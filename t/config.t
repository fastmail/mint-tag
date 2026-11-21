use v5.36;

use lib 't/lib';
use Test::MintTag;

use Path::Tiny ();
use Test::Deep;
use Test::More;
use Try::Tiny;

use App::MintTag::Config;
use Test::MintTag::Forge;

# These tests load config files, but never run mint-tag.  Loading a config
# builds remotes, and sometimes asks them a question, so there's one forge that
# stands behind every remote in every config here.
my $TEMPDIR = Path::Tiny->tempdir;
my $FORGE   = Test::MintTag::Forge->new({ name => 'forge', root => $TEMPDIR });

# These build one of the stock configs, give it a local path, and then pass it
# to $tweak, which can change it in place to make it interesting.
my sub tweaked ($config, $tweak) {
  $config->{local}{path} = '/local/path';
  $tweak->($config) if $tweak;
  return $config;
}

my sub simple ($tweak = undef) { tweaked(simple_config(), $tweak) }
my sub cyrus  ($tweak = undef) { tweaked(cyrus_config(),  $tweak) }

# A config for release mode, which looks pretty different from the others.
my sub release ($tweak = undef) {
  return tweaked({
    meta   => { committer_email => 'minttag@example.com', release_mode => \1 },
    local  => { upstream_remote => 'forge', use_upstream_default_branch => \1 },
    remote => { forge => { repo => 'example/project' } },
    release_mode => { remote => 'forge', label => 'release-me' },
  }, $tweak);
}

my sub load ($config, $repo = undef) {
  for my $name (keys $config->{remote}->%*) {
    my $remote = $config->{remote}{$name};

    $remote->{interface_class} //= 'Test::MintTag::Remote' unless $remote->{no_class};
    $remote->{api_url}         //= "mock://config-test/$name";
    $remote->{api_key}         //= 'hunter2';

    delete $remote->{no_class};

    $Test::MintTag::Remote::FORGE_FOR{ $remote->{api_url} } = $FORGE;
  }

  my $file = $TEMPDIR->child('config.toml');
  $file->spew_utf8(Test::MintTag::World::toml_for($config));

  return App::MintTag::Config->from_file("$file", $repo);
}

# Load a config and check on what we got.  The expectations are:
#
#   config  - a hashref of (method => result) for the config object
#   steps   - an arrayref, with one hashref of (method => result) per step
#   remotes - a hashref of (remote name => { method => result })
#   repo    - not an expectation: the repo name to pass, as with --repo
#
# Results are compared with Test::Deep.
my sub config_ok ($desc, $config, $want) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  subtest $desc => sub {
    my $got = try { load($config, $want->{repo}) } catch { fail("loaded config"); diag $_; undef };
    return unless $got;

    cmp_deeply($got, methods($want->{config}->%*), "config") if $want->{config};

    if ($want->{steps}) {
      cmp_deeply(
        [ $got->steps ],
        [ map {; methods(%$_) } $want->{steps}->@* ],
        "steps",
      );
    }

    for my $name (sort keys(($want->{remotes} // {})->%*)) {
      cmp_deeply(
        $got->remote_named($name),
        methods($want->{remotes}{$name}->%*),
        "remote $name",
      );
    }
  };
}

my sub config_dies ($desc, $config, $want, $repo = undef) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $error = try { load($config, $repo); undef } catch { $_ };
  like($error // '(no error)', $want, $desc);
}

my sub remote ($name) { methods(name => $name) }

my $TRUE  = bool(1);
my $FALSE = bool(0);

subtest "configs that load" => sub {
  config_ok "the Cyrus config" => cyrus(), {
    config => {
      committer_name     => 'MintTag',
      committer_email    => 'minttag@example.com',
      local_repo_dir     => '/local/path',
      target_branch_name => 'deploy',
      upstream_base      => 'github/master',
      upstream_remote_name => 'github',
      upstream_branch_name => 'master',
      should_clone       => $FALSE,
      is_release_mode    => $FALSE,
      remotes            => { github => remote('github'), gitlab => remote('gitlab') },
    },
    steps => [
      {
        name   => 'github',
        remote => remote('github'),
        label  => 'include-in-fastmail',
        trusted_org => 'fastmail',
        tag_prefix  => undef,
        push_tag_to => undef,
        rebase      => $FALSE,
      },
      {
        name   => 'capstone',
        remote => remote('gitlab'),
        label  => 'include-in-fastmail',
        trusted_org => 'fastmail',
        tag_prefix  => 'fm',
        push_tag_to => remote('gitlab'),
        rebase      => $TRUE,
        has_push_spec => $FALSE,
        use_semilinear_merge => $FALSE,
        force_push_rebased_branches  => $FALSE,
        allow_source_branch_deletion => $FALSE,
        cleanup_tag_days => 0,
      },
    ],
    remotes => {
      github => { repo => 'cyrusimap/cyrus-imapd', api_key => 'hunter2' },
      gitlab => { repo => 'fastmail/cyrus-imapd',  should_fetch_ssh_url_for_forks => $FALSE },
    },
  };

  config_ok "a default committer_name" => simple(sub ($c) {
    delete $c->{meta}{committer_name};
  }), {
    config => { committer_name => 'MintTag', committer_email => 'minttag@example.com' },
  };

  config_ok "a committer_name that isn't the default" => simple(sub ($c) {
    $c->{meta}{committer_name} = 'Tag Minter';
  }), {
    config => { committer_name => 'Tag Minter' },
  };

  config_ok "local.clone" => simple(sub ($c) { $c->{local}{clone} = \1 }), {
    config => { should_clone => $TRUE },
  };

  config_ok "a push_spec with a branch" => simple(sub ($c) {
    $c->{build_steps}[0]{push_spec} = { remote => 'forge', branch => 'beta', force => \1 };
  }), {
    steps => [
      { push_spec => { remote => remote('forge'), branch => 'beta', force => $TRUE } },
    ],
  };

  config_ok "a push_spec with use_matching_branch" => simple(sub ($c) {
    $c->{build_steps}[0]{push_spec} = { remote => 'forge', use_matching_branch => \1 };
  }), {
    steps => [
      { push_spec => { remote => remote('forge'), use_matching_branch => $TRUE } },
    ],
  };

  config_ok "force-pushing rebased branches" => cyrus(sub ($c) {
    $c->{build_steps}[1]{force_push_rebased_branches} = \1;
  }), {
    remotes => {
      github => { should_fetch_ssh_url_for_forks => $FALSE },
      gitlab => { should_fetch_ssh_url_for_forks => $TRUE  },
    },
  };

  {
    local $ENV{MINTTAG_TEST_API_KEY} = 'from-the-environment';

    config_ok "an api_key from the environment" => simple(sub ($c) {
      $c->{remote}{forge}{api_key} = 'ENV:MINTTAG_TEST_API_KEY';
    }), {
      remotes => { forge => { api_key => 'from-the-environment' } },
    };
  }

  config_ok "a local path made from base_dir" => simple(sub ($c) {
    delete $c->{local}{path};
    $c->{local}{base_dir} = '/base/dir';
  }), {
    config => { local_repo_dir => '/base/dir/example/project' },
  };

  config_ok "a local path wins over base_dir" => simple(sub ($c) {
    $c->{local}{base_dir} = '/base/dir';
  }), {
    config => { local_repo_dir => '/local/path' },
  };

  config_ok "the upstream's default branch" => simple(sub ($c) {
    $c->{local} = {
      path => '/local/path',
      upstream_remote => 'forge',
      use_upstream_default_branch => \1,
    };
  }), {
    config => { upstream_base => 'forge/master', target_branch_name => 'master' },
  };

  config_ok "release mode" => release(), {
    config => {
      is_release_mode    => $TRUE,
      should_clone       => $TRUE,
      upstream_base      => 'forge/master',
      target_branch_name => 'master',
    },
    steps => [
      {
        name   => 'build-release-branch',
        remote => remote('forge'),
        label  => 'release-me',
        push_spec => { remote => remote('forge'), use_matching_branch => 1, force => 0 },
      },
    ],
  };

  config_ok "release mode, with the repo given at runtime" => release(sub ($c) {
    delete $c->{remote}{forge}{repo};
    delete $c->{local}{path};
    $c->{local}{base_dir} = '/base/dir';
  }), {
    repo    => 'some/repo',
    config  => { local_repo_dir => '/base/dir/some/repo' },
    remotes => { forge => { repo => 'some/repo' } },
  };

  config_ok "release mode, where the config's repo beats the runtime one" => release(), {
    repo    => 'some/repo',
    remotes => { forge => { repo => 'example/project' } },
  };

  config_ok "release mode, with extra step config" => release(sub ($c) {
    $c->{release_mode}{use_semilinear_merge} = \1;
    $c->{release_mode}{label} = \0;
  }), {
    steps => [
      { use_semilinear_merge => $TRUE, label => all($FALSE, code(sub { JSON::MaybeXS::is_bool($_[0]) })) },
    ],
  };
};

# This pins down something that happens now, but looks like an accident.
subtest "configs that load, surprisingly" => sub {
  config_ok "a config with no build steps" => simple(sub ($c) {
    delete $c->{build_steps};
  }), {
    steps => [ ],
  };
};

subtest "configs that don't load" => sub {
  config_dies "no committer_email",
    simple(sub ($c) { delete $c->{meta}{committer_email} }),
    qr/\ANo value found for meta\.committer_email in config; giving up\.\n\z/;

  config_dies "no committer at all",
    simple(sub ($c) { delete $c->{meta} }),
    qr/No value found for meta\.committer_email.+\nYou might also consider setting meta\.committer_name/;

  config_dies "a remote with no interface_class",
    simple(sub ($c) { $c->{remote}{forge}{no_class} = 1 }),
    qr/no interface_class found for remote forge/;

  {
    local $ENV{MINTTAG_TEST_API_KEY};

    config_dies "an api_key from the environment, but it's not there",
      simple(sub ($c) { $c->{remote}{forge}{api_key} = 'ENV:MINTTAG_TEST_API_KEY' }),
      qr/looking for an environment variable MINTTAG_TEST_API_KEY, but didn't find one/;
  }

  config_dies "a step with no name",
    simple(sub ($c) { delete $c->{build_steps}[0]{name} }),
    qr/Missing required arguments: name/;

  config_dies "a step with no label",
    simple(sub ($c) { delete $c->{build_steps}[0]{label} }),
    qr/Missing required arguments: label/;

  config_dies "a step with an unknown remote",
    simple(sub ($c) { $c->{build_steps}[0]{remote} = 'nope' }),
    qr/No matching remote found for nope!/;

  config_dies "a step that pushes tags to an unknown remote",
    simple(sub ($c) { $c->{build_steps}[0]->@{qw(tag_prefix push_tag_to)} = qw(tag nope) }),
    qr/No matching remote found for nope!/;

  config_dies "a step that pushes tags but doesn't make them",
    simple(sub ($c) { $c->{build_steps}[0]{push_tag_to} = 'forge' }),
    qr/build doesn't make sense: you defined a tag push target but no tag prefix/;

  config_dies "a push_spec with no remote",
    simple(sub ($c) { $c->{build_steps}[0]{push_spec} = { branch => 'beta' } }),
    qr/push_spec must have 'remote' key/;

  config_dies "a push_spec with an unknown remote",
    simple(sub ($c) { $c->{build_steps}[0]{push_spec} = { remote => 'nope', branch => 'beta' } }),
    qr/No matching remote found for nope!/;

  config_dies "a push_spec with no branch",
    simple(sub ($c) { $c->{build_steps}[0]{push_spec} = { remote => 'forge' } }),
    qr/push_spec must have either 'branch' or 'use_matching_branch' keys/;

  config_dies "a push_spec with two ideas about the branch",
    simple(sub ($c) {
      $c->{build_steps}[0]{push_spec} = {
        remote => 'forge', branch => 'beta', use_matching_branch => \1,
      };
    }),
    qr/push_spec must have either 'branch' or 'use_matching_branch' keys/;

  config_dies "no upstream_base",
    simple(sub ($c) { delete $c->{local}{upstream_base} }),
    qr/cannot figure out upstream base/;

  config_dies "the default branch of an unknown upstream",
    simple(sub ($c) {
      $c->{local} = { path => '/x', upstream_remote => 'nope', use_upstream_default_branch => \1 };
    }),
    qr/cannot find remote for upstream nope/;

  config_dies "no local path",
    simple(sub ($c) { delete $c->{local}{path} }),
    qr/could not determine local path to use/;

  config_dies "base_dir with an unknown upstream",
    simple(sub ($c) {
      delete $c->{local}{path};
      $c->{local}{base_dir} = '/base/dir';
      $c->{local}{upstream_base} = 'nope/master';
    }),
    qr/cannot find remote for upstream nope/;

  config_dies "release mode with no release_mode section",
    release(sub ($c) { delete $c->{release_mode} }),
    qr/missing release_mode config/;

  config_dies "release mode with no remote",
    release(sub ($c) { delete $c->{release_mode}{remote} }),
    qr/missing remote name for release_mode/;

  config_dies "release mode with no label",
    release(sub ($c) { delete $c->{release_mode}{label} }),
    qr/missing label name for release_mode/;

  config_dies "release mode with build steps",
    release(sub ($c) { $c->{build_steps} = simple_config()->{build_steps} }),
    qr/release_mode config cannot have build_steps/;

  config_dies "release mode with no repo",
    release(sub ($c) { delete $c->{remote}{forge}{repo} }),
    qr/could not determine remote repo to use for release mode/;
};

done_testing;
