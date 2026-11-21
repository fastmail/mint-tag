use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

# These tests are about which merge requests mint-tag picks up, and what it
# works out about each one before it starts merging.  Picking them up by label
# is the usual thing, and that's all over the other tests.

subtest "what we learn about each merge request" => sub {
  my $same_change = { 'topic/shared.txt' => "two people had the same idea\n" };

  my ($world, $result) = build_ok "merge requests from various points in history" => {
    config => simple_config(),
    mrs    => {
      forge => [
        mr(1, alice => 'at-tip'),
        mr(2, alice => 'at-root',  base => 'master~2', files => $same_change),
        mr(3, bob   => 'in-between', base => 'master~1', files => $same_change, fork => 1),
      ],
    },
    expect => { merged => [ 'forge!1', 'forge!2', 'forge!3' ] },
  };

  my $upstream = $world->forge('forge')->repo;

  for my $pair ([ 1 => 'master' ], [ 2 => 'master~2' ], [ 3 => 'master~1' ]) {
    my ($number, $base) = @$pair;

    is(
      $result->mr("forge!$number")->merge_base,
      $upstream->rev($base),
      "the merge base of forge!$number is $base",
    );
  }

  like($result->mr('forge!1')->patch_id, qr/\A[0-9a-f]{40}\z/, "a patch id looks like a sha");

  is(
    $result->mr('forge!2')->patch_id,
    $result->mr('forge!3')->patch_id,
    "the same change on two different bases has one patch id",
  );

  isnt(
    $result->mr('forge!1')->patch_id,
    $result->mr('forge!2')->patch_id,
    "different changes have different patch ids",
  );
};

subtest "merge requests that change between builds" => sub {
  my $world = new_world(
    config => simple_config(),
    mrs    => { forge => [ mr(1, alice => 'local'), mr(2, bob => 'forked', fork => 1) ] },
  );

  my $forge = $world->forge('forge');
  my $first = mint_ok $world, "the first build" => {
    expect => { merged => [ 'forge!1', 'forge!2' ] },
  };

  $forge->update_mr(1);
  $forge->update_mr(2);

  my $second = mint_ok $world, "a build after both merge requests changed" => {
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      history => [ 'base', 'forge!1', 'forge!2' ],
      logs    => [ qr/fetched forge!2/ ],
    },
  };

  for my $ident ('forge!1', 'forge!2') {
    isnt($second->rev_for($ident), $first->rev_for($ident), "$ident has a new head");

    my ($number) = $ident =~ /!(\d+)/;
    is($second->rev_for($ident), $forge->mr_data($number)->{sha}, "...which is the forge's");
  }

  $forge->close_mr(1);
  $forge->set_labels(2, 'wip');

  mint_ok $world, "a build after one was closed and the other lost its label" => {
    expect => { merged => [ ], history => 'base' },
  };
};

subtest "merge requests asked for by number" => sub {
  my %spec = (
    config => simple_config(),
    mrs    => {
      forge => [
        mr(1, alice => 'labeled'),
        mr(2, alice => 'unlabeled', labels => [ ]),
        mr(3, alice => 'also-unlabeled', labels => [ ]),
      ],
    },
  );

  build_ok "labeled merge requests, plus one by number" => {
    %spec,
    with   => { mrs => [ 3 ] },
    expect => {
      merged  => [ 'forge!1', 'forge!3' ],
      history => [ 'base', 'forge!1', 'forge!3' ],
      logs    => [ qr/fetching extra MR: #3, from remote forge/ ],
    },
  };

  build_ok "merge requests by number come after the labeled ones, in the order given" => {
    %spec,
    with   => { mrs => [ 3, 2 ] },
    expect => {
      merged  => [ 'forge!1', 'forge!3', 'forge!2' ],
      history => [ 'base', 'forge!1', 'forge!3', 'forge!2' ],
    },
  };

  build_ok "a merge request is only picked up once, however often it's asked for" => {
    %spec,
    with   => { mrs => [ 1, 3, 3 ] },
    expect => {
      merged  => [ 'forge!1', 'forge!3' ],
      history => [ 'base', 'forge!1', 'forge!3' ],
      message => qr/\AMerge 2 tagged MRs\n\n1, .+\n3, .+\n\z/,
      logs    => [
        qr/skipping extra MR #1, from remote forge; already have it/,
        qr/skipping extra MR #3, from remote forge; already have it/,
      ],
    },
  };
};

done_testing;
