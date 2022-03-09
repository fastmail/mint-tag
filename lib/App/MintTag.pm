use v5.20;
package App::MintTag;
# ABSTRACT: turn labeled merge requests into git tags

use Moo;
use experimental qw(postderef signatures);

use App::MintTag::Approver;
use App::MintTag::Artifact;
use App::MintTag::Config;
use App::MintTag::Logger '$Logger';
use App::MintTag::Util qw(run_git re_for_tag);

use Data::Dumper::Concise;
use DateTime;
use Path::Tiny ();
use Process::Status;
use Term::ANSIColor qw(color colored);
use Try::Tiny;

# MintTag::Config object
has config => (
  is => 'ro',
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

has merge_base => (
  is => 'rw',
  init_arg => undef,
  predicate => 'has_merge_base',
);

our $ANNOTATION_VERSION = 1;

sub from_config_file ($class, $config_file, $repo = undef) {
  return $class->new({
    config => App::MintTag::Config->from_file($config_file, $repo),
  });
};

sub mint_tag ($self, $auto_mode = 0, $mr_numbers = []) {
  if ($auto_mode) {
    $self->interactive(0);
  }

  $self->prepare_local_directory;

  # Fetch
  for my $step ($self->config->steps) {
    local $Logger = $step->proxy_logger;
    $step->fetch_mrs($self->upstream_base, $mr_numbers);   # to set merge-base
  }

  if ($self->interactive) {
    # exits on lack of user confirmation
    my $approver = App::MintTag::Approver->new($self->config);
    my $should_continue = $approver->confirm_plan;
    return unless $should_continue;
  }

  # Do this in a try block, so that we can be very noisy if something goes
  # wrong.
  try {
    for my $step ($self->config->steps) {
      local $Logger = $step->proxy_logger;

      local $ENV{GIT_AUTHOR_NAME}     = $self->config->committer_name;
      local $ENV{GIT_AUTHOR_EMAIL}    = $self->config->committer_email;
      local $ENV{GIT_COMMITTER_NAME}  = $self->config->committer_name;
      local $ENV{GIT_COMMITTER_EMAIL} = $self->config->committer_email;

      my $strategy = $step->use_semilinear_merge ? 'semilinear' : 'octopus';
      my $merge_method = "merge_strategy_$strategy";

      $self->$merge_method($step);

      my $tag = $self->maybe_tag_commit($step);
      $self->maybe_push($step, $tag);
    }

    $self->finalize;
  } catch {
    my $e = $_;

    if ($self->interactive) {
      my $local = $self->config->local_repo_dir;
      my $msg = join("\n",
        "Something went wrong during the merge process. Your local tree is probably",
        "in a weird state (it might have detached HEAD, or merge conflicts, etc.).",
        "I've left everything the way it was, so you can investigate if you like.",
        "Working directory:",
        "    $local",
      );

      $msg = colored($msg, 'bright_red') if $self->interactive;

      say "\n$msg";
    }

    die $e;   # rethrow
  };
}

# Tag an arbitrary sha according to the config file. This bails unless there is
# exactly one step in config with a defined tag_prefix.
sub tag_arbitrary_sha ($self, $sha) {
  my $num_prefixes = 0;
  my $tagging_step;

  for my $step ($self->config->steps) {
    if ($step->tag_prefix) {
      $num_prefixes++;
      $tagging_step = $step;
    }
  }

  unless ($num_prefixes == 1) {
    die "refusing to tag sha; config file is ambiguous about how to tag\n";
  }

  # Now, we can go. The plan is: set up, check out the tag, then tag it and
  # push it.
  $self->prepare_local_directory;

  run_git('checkout', $sha);
  run_git('submodule', 'update');

  my $tag = $self->maybe_tag_commit($tagging_step);
  $self->maybe_push($tagging_step, $tag);

  $self->finalize;
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'local setup: ' });
  $self->ensure_initial_prep;

  my $target = $self->target_branch_name;

  unless ($self->has_merge_base) {
    run_git('fetch', $self->upstream_remote_name);
    my $base_sha = run_git('rev-parse', $self->upstream_base);
    $self->merge_base($base_sha);
  }

  $Logger->log("creating branch: $target");
  run_git('reset', '--hard');
  # maybe: git clean -fdx
  run_git('checkout', '--no-track', '-B', $target, $self->merge_base);
  run_git('submodule', 'update');
}

has have_set_up => (
  is => 'rw',
  default => 0,
);

sub ensure_initial_prep ($self) {
  return if $self->have_set_up;

  my $dir = Path::Tiny::path($self->config->local_repo_dir);

  # If it doesn't exist, we either need to clone it or die.
  if (! $dir->is_dir) {
    die "local path $dir does not exist! (maybe you should set clone = true)\n"
      unless $self->config->should_clone;

    # Go to the parent directory before cloning.
    $dir->parent->mkpath unless $dir->parent->is_dir;
    chdir $dir->parent or die "Couldn't chdir to $dir\'s parent!\n";

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

  chdir $dir or die "Couldn't chdir to $dir; cowardly giving up\n";
  $Logger->log("using local path $dir");

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
      die "mismatched remote $name: have $have, want $remote_url"
        unless $have eq $remote_url;
    } else {
      $Logger->log("adding missing remote for $name at $remote_url");
      run_git('remote', 'add', $name, $remote_url);
    }

    # make sure our local tags are up to date
    $Logger->log("fetching tags for $name");
    run_git('fetch', '--tags', $remote->name);
  }
}

# for every MR in turn, rebase it onto now-main branch, then git-commit --no-ff
sub merge_strategy_semilinear ($self, $step) {
  for my $mr ($step->merge_requests) {
    my $new_base = run_git('rev-parse', 'HEAD');

    try {
      $mr->rebase($new_base);

      my $msg = $mr->as_multiline_commit_message($self->target_branch_name);

      run_git('checkout', $self->target_branch_name);;
      run_git('merge', '--no-ff', '-m' => $msg, $mr->sha);
      run_git('submodule', 'update');

      $Logger->log(["rebased and merged %s into %s", $mr->ident, $self->target_branch_name ]);
    } catch {
      my $e = $_;
      $Logger->log_fatal([
        "Error rebasing %s!%s (%s) onto HEAD (%s); bailing out! Error: %s",
        $mr->remote_name,
        $mr->number,
        $mr->sha,
        substr($new_base, 0, 8),
        $e,
      ])
    };
  }
}

sub merge_strategy_octopus ($self, $step) {
  $self->maybe_rebase($step);
  $self->octopus_merge_mrs([ $step->merge_requests ]);
}

sub maybe_rebase ($self, $step) {
  return unless $step->rebase;

  my $new_base = run_git('rev-parse', 'HEAD');

  # rebase every MR onto its base
  for my $mr ($step->merge_requests) {
    try {
      $mr->rebase($new_base);
    } catch {
      my $e = $_;
      $Logger->log_fatal([
        "Error rebasing %s!%s (%s) onto HEAD (%s); bailing out!",
        $mr->remote_name,
        $mr->number,
        $mr->sha,
        substr($new_base, 0, 8),
      ])
    };
  }

  # then check out our previous head
  run_git('checkout', $new_base);
}

sub octopus_merge_mrs ($self, $mrs) {
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

# Our tag format is going to be opinionated. If there's a tag_prefix in config,
# we'll tag the commit in the format PREFIX-yyyymmdd.nnn-gSHA
sub maybe_tag_commit ($self, $this_step) {
  return unless $this_step->tag_prefix;

  my $ymd = DateTime->now(time_zone => 'UTC')->ymd('');
  my $sha = run_git('rev-parse', 'HEAD');

  if (my $existing = $self->check_existing_tags($this_step->tag_prefix, $sha)) {
    my $short = substr $sha, 0, 12;
    $Logger->log("$short already tagged as $existing; skipping");
    return $existing;
  }

  my $prefix = $this_step->tag_prefix;
  my $tag = "$prefix-$ymd.001";

  # Grab the last tag we have, and increment our serial number, if we need to.
  my ($last_tag) = sort {; $b cmp $a }
                   split /\n/,
                   run_git('tag', '-l', "$prefix-$ymd.*");

  if ($last_tag) {
    my ($n) = $last_tag =~ /\Q$prefix-$ymd.\E(\d+)/a;
    $tag = sprintf "$prefix-$ymd.%03d", $n + 1;
  }

  my $short = substr $sha, 0, 8;
  $tag .= "-g$short";

  my $artifact = App::MintTag::Artifact->new({
    annotation_version => $ANNOTATION_VERSION,
    config    => $self->config,
    base      => $self->merge_base,
    tag_name  => $tag,
    this_step => $this_step,
  });

  my $msg = sprintf(
    "mint-tag generated commit from step named %s\n\n%s",
    $this_step->name,
    $artifact->as_toml,
  );

  # spew the message to a file
  my $path = Path::Tiny->tempfile();
  $path->spew_utf8($msg);

  $Logger->log("tagging $sha as $tag");
  run_git('tag', '-F', $path->absolute, $tag);

  return $tag;
}

sub check_existing_tags($self, $prefix, $sha) {
  # if we already have a tag for this tag format pointing at our head, don't
  # bother making another one!
  my @have_tags = split /\n/, run_git('tag', '-l', '--points-at', $sha);
  return unless @have_tags;

  my $re = re_for_tag($prefix);
  my ($tag) = grep {; $_ =~ $re } @have_tags;
  return $tag;
}

sub maybe_push ($self, $step, $tagname = undef) {
  # We do this _before_ pushing the merged branch, otherwise GitHub closes
  # them with status "closed" and not status "merged".
  if ($step->force_push_rebased_branches) {
    for my $mr ($step->merge_requests) {
      next unless $mr->has_been_rebased_locally;

      my $push_spec = join q{:}, $mr->sha, $mr->branch_name;

      try {
        $Logger->log(["force-pushing branch to %s/%s",
          $mr->force_push_url,
          $mr->branch_name,
        ]);

        run_git('push', '--force', $mr->force_push_url, $push_spec);

        $mr->wait_until_remote_head_is_correct;
      } catch {
        my $err = $_;

        # NOTE: I am erring on the side of caution in making this fatal.
        # Arguably, it doesn't *need* to be, but what I don't want is for us
        # to fail to force-push to a fork, then succeed in pushing to a merge
        # to the golden repo, which would leave the MR as open and tagged, and
        # potentially included again in future builds, when it fact it had
        # already been merged. -- michael, 2021-07-28
        $Logger->log_fatal([
          "could not force-push to %s/%s: %s",
          $mr->remote_name,
          $mr->branch_name,
          $err,
        ])
      };
    }
  }

  if (my $remote = $step->push_tag_to) {
    unless (length $tagname) {
      $Logger->log_fatal(["cannot push empty tag to remote %s!", $remote->name]);
    }

    $Logger->log(["pushing tag to remote %s", $remote->name ]);
    run_git('push', $remote->name, $tagname);
  }

  if ($step->has_push_spec) {
    my $spec         = $step->push_spec;
    my $remote       = $spec->{remote};
    my $should_force = $spec->{force};
    my $branch       = $spec->{branch}              ? $spec->{branch}
                     : $spec->{use_matching_branch} ? $self->target_branch_name
                     : die "could not figure out remote branch to push!";
    my $refspec      = join q{:}, 'HEAD', "refs/heads/$branch";

    $Logger->log(["%spushing branch to remote %s/%s",
      $should_force ? 'force-' : '',
      $remote->name,
      $branch,
    ]);

    run_git(
      'push',
      $remote->name,
      ($spec->{force} ? '--force-with-lease' : ()),
      $refspec,
    );
  }
}

sub finalize ($self) {
  # I put this here, but I'm not sure right now that it will do anything.
  $Logger->log("done!");
}

sub _octopus_merge ($self, $mrs) {
  unless (@$mrs) {
    $Logger->log("nothing to do!");
    return;
  }

  my @shas = map {; $_->sha } @$mrs;

  # Write our commit message into a file. This is potentially quite long, and
  # we don't really want it to show up in the debug logs for the commands.
  my $n = @$mrs;
  my $mrs_eng = "MR" . ($n > 1 ? 's' : '');

  my $msg = "Merge $n tagged $mrs_eng\n\n";
  $msg .= $_->oneline_desc . "\n" for @$mrs;

  my $path = Path::Tiny->tempfile();
  $path->spew_utf8($msg);

  # Here we're going to grab the latest author date of the heads we include,
  # then use that for both the author and committer dates, so that we can get
  # repeatable shas.
  my $latest = run_git('show', '--no-patch', '--format=%at', $self->merge_base);

  for my $mr (@$mrs) {
    my $epoch = run_git('show', '--no-patch', '--format=%at', $mr->sha);
    $latest = $epoch if $epoch > $latest;
  }

  # use the latest one we got, but never commit at epoch zero!
  my $stamp = $latest ? "$latest -0000" : undef;

  local $ENV{GIT_AUTHOR_DATE}     = $stamp;
  local $ENV{GIT_COMMITTER_DATE}  = $stamp;

  $Logger->log("octopus merging $n $mrs_eng");

  # We merge with no-commit, then commit -F, because older gits do not support
  # merge -F.  -- michael, 2020-07-15
  run_git('merge', '--no-ff', '--no-commit', @shas);
  run_git('commit', '-F' => $path->absolute);

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
  $Logger->log_fatal('diagnostic merge succeeded somehow...this should not happen!');
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
      $self->upstream_base,
      $err,
    ]);
  };

  # No? What *does* it conflict with, then?
  for my $mr (@$all_mrs) {
    next if $mr->ident eq $known_bad->ident;

    try {
      $Logger->log([ "merging %s to check for conflict", $mr->ident ]);
      run_git('merge', '--no-ff', '-m' => $mr->as_commit_message, $mr->sha);
      run_git('submodule', 'update');
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
