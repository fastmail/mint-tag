use v5.20;
package Buildotron;
use Moo;
use experimental qw(postderef signatures);

use Buildotron::Config;
use Buildotron::Logger '$Logger';

use Capture::Tiny qw(capture_merged);
use Data::Dumper::Concise;
use DateTime;
use IPC::System::Simple qw(capturex runx);
use Path::Tiny ();
use Process::Status;
use String::ShellQuote qw(shell_quote);
use Try::Tiny;

has config => (
  is => 'ro',
  required => 1,
);

sub from_config_file ($class, $config_file) {
  return $class->new({
    config => Buildotron::Config->from_file($config_file),
  });
};

sub build ($self) {
  $self->prepare_local_directory;

  for my $remote_name ($self->config->remote_names) {
    my $remote = $self->config->remote_named($remote_name);
    $self->fetch_and_merge_mrs_from($remote);   # might throw
    $self->maybe_tag_commit($remote);
  }

  $self->finalize;
}

sub run_git ($self, @cmd) {
  $Logger->log_debug([ "run: %s", join(q{ }, 'git', @cmd) ]);

  # I would use IPC::System::Simple's capturex here, but it does not seem to
  # capture stderr.
  my ($out) = capture_merged(sub { runx('git', @cmd) });

  if ($Logger->get_debug) {
    local $Logger = $Logger->proxy({ proxy_prefix => '(git): ' });
    my @lines = split /\r?\n/, $out;
    $Logger->log_debug($_) for @lines;
  }
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  chdir $self->config->local_repo_dir;

  my $target = $self->config->target_branch_name;

  $Logger->log("creating branch: $target");
  $self->run_git('reset', '--hard');
  # maybe: git clean -fdx
  $self->run_git('checkout', '-B', $target, $self->config->upstream_base);
  $self->run_git('submodule', 'update');
}

sub fetch_and_merge_mrs_from ($self, $remote) {
  # get 'em
  $Logger->log([ "fetching MRs from %s", $remote->name ]);

  my @mrs = $remote->get_mrs;
  for my $mr (@mrs) {
    $Logger->log([ "will merge: %s",  $mr->oneline_desc ]);
    $self->run_git('fetch', $mr->as_fetch_args);
  }

  # merge 'em
  try {
    $self->_octopus_merge(\@mrs);
  } catch {
    my $err = $_;
    chomp $err;

    $Logger->log("octopus merge failed with error: $err");
    $Logger->log("will merge less octopodally for diagnostics");
    $self->_diagnostic_merge(\@mrs);
  };
}

# This is *terrible*. If the remote has a tag_format, it can contain %d and
# %s, which are substituted with a date and a serial number. Almost certainly
# we want something else (sha?) but it's quitting time for today.
sub maybe_tag_commit ($self, $remote) {
  return unless $remote->has_tag_format;

  my $ymd = DateTime->now(time_zone => 'UTC')->ymd('');
  my $sha = capturex(qw(git rev-parse HEAD));
  chomp $sha;

  my $tag;
  my $format = $remote->tag_format;

  for (my $n = 1; $n < 1000; $n++) {
    my $candidate = sprintf '%03d', $n;
    $tag = $format;
    $tag =~ s/%d/$ymd/;
    $tag =~ s/%s/$candidate/;

    system(qw(git show-ref -q), $tag);
    my $ps = Process::Status->new;

    if (! $ps->is_success) {
      # If this exits zero, that means the tag exists and we need to keep going.
      # If it exits non-zero, that means it doensn't, and we're done!
      last;
    }
  }

  $Logger->log("tagging $sha as $tag");
  $self->run_git('tag', $tag);
}

sub finalize ($self) {
  # I put this here, but I'm not sure right now that it will do anything.
}

sub _octopus_merge ($self, $mrs) {
  my @shas = map {; $_->sha } @$mrs;

  # Write our commit message into a file. This is potentially quite long, and
  # we don't really want it to show up in the debug logs for the commands.
  my $n = @$mrs;
  my $msg = sprintf("Merge %d tagged MR%s\n\n", $n, $n > 1 ? 's' : '');
  $msg .= $_->oneline_desc . "\n" for @$mrs;

  my $path = Path::Tiny->tempfile();
  $path->spew_utf8($msg);

  $self->run_git('merge', '--no-ff', '-F' => $path->absolute, @shas);

  $Logger->log([ "merged $n MR%s into %s",
    $n > 1 ? 's' : '',
    $self->config->target_branch_name,
  ]);
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

  # If we get here, something very strange indeed has happened.

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
      $self->config->target_branch_name,
      $err,
    ]);
  };

  # No? What *does* it conflict with, then?
  for my $mr (@$all_mrs) {
    next if $mr->ident eq $known_bad->ident;

    try {
      $Logger->log([ "merging %s to check for conflict", $mr->ident ]);

      # XXX: Oh boy. Passing a single command into this instead of a list is
      # evil, but all the people I'd normally ask about less evil ways of
      # doing this are asleep or not working.
      my $sha = shell_quote($mr->sha);

      # NB: this prefix nonsense is because I have diff.noprefix true in my
      # local gitconfig, which causes this command to fail cryptically.
      $self->run_git("format-patch --src-prefix=a/ --dst-prefix=b/ --stdout $sha | git apply --check");
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
