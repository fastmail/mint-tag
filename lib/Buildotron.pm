use v5.20;
package Buildotron;
use Moo;
use experimental qw(postderef signatures);

use Buildotron::Config;
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
  say "can we build it?\nno not yet!";

  $self->prepare_local_directory;

  for my $remote ($self->config->remote_names) {
    $self->fetch_and_merge_mrs_from($remote);
  }

  $self->finalize;
}

sub run_git ($self, @cmd) {
  # Probably, eventually, a logger.
  my $str = join(q{ }, 'git', @cmd);
  say "I: running $str";
  runx('git', @cmd);
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  chdir $self->config->local_repo_dir;

  my $target = $self->config->target_branch_name;

  say "I: creating branch: $target";
  $self->run_git('reset', '--hard');
  # maybe: git clean -fdx
  $self->run_git('checkout', '-B', $target, $self->config->upstream_base);
  $self->run_git('submodule', 'update');
}

sub fetch_and_merge_mrs_from ($self, $remote_name) {
}

sub finalize ($self) {
}

1;
