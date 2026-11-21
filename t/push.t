use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::Deep;
use Test::More;

# These tests are about everything mint-tag does to a remote after it's done
# building: pushing tags and branches, pushing rebased merge requests back to
# where they came from, and cleaning up.

my $FAILED_PUSH = qr/encountered error while running git push/;

subtest "pushing tags" => sub {
  my ($world) = build_ok "the tag is pushed where the step says, and nowhere else" => {
    config => cyrus_config(),
    mrs    => { github => [ mr(101, alice => 'jmap-fix') ] },
    expect => {
      tag  => qr/\Afm-20261120\.001-g\w{8}\z/,
      logs => [ qr/capstone: pushing tag to remote gitlab/ ],
      remote_tags => {
        github => [ ],
        gitlab => [ re(qr/\Afm-20261120\.001-g\w{8}\z/) ],
      },
      remote_branches => {
        github => { deploy => undef },
        gitlab => { deploy => undef },
      },
    },
  };

  my $gitlab = $world->forge('gitlab')->repo;
  my ($tag)  = $gitlab->tags;

  is($gitlab->rev($tag), $world->local_repo->rev($tag), "the remote's tag points where ours does");
  is($gitlab->message($tag), $world->local_repo->message($tag), "...and has our annotation");

  mint_ok $world, "when nothing has changed, the same tag is pushed again, harmlessly" => {
    expect => {
      tag  => undef,
      logs => [ qr/capstone: pushing tag to remote gitlab/ ],
      remote_tags => { gitlab => [ $tag ] },
    },
  };

  build_ok "a step that makes a tag doesn't have to push it" => {
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
    expect => {
      tag         => qr/\Abuild-/,
      no_logs     => [ qr/pushing/ ],
      remote_tags => { forge => [ ] },
    },
  };
};

subtest "pushing a branch" => sub {
  my sub beta_config ($force) {
    simple_config(push_spec => { remote => 'forge', branch => 'beta', force => $force });
  }

  my %mrs = (forge => [ mr(1, alice => 'one') ]);

  my ($world) = build_ok "the build is pushed to the named branch" => {
    config => beta_config(\1),
    mrs    => \%mrs,
    expect => {
      logs => [ qr{build: force-pushing branch to remote forge/beta} ],
      remote_branches => { forge => { beta => 'head', master => 'base', deploy => undef } },
      mr_states => { 'forge!1' => 'opened' },
    },
  };

  $world->forge('forge')->update_mr(1);

  mint_ok $world, "the next build replaces the branch, when forcing" => {
    expect => { remote_branches => { forge => { beta => 'head' } } },
  };

  $world->forge('forge')->repo->commit(
    ref    => 'refs/heads/beta',
    parent => $world->forge('forge')->repo->rev('beta'),
    epoch  => 1_700_000_000,
    files  => { 'hotfix.txt' => "somebody pushed this to beta by hand\n" },
  );

  mint_ok $world, "the next build replaces the branch, even if somebody else pushed to it" => {
    expect => { remote_branches => { forge => { beta => 'head' } } },
  };

  ($world) = build_ok "the build is pushed to the named branch, without forcing" => {
    config => beta_config(\0),
    mrs    => \%mrs,
    expect => {
      logs => [ qr{build: pushing branch to remote forge/beta} ],
      remote_branches => { forge => { beta => 'head' } },
    },
  };

  mint_ok $world, "pushing the same thing again is fine" => {
    expect => { remote_branches => { forge => { beta => 'head' } } },
  };

  $world->forge('forge')->update_mr(1);

  my $beta = $world->forge('forge')->repo->rev('beta');

  mint_ok $world, "the next build can't replace the branch, when not forcing" => {
    expect => { error => $FAILED_PUSH },
  };

  is($world->forge('forge')->repo->rev('beta'), $beta, "the remote branch didn't move");

  build_ok "the build can be pushed to a branch named for the target branch" => {
    config => simple_config(push_spec => { remote => 'forge', use_matching_branch => \1 }),
    mrs    => \%mrs,
    expect => {
      logs => [ qr{build: pushing branch to remote forge/deploy} ],
      remote_branches => { forge => { deploy => 'head' } },
    },
  };

  build_ok "a rebasing step pushes what it built, not the local target branch" => {
    config => simple_config(
      rebase    => \1,
      push_spec => { remote => 'forge', branch => 'beta', force => \1 },
    ),
    mrs    => \%mrs,
    expect => {
      history => [ 'base', 'forge!1' ],
      remote_branches => { forge => { beta => 'head' } },
    },
  };

  build_ok "every step can push somewhere" => {
    config => cyrus_config(
      github   => { push_spec => { remote => 'gitlab', branch => 'upstream-only', force => \1 } },
      capstone => { push_spec => { remote => 'gitlab', branch => 'everything', force => \1 } },
    ),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix') ],
      gitlab => [ mr(7, carol => 'fm-tweaks') ],
    },
    expect => {
      history => [ [ 'base', 'github!101' ], 'gitlab!7' ],
      remote_branches => {
        github => { 'upstream-only' => undef, everything => undef },
        gitlab => { 'upstream-only' => 'head^1', everything => 'head' },
      },
    },
  };
};

# A release that rebases, and then pushes the rebased merge requests back to
# their source branches, so that the forge will see that they've been merged.
my sub rebasing_release (%step) {
  return release_config(
    use_semilinear_merge        => \1,
    force_push_rebased_branches => \1,
    %step,
  );
}

my @TWO_OLD_MRS = (
  mr(1, alice => 'one', base => 'master~2', delete_branch => 1),
  mr(2, bob   => 'two', base => 'master~1', fork => 1),
);

subtest "pushing rebased merge requests back to their branches" => sub {
  my ($world, $result) = build_ok "rebased branches are pushed, and then the merge" => {
    config => rebasing_release(),
    mrs    => { forge => [ @TWO_OLD_MRS ] },
    expect => {
      merged => [ 'forge!1', 'forge!2' ],
      slept  => 0,
      logs   => [
        qr{force-pushing branch to file://\S+/forge\.git/one},
        qr{force-pushing branch to file://\S+/forge-fork-bob\.git/two},
        qr{waiting for remote to notice that forge!1 has been updated},
        qr{waiting for remote to notice that forge!2 has been updated},
      ],
      remote_branches => { forge => { master => 'head', one => 'forge!1', two => undef } },
      mr_states => { 'forge!1' => 'merged', 'forge!2' => 'merged' },
    },
  };

  my $forge = $world->forge('forge');

  for my $number (1, 2) {
    is(
      $forge->mr_data($number)->{sha},
      $result->rev_for("forge!$number"),
      "the forge has the rebased head of forge!$number",
    );
  }

  build_ok "without force_push_rebased_branches, the forge keeps the old heads" => {
    config => rebasing_release(force_push_rebased_branches => \0),
    mrs    => { forge => [ @TWO_OLD_MRS ] },
    expect => {
      merged    => [ 'forge!1', 'forge!2' ],
      no_logs   => [ qr{force-pushing branch} ],
      mr_states => { 'forge!1' => 'opened', 'forge!2' => 'opened' },
      remote_branches => { forge => { master => 'head' } },
    },
  };

  build_ok "merge requests that weren't rebased aren't pushed back" => {
    config => release_config(force_push_rebased_branches => \1),
    mrs    => { forge => [ @TWO_OLD_MRS ] },
    expect => {
      merged    => [ 'forge!1', 'forge!2' ],
      no_logs   => [ qr{force-pushing branch} ],
      mr_states => { 'forge!1' => 'merged', 'forge!2' => 'merged' },
    },
  };
};

subtest "pushing rebased merge requests back, when it goes wrong" => sub {
  my $world = new_world(config => rebasing_release(), mrs => { forge => [ @TWO_OLD_MRS ] });
  my $forge = $world->forge('forge');

  $forge->is_oblivious(1);

  mint_ok $world, "if the forge never notices the push, we give up before pushing the merge" => {
    expect => {
      error => qr{could not force-push to forge/one: .*remote head for forge!1 not up to date after 30 attempts}s,
      slept => 62,
      remote_branches => { forge => { master => 'base' } },
    },
  };

  $forge->is_oblivious(0);

  mint_ok $world, "once the forge is paying attention again, the release goes ahead" => {
    expect => {
      merged    => [ 'forge!1', 'forge!2' ],
      slept     => 0,
      mr_states => { 'forge!1' => 'merged', 'forge!2' => 'merged' },
      remote_branches => { forge => { master => 'head' } },
    },
  };

  $world = new_world(config => rebasing_release(), mrs => { forge => [ @TWO_OLD_MRS ] });

  # Bob's fork goes missing.
  my $fork = Path::Tiny::path($world->forge('forge')->mr_data(2)->{source_url} =~ s{\Afile://}{}r);
  $fork->move("$fork.gone");

  mint_ok $world, "if a branch can't be pushed, we give up before pushing the merge" => {
    expect => {
      error => qr{could not force-push to forge/two},
      remote_branches => { forge => { master => 'base' } },
    },
  };
};

subtest "deleting the source branches of merged merge requests" => sub {
  my @mrs = (
    mr(1, alice => 'delete-me', delete_branch => 1),
    mr(2, bob   => 'delete-me-too', delete_branch => 1, fork => 1),
    mr(3, carol => 'keep-me'),
  );

  my ($world) = build_ok "branches are deleted if the merge request asks for it" => {
    config => release_config(allow_source_branch_deletion => \1),
    mrs    => { forge => [ @mrs ] },
    expect => {
      merged => [ 'forge!1', 'forge!2', 'forge!3' ],
      slept  => 0,
      logs   => [
        qr{deleting merged branch file://\S+/forge\.git/delete-me\z},
        qr{deleting merged branch file://\S+/forge-fork-bob\.git/delete-me-too},
        qr{waiting for remote to notice that forge!1 has been merged},
      ],
      no_logs => [ qr{keep-me} ],
      remote_branches => {
        forge => { master => 'head', 'delete-me' => undef, 'keep-me' => 'forge!3' },
      },
    },
  };

  my $fork = Test::MintTag::Repo->new({
    path => Path::Tiny::path($world->forge('forge')->mr_data(2)->{source_url} =~ s{\Afile://}{}r),
  });

  is($fork->rev('refs/heads/delete-me-too'), undef, "the branch in the fork is gone, too");

  build_ok "branches are not deleted unless the step allows it" => {
    config => release_config(),
    mrs    => { forge => [ @mrs ] },
    expect => {
      merged  => [ 'forge!1', 'forge!2', 'forge!3' ],
      no_logs => [ qr{deleting merged branch} ],
      remote_branches => { forge => { master => 'head', 'delete-me' => 'forge!1' } },
    },
  };

  # The merge isn't pushed to master here, so the merge requests are never
  # merged, as far as the forge can tell.
  build_ok "branches are not deleted if the forge doesn't say they're merged" => {
    config => simple_config(
      allow_source_branch_deletion => \1,
      push_spec => { remote => 'forge', branch => 'beta', force => \1 },
    ),
    mrs    => { forge => [ @mrs ] },
    expect => {
      merged => [ 'forge!1', 'forge!2', 'forge!3' ],
      slept  => 124,
      logs   => [ qr{could not delete remote branch delete-me at \S+forge\.git: } ],
      remote_branches => { forge => { beta => 'head', 'delete-me' => 'forge!1' } },
    },
  };
};

subtest "cleaning up old tags" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build', push_tag_to => 'forge', cleanup_tag_days => 7),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
  );

  my $forge = $world->forge('forge');

  # Run a build on the given date, and then check that the local repository
  # and the forge both have exactly the given tags, less their -gSHA suffixes.
  my sub tags_after_build_on ($date, $desc, $want, $extra = {}) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    $world->set_date($date);

    my $result = mint_ok $world, "$date: $desc" => { expect => $extra };

    for my $repo ($world->local_repo, $forge->repo) {
      my $where = $repo == $forge->repo ? 'the forge' : 'the local repository';
      is_deeply([ map {; s/-g\w{8}\z//r } sort $repo->tags ], $want, "...tags in $where");
    }

    return $result;
  }

  tags_after_build_on('2026-11-01', "the first build", [ 'build-20261101.001' ],
    { logs => [ qr/Deleting 0 old tags/ ] });

  $forge->update_mr(1);
  tags_after_build_on('2026-11-02', "a second build", [
    'build-20261101.001',
    'build-20261102.001',
  ]);

  $forge->update_mr(1);
  tags_after_build_on('2026-11-08', "a build when the oldest tag is not quite old enough", [
    'build-20261101.001',
    'build-20261102.001',
    'build-20261108.001',
  ]);

  tags_after_build_on('2026-11-09', "a build when the oldest tag is old enough", [
    'build-20261102.001',
    'build-20261108.001',
  ], {
    tag  => undef,
    logs => [ qr/Deleting 1 old tags/, qr/Deleting tags: build-20261101\.001-g\w{8}\z/ ],
  });

  tags_after_build_on('2026-12-25', "a build when every tag is old, and there's no new one", [
    'build-20261108.001',
  ], {
    tag  => undef,
    logs => [ qr/Keeping most recent tag build-20261108\.001-g\w{8} to avoid deleting all/ ],
  });

  $forge->update_mr(1);
  tags_after_build_on('2026-12-26', "a build when every tag but the new one is old", [
    'build-20261108.001',
    'build-20261226.001',
  ], {
    logs => [ qr/Keeping most recent tag build-20261108\.001-g\w{8} to avoid deleting all/ ],
  });

  # Old tags that merely start with our prefix aren't ours to clean up.
  $forge->repo->git(qw(tag builders-notes master));
  $forge->repo->git(qw(tag other-notes master));

  tags_after_build_on('2026-12-27', "a build when somebody else has tags that look like ours", [
    'build-20261108.001',
    'build-20261226.001',
    'builders-notes',
    'other-notes',
  ], {
    no_logs => [ qr/builders-notes/ ],
  });
};

subtest "cleaning up tags that aren't pushed anywhere" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build', cleanup_tag_days => 7),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
  );

  for my $date (qw( 2026-11-01 2026-11-02 2026-12-25 )) {
    $world->set_date($date);
    $world->forge('forge')->update_mr(1);
    mint_ok $world, "a build on $date" => { expect => { no_logs => [ qr/Deleting/ ] } };
  }

  is($world->local_repo->tags, 3, "tags are never cleaned up unless they're pushed somewhere");
};

done_testing;
