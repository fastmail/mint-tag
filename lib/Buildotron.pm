use v5.20;
package Buildotron;
use Moo;
use experimental qw(postderef signatures);

use Buildotron::Config;
use Buildotron::Logger '$Logger';

use Data::Dumper::Concise;
use Capture::Tiny qw(capture_merged);
use IPC::System::Simple qw(runx);
use Path::Tiny ();
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

  for my $remote ($self->config->remote_names) {
    $self->fetch_and_merge_mrs_from($remote);
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

sub fetch_and_merge_mrs_from ($self, $remote_name) {
  my $remote = $self->config->remote_named($remote_name);

  # get 'em
  $Logger->log("fetching MRs from $remote_name");

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
    die "octopus merge failed: $err";
  };
}

sub finalize ($self) {
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

1;
