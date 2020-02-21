use v5.20;
package Buildotron;
use Moo;
use experimental qw(postderef signatures);

use Buildotron::Config;
use Buildotron::Logger '$Logger';

use Data::Dumper::Concise;
use Capture::Tiny qw(capture_merged);
use IPC::System::Simple qw(runx);

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

  $Logger->log("fetching MRs from $remote_name");

  my @mrs = $remote->get_mrs;

  for my $mr (@mrs) {
    $Logger->log([ "will merge: %s",  $mr->oneline_desc ]);
  }
}

sub finalize ($self) {
}

1;
