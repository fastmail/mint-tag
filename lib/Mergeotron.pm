use v5.20;
package Mergeotron;
use Moo;
use experimental qw(postderef signatures);

use Mergeotron::Approver;
use Mergeotron::Config;
use Mergeotron::Logger '$Logger';
use Mergeotron::Util qw(run_git);

use Data::Dumper::Concise;
use DateTime;
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

  if ($self->interactive) {
    # exits on lack of user confirmation
    my $approver = Mergeotron::Approver->new($self->config);
    $approver->confirm_plan;
  }

  # Act
  for my $step ($self->config->steps) {
    local $Logger = $step->proxy_logger;
    $self->merge_mrs([ $step->merge_requests ]);
    $self->maybe_tag_commit($step);
  }

  $self->finalize;
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'local setup: ' });
  $self->ensure_initial_prep;

  my $target = $self->target_branch_name;

  $Logger->log("creating branch: $target");
  run_git('reset', '--hard');
  # maybe: git clean -fdx
  run_git('fetch', $self->upstream_remote_name);
  run_git('checkout', '--no-track', '-B', $target, $self->upstream_base);
  run_git('submodule', 'update');
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

    run_git(
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
  my $remote_output = run_git('remote', '-v');

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
    run_git('remote', 'add', $name, $remote_url);
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
    run_git('fetch', $mr->as_fetch_args);
  }

  return \@mrs;
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
  my $sha = run_git('rev-parse', 'HEAD');

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
    my $found_tags = run_git('tag', '-l', "$tag*");
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
  run_git('tag', '-F', $path->absolute, $tag);

  $self->maybe_push_tag($this_step, $tag);
}

sub check_existing_tags($self, $format, $sha) {
  # if we already have a tag for this tag format pointing at our head, don't
  # bother making another one!
  my @have_tags = split /\n/, run_git('tag', '-l', '--points-at', $sha);

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
    run_git('push', $remote->name, $tag);
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
    my $epoch = run_git('show', '--no-patch', '--format=%at', $mr->sha);
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

  run_git('merge', '--no-ff', '-F' => $path->absolute, @shas);

  $Logger->log([ "merged $n $mrs_eng into %s", $self->target_branch_name ]);
}

sub _diagnostic_merge ($self, $mrs) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'diagnostic merge: ' });

  $self->prepare_local_directory;

  for my $mr (@$mrs) {
    $Logger->log([ "merging %s", $mr->oneline_desc ]);

    try {
      run_git('merge', '--no-ff', '-m' => $mr->as_commit_message, $mr->sha);
      run_git('submodule', 'update');
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
    run_git('merge', '--no-ff', '-m' => $msg, $known_bad->sha);
    run_git('submodule', 'update');
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
      my $patch = run_git(
        'format-patch', '--src-prefix=a/', '--dst-prefix=b/', '--stdout', $mr->sha
      );

      run_git('apply', 'check', { stdin => \$patch });
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
