use v5.20;
use warnings;
package Buildotron::Config;
use Moo;
use experimental 'postderef';

use TOML::Parser;
use Types::Standard qw(HashRef Str);

# I tried using Module::Runtime for this, but failed mysteriously. TODO: why??
use Buildotron::Remote::Github;
use Buildotron::Remote::GitLab;

sub from_file {
  my ($class, $file) = @_;

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

has remotes => (
  is => 'ro',
  isa => sub {
    my $val = shift;
    die "must be a hashref\n" unless ref $val eq 'HASH';

    for my $name (keys %$val) {
      my $remote = $val->{$name};
      die "remote '$name' must be a hashref\n" unless ref $remote eq 'HASH';
      die "remote '$name' is missing value for 'url'\n" unless $remote->{url};
      die "remote '$name' is missing value for 'interface_class'\n"
        unless $remote->{interface_class};
    }

    return;
  },
  required => 1,
);

# return a list of the remotes, in some order.
sub remote_names {
  my $self = shift;

  my $ordered = $self->meta->{remote_order};
  return @$ordered if $ordered;

  return sort keys $self->remotes->%*;
}

sub remote_interface_for {
  my ($self, $remote_name) = @_;
  my $this_cfg = $self->remotes->{$remote_name};

  die "No configuration for remote named $remote_name!\n"
    unless $this_cfg;

  my $class = $this_cfg->{interface_class};

  return $class->new({
    labels => $this_cfg->{labels} // [],
    url => $this_cfg->{url},
  });
}

1;
