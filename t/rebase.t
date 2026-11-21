use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

# Two merge requests that merge cleanly, but aren't based on the tip of the
# upstream's master, so that a rebase has something to do.
my @OLD_MRS = (
  mr(1, alice => 'one', base => 'master~2'),
  mr(2, bob   => 'two', base => 'master~1', fork => 1),
);

# A merge request that changes a line that master has also changed since the
# merge request was made.
my $STALE_MR = mr(3, carol => 'stale',
  base  => 'master~2',
  files => { 'imap/mailbox.c' => "/* mailbox */\nint mailbox(void) {\n  return 7;\n}\n" },
);

subtest "rebasing before an octopus merge" => sub {
  my ($world, $result) = build_ok "merge requests are rebased onto the base, then merged" => {
    config => simple_config(rebase => \1),
    mrs    => { forge => [ @OLD_MRS ] },
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      history => [ 'base', { 'forge!1' => [ 'base' ] }, { 'forge!2' => [ 'base' ] } ],
      message => qr/\AMerge 2 tagged MRs\n/,
    },
  };

  my $forge = $world->forge('forge');
  my $local = $world->local_repo;

  for my $number (1, 2) {
    my $mr = $result->mr("forge!$number");

    isnt($mr->sha, $forge->mr_data($number)->{sha}, "forge!$number was rewritten locally");
    is($mr->merge_base, $result->rev_for('base'), "...and its merge base is the build's base");
    ok($mr->has_been_rebased_locally, "...and it knows it");

    is(
      $local->git(qw(log -1 --format=%an/%cn), $mr->sha),
      $mr->author . "/MintTag",
      "...and it kept its author, but MintTag is the committer",
    );
  }

  is($forge->mr_data(1)->{sha}, $forge->repo->rev('refs/heads/one'), "the forge's branch didn't move");

  # This is how it works, whether or not it's how it should work: rebasing
  # leaves us on a detached HEAD, so the merge isn't on the target branch.
  is($local->rev('deploy'), $result->rev_for('base'), "the target branch is left at the base");
  is($local->git(qw(rev-parse --abbrev-ref HEAD)), 'HEAD', "the build is on a detached HEAD");
};

subtest "a merge request with several commits" => sub {
  my $world = new_world(
    config => simple_config(rebase => \1),
    mrs    => { forge => [ mr(1, alice => 'one', base => 'master~2') ] },
  );

  $world->forge('forge')->update_mr(1) for 1..2;

  mint_ok $world, "every commit of a three-commit merge request is rebased" => {
    expect => {
      history => [ 'base', { 'forge!1' => [ [ [ 'base' ] ] ] } ],
    },
  };
};

subtest "rebasing onto an earlier step" => sub {
  my ($world, $result) = build_ok "the second step's merge requests go on top of the first's" => {
    config => cyrus_config(),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix') ],
      gitlab => [ mr(7, carol => 'fm-tweaks'), mr(8, bob => 'more-tweaks', base => 'master~1') ],
    },
    expect => {
      merged  => [ 'github!101', 'gitlab!7', 'gitlab!8' ],
      history => [
        [ 'base', { 'github!101' => [ 'base' ] } ],
        { 'gitlab!7' => [ [ 'base', 'github!101' ] ] },
        { 'gitlab!8' => [ [ 'base', 'github!101' ] ] },
      ],
      tag => qr/\Afm-20261120\.001-g\w{8}\z/,
    },
  };

  # Rebasing makes new commits, but if nothing has changed, they should be the
  # very same new commits every time.
  $world->set_date('2026-11-23');

  my $later = mint_ok $world, "the same build, days later" => {
    expect => { tag => undef, logs => [ qr/already tagged as fm-20261120\.001/ ] },
  };

  is($later->rev_for('head'), $result->rev_for('head'), "it builds the same commit");

  for my $ident ('gitlab!7', 'gitlab!8') {
    is($later->rev_for($ident), $result->rev_for($ident), "$ident is rebased to the same commit");
  }

  $world->forge('gitlab')->update_mr(8);

  my $changed = mint_ok $world, "a build after a merge request changes" => {
    expect => { tag => qr/\Afm-20261123\.001-g\w{8}\z/ },
  };

  is($changed->rev_for('gitlab!7'), $result->rev_for('gitlab!7'),
    "the merge request that didn't change is rebased to the same commit");
};

subtest "a rebase that fails" => sub {
  my ($world, $result) = build_ok "a merge request that can't be rebased is fatal" => {
    config => simple_config(rebase => \1, tag_prefix => 'build'),
    mrs    => { forge => [ @OLD_MRS, $STALE_MR ] },
    expect => {
      error => qr/Error rebasing forge!3 \(\w{40}\) onto HEAD \(\w{8}\); bailing out!/,
      tag   => undef,
    },
  };

  my $rebase_dir = $world->local_repo->path->child('.git', 'rebase-merge');
  ok($rebase_dir->is_dir, "the failed rebase is left in progress");

  mint_ok $world, "the next build cleans up, and fails the same way" => {
    expect => {
      error => qr/Error rebasing forge!3/,
      logs  => [ qr/removing existing rebase-merge directory/ ],
    },
  };

  $world->forge('forge')->close_mr(3);

  mint_ok $world, "once the bad merge request is gone, we can build again" => {
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      tag     => qr/\Abuild-20261120\.001-g\w{8}\z/,
    },
  };
};

subtest "semilinear merges" => sub {
  my ($world, $result) = build_ok "each merge request is rebased onto the last merge" => {
    config => simple_config(use_semilinear_merge => \1),
    mrs    => { forge => [ @OLD_MRS ] },
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      history => [
        [ 'base', { 'forge!1' => [ 'base' ] } ],
        { 'forge!2' => [ [ 'base', 'forge!1' ] ] },
      ],
      message => qr{\AMerge branch 'bob/two' into 'deploy'\n\nSee https://forge\.example\.com/merge-requests/2\n\z},
      logs    => [
        qr/rebased and merged forge!1 into deploy/,
        qr/rebased and merged forge!2 into deploy/,
      ],
    },
  };

  my $local = $world->local_repo;

  is(
    $local->message($result->head . "^1"),
    "Merge branch 'alice/one' into 'deploy'\n\nSee https://forge.example.com/merge-requests/1\n",
    "the first merge has a message of its own",
  );

  is($local->rev('deploy'), $result->rev_for('head'), "the build is on the target branch");

  $world->set_date('2026-11-23');

  my $later = mint_ok $world, "the same build, days later" => {
    expect => { merged => [ 'forge!1', 'forge!2' ] },
  };

  is($later->rev_for('head'), $result->rev_for('head'), "it builds the same commit");

  build_ok "a merge request that can't be rebased is fatal" => {
    config => simple_config(use_semilinear_merge => \1),
    mrs    => { forge => [ @OLD_MRS, $STALE_MR ] },
    expect => {
      error => qr/Error rebasing forge!3 \(\w{40}\) onto HEAD \(\w{8}\); bailing out! Error: /,
      logs  => [ qr/rebased and merged forge!2 into deploy/ ],
    },
  };
};

done_testing;
