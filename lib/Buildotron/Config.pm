use v5.20;
use warnings;
package Buildotron::Config;
use Moo;
use experimental 'postderef';

use TOML::Parser;

# I tried using Module::Runtime for this, but failed mysteriously. TODO: why??
use Buildotron::Remote::Github;
use Buildotron::Remote::GitLab;

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

# Surely I could do this in some other way...
sub _assert_exists {
  my ($class, $cfg, $path) = @_;

  my @parts = split /[.]/, $path;
  my @seen;

  my $cur = $cfg;

  while (@parts) {
    my $k = shift @parts;
    push @seen, $k;

    $cur = $cur->{$k};

    unless ($cur) {
      my $full = join q{.}, @seen;
      die "Missing config item $full!\n" unless $cur;
    }
  }

  return;
}

sub _validate_config {
  my ($class, $cfg) = @_;

  $class->_assert_exists($cfg, 'local.path');
  $class->_assert_exists($cfg, 'local.target_branch');
  $class->_assert_exists($cfg, 'local.upstream_base');

  my $remotes = $cfg->{remote} // {};

  for my $remote (keys %$remotes) {
    $class->_assert_exists($cfg, "remote.$remote.url");
    $class->_assert_exists($cfg, "remote.$remote.interface_class");
  }
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

# return a list of the remotes, in some order.
sub remote_names {
  my $self = shift;

  my $remotes = $self->_cfg->{meta}{remote_order};
  return @$remotes if $remotes;

  return sort keys $self->_cfg->{remote}->%*;
}

sub remote_interface_for {
  my ($self, $remote_name) = @_;
  my $this_cfg = $self->_cfg->{remote}{$remote_name};

  die "No configuration for remote named $remote_name!\n"
    unless $this_cfg;

  my $class = $this_cfg->{interface_class};

  return $class->new({
    labels => $this_cfg->{labels} // [],
    url => $this_cfg->{url},
  });
}

1;
