use v5.20;
package App::MintTag::Config;
# ABSTRACT: how should we build this tag, anyway?

use Moo;
use experimental qw(signatures postderef);

use Path::Tiny qw(path);
use TOML::Parser;

use App::MintTag::BuildStep;
use App::MintTag::Remote::GitHub;
use App::MintTag::Remote::GitLab;

sub from_file ($class, $file, $repo = undef) {
  my $config = TOML::Parser->new->parse_file($file);

  if ($config->{meta}{release_mode}) {
    $config = $class->_munge_config_for_release_mode($config, $repo);
  }

  my $remotes = $class->_assemble_remotes($config->{remote});
  my $steps = $class->_assemble_steps($config->{build_steps}, $remotes);
  my $local_conf = $class->_assemble_local_conf($config, $remotes);

  return $class->new({
    cfg                => $config,
    is_release_mode    => !! $config->{meta}{release_mode},
    committer_name     => $config->{meta}{committer_name},
    committer_email    => $config->{meta}{committer_email},
    local_repo_dir     => $local_conf->{path},
    target_branch_name => $local_conf->{target_branch},
    upstream_base      => $local_conf->{upstream_base},
    should_clone       => $local_conf->{clone},
    remotes            => $remotes,
    steps              => $steps,
  });
}

has _cfg => (
  is => 'ro',
  required => 1,
  init_arg => 'cfg',
);

has is_release_mode => (
  is => 'ro',
  default => 0,
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

# In release mode, we do things a little differently
# - there is only one step
# - we assume as much as possible given the config we have
sub _munge_config_for_release_mode ($class, $config, $repo_name) {
  my $step_config = delete $config->{release_mode};

  die "missing release_mode config\n"          unless $step_config;
  die "missing remote name for release_mode\n" unless $step_config->{remote};
  die "missing label name for release_mode\n"  unless defined $step_config->{label};
  die "release_mode config cannot have build_steps" if $config->{build_steps};

  # stick our repo name into remote conf
  my $remote_name = $step_config->{remote};
  $config->{remote}{$remote_name}{repo} //= $repo_name;

  die "could not determine remote repo to use for release mode\n"
    unless $config->{remote}{$remote_name}{repo};

  $config->{local}{clone} = 1;

  $config->{build_steps} = [{
    name => 'build-release-branch',
    push_spec => {
      remote => $step_config->{remote},
      use_matching_branch => 1,
      force => 0,
    },
    %$step_config,
  }];

  return $config;
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
      die "push_spec must have 'remote' key\n" unless $spec->{remote};

      die "push_spec must have either 'branch' or 'use_matching_branch' keys"
        unless $spec->{branch} xor $spec->{use_matching_branch};

      my $remote = $remotes->{ $spec->{remote} };
      die "No matching remote found for $spec->{remote}!\n" unless $remote;

      $spec->{remote} = $remote;  # replace with a real remote object
    }

    # If we need to force-push to forks, we have to tell our remote to fetch
    # the URLs we need.
    if ($step->{force_push_rebased_branches}) {
      $remote->should_fetch_ssh_url_for_forks(1);
    }

    push @steps, App::MintTag::BuildStep->new({
      remote      => $remote,
      push_tag_to => $tag_remote,
      %$step,
    });
  }

  return \@steps;
}

sub _assemble_local_conf ($class, $config, $remotes) {
  my $local_conf = $config->{local};

  # We must have upstream_base OR (upstream_remote && use_upstream_default_branch)
  if ($local_conf->{upstream_remote} && $local_conf->{use_upstream_default_branch}) {
    my $upstream_name = $local_conf->{upstream_remote};

    my $remote = $remotes->{$upstream_name}
      or die "cannot find remote for upstream $upstream_name\n";

    my $default_branch = $remote->get_default_branch_name;
    $local_conf->{upstream_base} = "$upstream_name/$default_branch";
    $local_conf->{target_branch} = $default_branch;
  }

  die "cannot figure out upstream base\n" unless $local_conf->{upstream_base};

  if (my $base_dir = delete $local_conf->{base_dir}) {
    # Generate a local path
    my ($upstream) = split m{/}, $local_conf->{upstream_base};

    my $remote = $remotes->{$upstream}
      or die "cannot find remote for upstream $upstream\n";

    $local_conf->{path} //= "" . path($base_dir)->child($remote->repo);
  }

  die "could not determine local path to use\n" unless $local_conf->{path};

  return $local_conf;
}

1;
