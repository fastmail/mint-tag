use v5.20;
use warnings;
package Buildotron::Config;
use Moo;
use experimental qw(signatures postderef);

use TOML::Parser;
use Types::Standard qw(HashRef Str ConsumerOf);

# I tried using Module::Runtime for this, but failed mysteriously. TODO: why??
use Buildotron::Remote::Github;
use Buildotron::Remote::GitLab;

sub from_file ($class, $file) {
  my $config = TOML::Parser->new->parse_file($file);

  return $class->new({
    cfg                => $config,
    local_repo_dir     => $config->{local}{path},
    target_branch_name => $config->{local}{target_branch},
    upstream_base      => $config->{local}{upstream_base},
    remotes            => $config->{remote},
    meta               => $config->{meta} // {},
  });
}

has _cfg => (
  is => 'ro',
  required => 1,
  init_arg => 'cfg',
  isa => HashRef,
);

has meta => (
  is => 'ro',
  isa => HashRef,
  required => 1,
);

has local_repo_dir => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has target_branch_name => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has upstream_base => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has _remotes => (
  is => 'ro',
  isa => HashRef[ConsumerOf["Buildotron::Remote"]],
  required => 1,
  init_arg => 'remotes',
  coerce => sub ($val) {
    # Build Buildotron::Remote classes as early as possible. This is a little
    # janky to do it in a coercion, but I think it's ok.
    my %remotes;

    for my $name (keys %$val) {
      my $cfg = $val->{$name};
      my $class = delete $cfg->{interface_class}
        or die "no interface_class found for remote $name!";

      $remotes{$name} = $class->new({
        name => $name,
        %$cfg,
      });
    }

    return \%remotes;
  },
);

sub remotes ($self) {
  return map {; $self->remote_named($_) } $self->remote_names;
}

# return a list of the remotes, in some order.
sub remote_names ($self) {
  my $ordered = $self->meta->{remote_order};
  return @$ordered if $ordered;

  return sort keys $self->_remotes->%*;
}

sub remote_named ($self, $name) {
  my $remote = $self->_remotes->{$name};
  return $remote if $remote;

  die "No configuration for remote named $name!\n"
}

1;
