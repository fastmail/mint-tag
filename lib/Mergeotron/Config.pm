use v5.20;
use warnings;
package Mergeotron::Config;
use Moo;
use experimental qw(signatures postderef);

use TOML::Parser;
use Types::Standard qw(ArrayRef Bool HashRef Str ConsumerOf InstanceOf);

use Mergeotron::BuildStep;
use Mergeotron::Remote::Github;
use Mergeotron::Remote::GitLab;

sub from_file ($class, $file) {
  my $config = TOML::Parser->new->parse_file($file);

  my $remotes = $class->_assemble_remotes($config->{remote});
  my $steps = $class->_assemble_steps($config->{build_steps}, $remotes);

  return $class->new({
    cfg                => $config,
    committer_name     => $config->{meta}{committer_name},
    committer_email    => $config->{meta}{committer_email},
    local_repo_dir     => $config->{local}{path},
    target_branch_name => $config->{local}{target_branch},
    upstream_base      => $config->{local}{upstream_base},
    should_clone       => $config->{local}{clone},
    remotes            => $remotes,
    steps              => $steps,
  });
}

has _cfg => (
  is => 'ro',
  required => 1,
  init_arg => 'cfg',
  isa => HashRef,
);

has committer_name => (
  is => 'ro',
  isa => Str,
  default => 'Mergeotron',
);

has committer_email => (
  is => 'ro',
  isa => Str,
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

has upstream_remote_name => (
  is => 'ro',
  isa => Str,
  lazy => 1,
  default => sub ($self) {
    my ($remote) = split m{/}, $self->upstream_base;
    return $remote;
  },
);

has upstream_branch_name => (
  is => 'ro',
  isa => Str,
  lazy => 1,
  default => sub ($self) {
    my (undef, $branch) = split m{/}, $self->upstream_base;
    return $branch;
  },
);

has should_clone => (
  is => 'ro',
  isa => Bool,
  coerce => sub ($val) { !! $val },
);

has remotes => (
  is => 'ro',
  isa => HashRef[ConsumerOf["Mergeotron::Remote"]],
  required => 1,
);

has _remotes_by_url => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    # This is potentially lossy, if you have the same remote with more than
    # one name. I think that's fine, for the purposes we need it for.
    return +{ map {; $_->clone_url => $_ } $self->all_remotes };
  }
);

sub all_remotes ($self) { return values $self->remotes->%* }

sub remote_named ($self, $name) {
  my $remote = $self->remotes->{$name};
  return $remote if $remote;

  die "No configuration for remote named $name!\n"
}

sub _assemble_remotes ($class, $remote_config) {
  my %remotes;

  for my $name (keys %$remote_config) {
    my $cfg = $remote_config->{$name};
    my $iclass = delete $cfg->{interface_class}
      or die "no interface_class found for remote $name!";

    $remotes{$name} = $iclass->new({
      name => $name,
      %$cfg,
    });
  }

  return \%remotes;
}

has _steps => (
  is => 'ro',
  isa => ArrayRef[InstanceOf["Mergeotron::BuildStep"]],
  required => 1,
  init_arg => 'steps',
);

sub steps { $_[0]->_steps->@* }

sub _assemble_steps ($class, $step_config, $remotes) {
  my @steps;

  for my $step (@$step_config) {
    my $remote_name = delete $step->{remote};
    my $remote = $remotes->{$remote_name};
    die "No matching remote found for $remote_name!\n" unless $remote;

    my $tag_remote;
    if (my $tag_remote_name = delete $step->{push_tag_to}) {
      $tag_remote = $remotes->{$tag_remote_name};
      die "No matching remote found for $tag_remote!\n" unless $tag_remote;
    }

    push @steps, Mergeotron::BuildStep->new({
      remote      => $remote,
      push_tag_to => $tag_remote,
      %$step,
    });
  }

  return \@steps;
}

1;
