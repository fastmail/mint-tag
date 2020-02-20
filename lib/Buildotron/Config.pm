use v5.20;
use warnings;
package Buildotron::Config;
use Moo;

use TOML::Parser;

has _cfg => (
  is => 'ro',
  required => 1,
  init_arg => 'cfg',
);

sub from_file {
  my ($class, $file) = @_;

  my $config = TOML::Parser->new->parse_file($file);
  $class->_validate_config($config);

  return $class->new({ cfg => $config });
}

sub _validate_config {
  my ($class, $cfg) = @_;

  # TODO
}

has local_repo_dir => (
  is => 'ro',
  lazy => 1,
  builder => sub { $_[0]->_cfg->{local}{path} },
);

has target_branch_name => (
  is => 'ro',
  lazy => 1,
  builder => sub { $_[0]->_cfg->{local}{target_branch} },
);

has upstream_base => (
  is => 'ro',
  lazy => 1,
  builder => sub { $_[0]->_cfg->{local}{upstream_base} },
);

1;
