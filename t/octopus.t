use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

build_ok "one step, two merge requests" => {
  config => simple_config(),
  mrs    => {
    forge => [ mr(1, alice => 'one'), mr(2, bob => 'two', fork => 1) ],
  },
  expect => {
    merged  => [ 'forge!1', 'forge!2' ],
    history => [ 'base', 'forge!1', 'forge!2' ],
    message => qr/\AMerge 2 tagged MRs\n\n1, \w{8} \(alice\) - .+\n2, \w{8} \(bob\) - .+\n\z/,
    tag     => undef,
    logs    => [
      qr/already have forge!1 \(\w{8}\) locally, will not fetch/,
      qr/fetched forge!2/,
      qr/octopus merging 2 MRs/,
    ],
  },
};

build_ok "one step, one merge request" => {
  config => simple_config(),
  mrs    => { forge => [ mr(1, alice => 'one') ] },
  expect => {
    merged  => [ 'forge!1' ],
    history => [ 'base', 'forge!1' ],
    message => qr/\AMerge 1 tagged MR\n/,
  },
};

build_ok "merge requests are merged in numeric order" => {
  config => simple_config(),
  mrs    => {
    forge => [ mr(10, alice => 'ten'), mr(9, bob => 'nine'), mr(100, carol => 'hundred') ],
  },
  expect => {
    merged  => [ 'forge!9', 'forge!10', 'forge!100' ],
    history => [ 'base', 'forge!9', 'forge!10', 'forge!100' ],
  },
};

build_ok "only open, labeled merge requests are included" => {
  config => simple_config(),
  mrs    => {
    forge => [
      mr(1, alice => 'one'),
      mr(2, alice => 'two',   labels => [ 'wip' ]),
      mr(3, alice => 'three', labels => [ 'wip', 'include' ]),
      mr(4, alice => 'four',  labels => [ ]),
    ],
  },
  expect => {
    merged  => [ 'forge!1', 'forge!3' ],
    history => [ 'base', 'forge!1', 'forge!3' ],
  },
};

build_ok "nothing to merge" => {
  config => simple_config(),
  expect => {
    merged  => [ ],
    history => 'base',
    logs    => [ qr/nothing to do!/ ],
  },
};

build_ok "merge requests based on an old upstream commit" => {
  config => simple_config(),
  mrs    => {
    forge => [
      mr(1, alice => 'one', base => 'master~2'),
      mr(2, alice => 'two', base => 'master~1', files => { 'imap/append.c' => "/* new */\n" }),
    ],
  },
  expect => {
    merged  => [ 'forge!1', 'forge!2' ],
    history => [ 'base', 'forge!1', 'forge!2' ],
  },
};

build_ok "two steps, like the Cyrus build" => {
  config => cyrus_config(),
  mrs    => {
    github => [ mr(101, alice => 'jmap-fix'), mr(102, bob => 'sieve-fix', fork => 1) ],
    gitlab => [ mr(7, carol => 'fm-tweaks') ],
  },
  expect => {
    merged  => [ 'github!101', 'github!102', 'gitlab!7' ],
    history => [ [ 'base', 'github!101', 'github!102' ], 'gitlab!7' ],
    message => qr/\AMerge 1 tagged MR\n/,
    tag     => qr/\Afm-20261120\.001-g\w{8}\z/,
  },
};

build_ok "two steps, but only the second has anything to do" => {
  config => cyrus_config(),
  mrs    => { gitlab => [ mr(7, carol => 'fm-tweaks') ] },
  expect => {
    merged  => [ 'gitlab!7' ],
    history => [ 'base', 'gitlab!7' ],
    logs    => [ qr/github: nothing to do!/ ],
  },
};

build_ok "two steps, but only the first has anything to do" => {
  config => cyrus_config(),
  mrs    => { github => [ mr(101, alice => 'jmap-fix') ] },
  expect => {
    merged  => [ 'github!101' ],
    history => [ 'base', 'github!101' ],
    logs    => [ qr/capstone: nothing to do!/ ],
    tag     => qr/\Afm-20261120\.001-g\w{8}\z/,
  },
};

build_ok "merge requests from untrusted authors are left out" => {
  config => cyrus_config(),
  mrs    => {
    github => [ mr(101, alice => 'jmap-fix'), mr(102, mallory => 'backdoor') ],
    gitlab => [ mr(7, mallory => 'backdoor'), mr(8, carol => 'fm-tweaks') ],
  },
  expect => {
    merged  => [ 'github!101', 'gitlab!8' ],
    history => [ [ 'base', 'github!101' ], 'gitlab!8' ],
    logs    => [
      qr/ignoring MR github!102 from untrusted user mallory/,
      qr/ignoring MR gitlab!7 from untrusted user mallory/,
    ],
  },
};

subtest "the same inputs make the same commit" => sub {
  my $spec = {
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ mr(1, alice => 'one'), mr(2, bob => 'two') ] },
    expect => { tag => qr/\Abuild-20261120\.001-g\w{8}\z/ },
  };

  my ($world_a, $first) = build_ok("first build", $spec);
  my ($world_b, $other) = build_ok("the same build, in another world", $spec);

  is($other->rev_for('head'), $first->rev_for('head'), "two worlds agree on the sha");

  $world_a->set_date('2026-11-23');

  my $again = mint_ok($world_a, "the same build, days later" => {
    expect => {
      merged  => [ 'forge!1', 'forge!2' ],
      tag     => undef,
      logs    => [ qr/already tagged as build-20261120\.001-g\w{8}; skipping/ ],
    },
  });

  is($again->rev_for('head'), $first->rev_for('head'), "a rebuild gets the same sha");
};

done_testing;
