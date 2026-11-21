use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

# These tests are about release mode, which is what mint-release-branch uses.
# There's one step, and the result is pushed to the upstream's default branch.

subtest "a release" => sub {
  my ($world, $result) = build_ok "labeled merge requests are merged to master" => {
    config => release_config(),
    mrs    => {
      forge => [
        mr(1, alice => 'one'),
        mr(2, bob   => 'two', fork => 1),
        mr(3, carol => 'not-yet', labels => [ ]),
      ],
    },
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      history => [ 'base', 'forge!1', 'forge!2' ],
      tag     => undef,
      logs    => [ qr{build-release-branch: pushing branch to remote forge/master} ],
      remote_branches => { forge => { master => 'head' } },
      mr_states => {
        'forge!1' => 'merged',
        'forge!2' => 'merged',
        'forge!3' => 'opened',
      },
    },
  };

  is(
    $world->local_repo->rev('master'),
    $result->rev_for('head'),
    "the local branch is named for the upstream's default branch",
  );

  my $again = mint_ok $world, "another release, with nothing new to merge" => {
    expect => {
      merged  => [ ],
      history => 'base',
      remote_branches => { forge => { master => 'head' } },
    },
  };

  is($again->rev_for('base'), $result->rev_for('head'), "it starts from the last release");

  $world->forge('forge')->set_labels(3, 'release-me');

  mint_ok $world, "another release, after another merge request is labeled" => {
    expect => {
      merged  => [ 'forge!3' ],
      history => [ $result->rev_for('head'), 'forge!3' ],
      remote_branches => { forge => { master => 'head' } },
      mr_states => { 'forge!3' => 'merged' },
    },
  };
};

subtest "a release of merge requests picked by number" => sub {
  my %spec = (
    config => release_config(label => \0),
    mrs    => {
      forge => [
        mr(1, alice => 'one', labels => [ 'release-me' ]),
        mr(2, bob   => 'two'),
        mr(3, carol => 'three'),
      ],
    },
  );

  build_ok "with the label turned off, only the numbered ones are merged" => {
    %spec,
    with   => { mrs => [ 3, 2 ] },
    expect => {
      merged  => [ 'forge!3', 'forge!2' ],
      history => [ 'base', 'forge!3', 'forge!2' ],
      logs    => [ qr/not fetching MRs for remote forge, no label provided/ ],
      remote_branches => { forge => { master => 'head' } },
      mr_states => {
        'forge!1' => 'opened',
        'forge!2' => 'merged',
        'forge!3' => 'merged',
      },
    },
  };

  build_ok "with the label turned off and no numbers, nothing is merged" => {
    %spec,
    expect => {
      merged  => [ ],
      history => 'base',
      logs    => [ qr/not fetching MRs for remote forge, no label provided/ ],
    },
  };
};

done_testing;
