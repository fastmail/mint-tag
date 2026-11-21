use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::Deep;
use Test::More;

use Test::MintTag::Repo;

# These tests are about how mint-tag finds, makes, and cleans up the local
# repository that it works in.

# Clone a world's upstream forge into the place where mint-tag will look for
# its local repository, the way a person setting things up by hand might.
# The %remotes are (name => forge name) for the remotes to give the clone, and
# the first one is the one that gets cloned.
my sub clone_by_hand ($world, @remotes) {
  my $local = $world->local_repo;
  $local->path->parent->mkpath;

  my ($name, $forge_name) = splice @remotes, 0, 2;

  Test::MintTag::Repo->new({ path => $local->path->parent })->git(
    qw(clone --quiet -o), $name,
    $world->forge($forge_name)->clone_url,
    $local->path->stringify,
  );

  while (my ($name, $forge_name) = splice @remotes, 0, 2) {
    $local->git(qw(remote add), $name, $world->forge($forge_name)->clone_url);
  }

  return $local;
}

my sub remotes_of ($repo) {
  return { map {; $_ => $repo->git(qw(remote get-url), $_) } split /\n/, $repo->git('remote') };
}

my %ONE_OF_EACH = (
  github => [ mr(101, alice => 'jmap-fix') ],
  gitlab => [ mr(7, carol => 'fm-tweaks') ],
);

subtest "cloning" => sub {
  my ($world, $result) = build_ok "the local repository is cloned if it's not there" => {
    config => cyrus_config(),
    mrs    => \%ONE_OF_EACH,
    expect => {
      merged => [ 'github!101', 'gitlab!7' ],
      logs   => [
        qr{cloning into .+/local from github/master},
        qr{adding missing remote for gitlab},
        qr{fetching tags for github},
        qr{fetching tags for gitlab},
      ],
      no_logs => [ qr{adding missing remote for github} ],
    },
  };

  cmp_deeply(
    remotes_of($world->local_repo),
    {
      github => $world->forge('github')->clone_url,
      gitlab => $world->forge('gitlab')->clone_url,
    },
    "the clone has a remote for each remote in the config",
  );

  mint_ok $world, "the local repository is reused if it is there" => {
    expect => {
      merged  => [ 'github!101', 'gitlab!7' ],
      no_logs => [ qr{cloning into}, qr{adding missing remote} ],
    },
  };

  my $deep = Path::Tiny->tempdir->child(qw(a few levels down))->stringify;

  build_ok "missing directories above the local repository are made" => {
    config => cyrus_config(local => { path => $deep }),
    mrs    => \%ONE_OF_EACH,
    expect => { merged => [ 'github!101', 'gitlab!7' ] },
  };

  build_ok "the local repository is not cloned unless that's turned on" => {
    config => cyrus_config(local => { clone => \0 }),
    mrs    => \%ONE_OF_EACH,
    expect => {
      error => qr{local path .+/local does not exist! \(maybe you should set clone = true\)},
    },
  };
};

subtest "a repository that somebody else made" => sub {
  my $no_clone = cyrus_config(local => { clone => \0 });

  {
    my $world = new_world(config => $no_clone, mrs => \%ONE_OF_EACH);
    clone_by_hand($world, github => 'github');

    mint_ok $world, "missing remotes are added" => {
      expect => {
        merged  => [ 'github!101', 'gitlab!7' ],
        logs    => [ qr{adding missing remote for gitlab} ],
        no_logs => [ qr{cloning into}, qr{adding missing remote for github} ],
      },
    };
  }

  {
    my $world = new_world(config => $no_clone, mrs => \%ONE_OF_EACH);
    my $local = clone_by_hand($world, github => 'github', gitlab => 'gitlab', other => 'gitlab');

    mint_ok $world, "extra remotes are left alone" => {
      expect => {
        merged  => [ 'github!101', 'gitlab!7' ],
        no_logs => [ qr{adding missing remote} ],
      },
    };

    ok(remotes_of($local)->{other}, "the extra remote is still there");
  }

  {
    my $world = new_world(config => $no_clone, mrs => \%ONE_OF_EACH);
    clone_by_hand($world, github => 'github', gitlab => 'github');

    mint_ok $world, "a remote with the wrong URL is fatal" => {
      expect => { error => qr{mismatched remote gitlab: have \S+github\.git, want \S+gitlab\.git} },
    };
  }
};

subtest "starting from a clean slate" => sub {
  my $world = new_world(config => cyrus_config(), mrs => \%ONE_OF_EACH);
  my $local = $world->local_repo;
  my $github = $world->forge('github');

  my $first = mint_ok $world, "the first build" => {
    expect => { history => [ [ 'base', 'github!101' ], 'gitlab!7' ] },
  };

  is($first->rev_for('base'), $github->repo->rev('master'), "the base is the upstream's master");

  # Leave a mess.
  $local->path->child('README')->spew_utf8("This file has been scribbled on.\n");
  $local->path->child('untracked.txt')->spew_utf8("Nobody knows this file.\n");

  my $master = $github->add_upstream_commit(
    message => "append: return three\n",
    files   => { 'imap/append.c' => "/* append */\nint append(void) {\n  return 3;\n}\n" },
  );

  my $second = mint_ok $world, "a build after the upstream has moved" => {
    expect => { history => [ [ 'base', 'github!101' ], 'gitlab!7' ] },
  };

  is($second->rev_for('base'), $master, "the new build is based on the new master");

  is(
    $local->path->child('README')->slurp_utf8,
    "This is a pretend mail server.\n",
    "changes to tracked files are thrown away",
  );

  ok($local->path->child('untracked.txt')->exists, "untracked files are left alone");

  ok(
    ! $local->is_ancestor($first->rev_for('head'), 'HEAD'),
    "the old build is not part of the new build",
  );
};

subtest "an abandoned rebase" => sub {
  my $world = new_world(config => cyrus_config(), mrs => \%ONE_OF_EACH);
  mint_ok $world, "the first build" => { expect => {} };

  # We don't make a real stuck rebase, just the directory that git would leave
  # behind if there were one.
  my $rebase_dir = $world->local_repo->path->child('.git', 'rebase-merge');
  $rebase_dir->mkpath;

  mint_ok $world, "a build with a leftover rebase directory" => {
    expect => {
      merged => [ 'github!101', 'gitlab!7' ],
      logs   => [ qr{removing existing rebase-merge directory at \.git/rebase-merge} ],
    },
  };

  ok(! $rebase_dir->exists, "the directory is gone");
};

done_testing;
