use v5.20;
package App::MintTag::Config;
# ABSTRACT: how should we build this tag, anyway?

use Moo;
use experimental qw(signatures postderef);

use TOML::Parser;

use App::MintTag::BuildStep;
use App::MintTag::Remote::GitHub;
use App::MintTag::Remote::GitLab;

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
);

has committer_name => (
  is => 'ro',
  default => 'MintTag',
);

has committer_email => (
  is => 'ro',
  required => 1,
);

has local_repo_dir => (
  is => 'ro',
  required => 1,
);

has target_branch_name => (
  is => 'ro',
  required => 1,
);

has upstream_base => (
  is => 'ro',
  required => 1,
);

has upstream_remote_name => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my ($remote) = split m{/}, $self->upstream_base;
    return $remote;
  },
);

has upstream_branch_name => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my (undef, $branch) = split m{/}, $self->upstream_base;
    return $branch;
  },
);

has should_clone => (
  is => 'ro',
  coerce => sub ($val) { !! $val },
);

has remotes => (
  is => 'ro',
  isa => sub ($val) {
    die "remotes must be a hashref" unless ref $val eq 'HASH';
    for my $k (keys %$val) {
      die "remote named $k is not MintTag::Remote"
        unless $val->{$k}->does('App::MintTag::Remote');
    }
  },
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

sub remote_for_url ($self, $clone_url) {
  my $remote = $self->_remotes_by_url->{$clone_url};
  return $remote if $remote;

  # Not dying here, I think.
  return;
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
  isa => sub ($val) {
    die "steps must be an arrayref" unless ref $val eq 'ARRAY';
    for my $step (@$val) {
      die "step is not a MintTag::BuildStep"
        unless $step->isa('App::MintTag::BuildStep');
    }
  },
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
      die "No matching remote found for $tag_remote_name!\n" unless $tag_remote;
    }

    if (my $spec = $step->{push_spec}) {
      die "push_spec must have 'remote' and 'branch' keys\n"
        unless $spec->{remote} && $spec->{branch};

      my $remote = $remotes->{ $spec->{remote} };
      die "No matching remote found for $spec->{remote}!\n" unless $remote;

      $spec->{remote} = $remote;  # replace with a real remote object
    }

    push @steps, App::MintTag::BuildStep->new({
      remote      => $remote,
      push_tag_to => $tag_remote,
      %$step,
    });
  }

  return \@steps;
}

1;
