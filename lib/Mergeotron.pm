use v5.20;
package Mergeotron;
use Moo;
use experimental qw(postderef signatures);

use Mergeotron::Config;
use Mergeotron::Logger '$Logger';

use Data::Dumper::Concise;
use DateTime;
use IPC::Run3 qw(run3);
use List::Util qw(sum0);
use Path::Tiny ();
use Process::Status;
use Term::ANSIColor qw(color colored);
use Try::Tiny;
use Types::Standard qw(Bool InstanceOf);

has config => (
  is => 'ro',
  isa => InstanceOf['Mergeotron::Config'],
  required => 1,
  handles => [qw(
    all_remotes
    remote_named
    target_branch_name
    upstream_base
    upstream_remote_name
  )]
);

has interactive => (
  is => 'rw',
  default => 1,
);

sub from_config_file ($class, $config_file) {
  return $class->new({
    config => Mergeotron::Config->from_file($config_file),
  });
};

sub build ($self, $auto_mode = 0) {
  if ($auto_mode) {
    $self->interactive(0);
  }

  $self->prepare_local_directory;

  # Fetch
  for my $step ($self->config->steps) {
    local $Logger = $step->proxy_logger;
    my $mrs = $self->fetch_mrs_for($step);
    $step->set_merge_requests($mrs);
  }

  # Confirm
  $self->confirm_plan if $self->interactive;

  # Act
  for my $step ($self->config->steps) {
    local $Logger = $step->proxy_logger;
    $self->merge_mrs([ $step->merge_requests ]);
    $self->maybe_tag_commit($step);
  }

  $self->finalize;
}

sub run_git ($self, @cmd) {
  # A little silly, but hey.
  my $arg = {};
  $arg = pop @cmd if ref $cmd[-1] eq 'HASH';

  $Logger->log_debug([ "run: %s", join(q{ }, 'git', @cmd) ]);

  my $in = $arg->{stdin} // undef;
  my $out;

  unshift @cmd, 'git';
  run3(\@cmd, $in, \$out, \$out);
  my $ps = Process::Status->new;

  chomp $out;

  if ($Logger->get_debug) {
    local $Logger = $Logger->proxy({ proxy_prefix => '(git): ' });
    my @lines = split /\r?\n/, $out;
    $Logger->log_debug($_) for @lines;
  }

  $ps->assert_ok(join(q{ }, @cmd[0..1]));

  return $out;
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'local setup: ' });
  $self->ensure_initial_prep;

  my $target = $self->target_branch_name;

  $Logger->log("creating branch: $target");
  $self->run_git('reset', '--hard');
  # maybe: git clean -fdx
  $self->run_git('fetch', $self->upstream_remote_name);
  $self->run_git('checkout', '--no-track', '-B', $target, $self->upstream_base);
  $self->run_git('submodule', 'update');
}

has have_set_up => (
  is => 'rw',
  isa => Bool,
  default => 0,
);

sub ensure_initial_prep ($self) {
  return if $self->have_set_up;

  my $dir = Path::Tiny::path($self->config->local_repo_dir);

  # If it doesn't exist, we either need to clone it or die.
  if (! $dir->is_dir) {
    die "local path $dir does not exist! (maybe you should set clone = true)\n"
      unless $self->config->should_clone;

    chdir $dir->parent;
    $Logger->log(["cloning into $dir from %s", $self->upstream_base]);

    my $remote = $self->remote_named($self->upstream_remote_name);

    $self->run_git(
      'clone',
      '--recursive',
      '-o' => $remote->name,
      $remote->clone_url,
      $dir->basename
    );
  }

  chdir $dir;

  $self->_ensure_remotes;
  $self->have_set_up(1);
}

sub _ensure_remotes ($self) {
  my $remote_output = $self->run_git('remote', '-v');

  # name => url
  my %have_remotes = map  {; split /\t/       }
                     grep {; s/\s+\(fetch\)// }
                     split /\r?\n/, $remote_output;

  REMOTE: for my $remote ($self->all_remotes) {
    my $name = $remote->name;
    my $remote_url = $remote->clone_url;

    if (my $have = $have_remotes{$name}) {
      # nothing to do unless they're mismatched.
      if ($have ne $remote_url) {
        die "mismatched remote $name: have $have, want $remote_url";
      }

      next REMOTE;
    }

    $Logger->log("adding missing remote for $name at $remote_url");
    $self->run_git('remote', 'add', $name, $remote_url);
  }
}

sub fetch_mrs_for ($self, $step) {
  # get 'em
  $Logger->log([ "fetching MRs from remote %s with label %s",
    $step->remote->name,
    $step->label,
  ]);

  my @mrs = $step->remote->get_mrs_for_label($step->label, $step->trusted_org);
  for my $mr (@mrs) {
    $Logger->log([ "fetched %s!%s",  $mr->remote_name, $mr->number ]);
    $self->run_git('fetch', $mr->as_fetch_args);
  }

  return \@mrs;
}

sub confirm_plan ($self) {
  my $head = $self->run_git('rev-parse', 'HEAD');

  say '';

  printf("Okay, here's the plan! We're going to build a branch called %s.\n",
    colored($self->target_branch_name, 'bright_blue'),
  );

  printf("We're starting with %s, which is at commit %s.\n\n",
    colored($self->upstream_base, 'bright_blue'),
    colored(substr($head, 0, 12), 'bright_blue'),
  );

  my $i = 1;

  my $total_mr_count = sum0 map {; scalar $_->merge_requests } $self->config->steps;
  unless ($total_mr_count > 0) {
    say "Well, that would have been a great branch, but I couldn't find anything";
    say "to merge. I guess I'll give up now; maybe next time!";
    exit 0;
  }

  for my $step ($self->config->steps) {
    my $header = "Step $i: " . $step->name;
    $i++;
    say $header;
    say '-' x length $header;

    unless ($step->merge_requests) {
      printf("Nothing to do! No merge requests labeled %s found on remote %s\n",
        $step->label,
        $step->remote->name,
      );
      next;
    }

    say "We're going to include the following merge requests:\n";

    for my $mr ($step->merge_requests) {
      say "* " . $mr->oneline_desc;
    }

    if (my $remote = $step->push_tag_to) {
      say "\nWe'd tag that and push it tag to the remote named " . $remote->name . '.';
    }

    say "";
  }

  print "Continue? [y/n] ";
  while (my $input = <STDIN>) {
    chomp($input);

    if (lc $input eq 'y') {
      say "Great...here we go!\n";
      return;
    }

    if (lc $input eq 'n') {
      say "Alright then...see you next time!";
      exit 1;
    }

    print "Sorry, I didn't understand that! [y/n] ";
  }

  die "wait, how did you get here?";
}

sub merge_mrs ($self, $mrs) {
  try {
    $self->_octopus_merge($mrs);
  } catch {
    my $err = $_;
    chomp $err;

    $Logger->log("octopus merge failed with error: $err");
    $Logger->log("will merge less octopodally for diagnostics");
    $self->_diagnostic_merge($mrs);
  };
}

# $tag_format is a poor man's sprintf. Here are the replacements you can use:
#
# - %d: replaced with date in YYYYMMDD format
# - %s: three-digit serial number for this build (incremented until it's unique)
#
# We append an 8-char sha to the end of every tag format. So, a tag format of
# "cyrus-%d.%s" will be tagged as "cyrus-20200505.001-g12345678", and a build
# later the same day will be "cyrus-20200505.002-g90abcdef".
sub maybe_tag_commit ($self, $this_step) {
  return unless $this_step->tag_format;

  my $ymd = DateTime->now(time_zone => 'UTC')->ymd('');
  my $sha = $self->run_git('rev-parse', 'HEAD');

  if (my $existing = $self->check_existing_tags($this_step->tag_format, $sha)) {
    my $short = substr $sha, 0, 12;
    $Logger->log("$short already tagged as $existing; skipping");
    $self->maybe_push_tag($this_step, $existing);
    return;
  }

  my $tag;
  for (my $n = 1; $n < 1000; $n++) {
    my $candidate = sprintf '%03d', $n;
    $tag = $this_step->tag_format;
    $tag =~ s/%d/$ymd/;
    $tag =~ s/%s/$candidate/;

    # Do a prefix match, because we're going to add the sha at the end.
    my $found_tags = $self->run_git('tag', '-l', "$tag*");
    last unless $found_tags;
  }

  my $short = substr $sha, 0, 8;
  $tag .= "-g$short";

  # We want to include some metadata in the tag: for every MR we included,
  # the remote, its numbers, and its sha.
  my @lines = (
    sprintf("mergotron-tagged commit from step named %s", $this_step->name),
    "",
  );

  for my $step ($self->config->steps) {
    my $url = $step->remote->clone_url;

    for my $mr ($step->merge_requests) {
      push @lines, join q{|}, $url, $mr->number, $mr->sha;
    }

    last if $step eq $this_step;
  }

  # Write our commit message into a file. This is potentially quite long, and
  # we don't really want it to show up in the debug logs for the commands.
  local $ENV{GIT_AUTHOR_NAME}  = $self->config->committer_name;
  local $ENV{GIT_AUTHOR_EMAIL} = $self->config->committer_email;

  my $path = Path::Tiny->tempfile();
  $path->spew_utf8(join "\n", @lines);

  $Logger->log("tagging $sha as $tag");
  $self->run_git('tag', '-F', $path->absolute, $tag);

  $self->maybe_push_tag($this_step, $tag);
}

sub check_existing_tags($self, $format, $sha) {
  # if we already have a tag for this tag format pointing at our head, don't
  # bother making another one!
  my @have_tags = split /\n/, $self->run_git('tag', '-l', '--points-at', $sha);

  return unless @have_tags;

  # This is pretty janky...
  my $re = quotemeta($format);
  $re =~ s/\\%d/\\d{8}/;
  $re =~ s/\\%s/\\d{3}/;

  my ($tag) = grep {; $_ =~ qr{$re} } @have_tags;
  return $tag;
}

sub maybe_push_tag ($self, $step, $tag) {
  if (my $remote = $step->push_tag_to) {
    $Logger->log(["pushing tag to remote %s", $remote->name ]);
    $self->run_git('push', $remote->name, $tag);
  }
}

sub finalize ($self) {
  # I put this here, but I'm not sure right now that it will do anything.
  $Logger->log("done!");
}

sub _octopus_merge ($self, $mrs) {
  my @shas = map {; $_->sha } @$mrs;

  # Write our commit message into a file. This is potentially quite long, and
  # we don't really want it to show up in the debug logs for the commands.
  my $n = @$mrs;
  my $mrs_eng = "MR" . ($n > 1 ? 's' : '');

  my $msg = "Merge $n tagged $mrs_eng\n\n";
  $msg .= $_->oneline_desc . "\n" for @$mrs;

  my $path = Path::Tiny->tempfile();
  $path->spew_utf8($msg);

  # Here we're going to grab the latest author date of the MRs we include,
  # then use that for both the author and committer dates, so that we can get
  # repeatable shas.
  my $latest = 0;
  for my $mr (@$mrs) {
    my $epoch = $self->run_git('show', '--no-patch', '--format=%at', $mr->sha);
    $latest = $epoch if $epoch > $latest;
  }

  # use the latest one we got, but never commit at epoch zero!
  my $stamp = $latest ? "$latest -0000" : undef;

  local $ENV{GIT_AUTHOR_NAME}     = $self->config->committer_name;
  local $ENV{GIT_AUTHOR_EMAIL}    = $self->config->committer_email;
  local $ENV{GIT_AUTHOR_DATE}     = $stamp;
  local $ENV{GIT_COMMITTER_NAME}  = $self->config->committer_name;
  local $ENV{GIT_COMMITTER_EMAIL} = $self->config->committer_email;
  local $ENV{GIT_COMMITTER_DATE}  = $stamp;

  $Logger->log("octopus merging $n $mrs_eng");

  $self->run_git('merge', '--no-ff', '-F' => $path->absolute, @shas);

  $Logger->log([ "merged $n $mrs_eng into %s", $self->target_branch_name ]);
}

sub _diagnostic_merge ($self, $mrs) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'diagnostic merge: ' });

  $self->prepare_local_directory;

  for my $mr (@$mrs) {
    $Logger->log([ "merging %s", $mr->oneline_desc ]);

    try {
      $self->run_git('merge', '--no-ff', '-m' => $mr->as_commit_message, $mr->sha);
      $self->run_git('submodule', 'update');
    } catch {
      my $err = $_;
      chomp $err;

      # These errors are almost always useless, like 'git returned exit value 1'
      $Logger->log_debug("git error: $err");

      $Logger->log([
        "encountered error while merging %s; will attempt to find conflict",
        $mr->ident
      ]);
      $self->_find_conflict($mr, $mrs);
    };
  }

  # If we are in this sub at all, we expect that the above will fail. If it
  # doesn't, something very strange indeed has happened.
  $Logger->log('diagnostic merge succeeded somehow...this should not happen!');
}

sub _find_conflict ($self, $known_bad, $all_mrs) {
  # clean slate
  $self->prepare_local_directory;

  # First: does this conflict with the branch we're trying to deploy?
  try {
    $Logger->log([ "merging known-bad MR: %s", $known_bad->ident ]);

    my $msg = $known_bad->as_commit_message;
    $self->run_git('merge', '--no-ff', '-m' => $msg, $known_bad->sha);
    $self->run_git('submodule', 'update');
  } catch {
    my $err = $_;
    chomp $err;

    $Logger->log_fatal([ "%s conflicts with %s (%s)",
      $known_bad->ident,
      $self->target_branch_name,
      $err,
    ]);
  };

  # No? What *does* it conflict with, then?
  for my $mr (@$all_mrs) {
    next if $mr->ident eq $known_bad->ident;

    try {
      $Logger->log([ "merging %s to check for conflict", $mr->ident ]);

      # NB: this prefix nonsense is because I have diff.noprefix true in my
      # local gitconfig, which causes this command to fail cryptically.
      my $patch = $self->run_git(
        'format-patch', '--src-prefix=a/', '--dst-prefix=b/', '--stdout', $mr->sha
      );

      $self->run_git('apply', 'check', { stdin => \$patch });
    } catch {
      my $err = $_;
      chomp $err;

      $Logger->log_debug("git error: $err");

      $Logger->log_fatal([ "fatal conflict between %s and %s; giving up",
        $mr->ident,
        $known_bad->ident,
      ]);
    };
  }
}

1;
