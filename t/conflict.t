use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

# When an octopus merge fails, mint-tag starts over and merges things one at a
# time, to work out which merge requests are to blame.  These tests are about
# whether it blames the right ones.

# Make the content of imap/append.c, but returning something other than zero.
my sub append_c ($n) { "/* append */\nint append(void) {\n  return $n;\n}\n" }

my $UTIL_C = "/* util */\nint util(void) {\n  return 2;\n}\n";

# A merge request that changes a line that master has also changed since the
# merge request was made.
my $STALE_MR = mr(9, carol => 'stale',
  base  => 'master~2',
  files => { 'imap/mailbox.c' => "/* mailbox */\nint mailbox(void) {\n  return 7;\n}\n" },
);

my @DIAGNOSTICS = (
  qr/octopus merge failed with error/,
  qr/will merge less octopodally for diagnostics/,
);

build_ok "a merge request that conflicts with the base" => {
  config => simple_config(),
  mrs    => { forge => [ mr(1, alice => 'one'), mr(2, bob => 'two'), $STALE_MR ] },
  expect => {
    error => qr{forge!9 conflicts with forge/master},
    logs  => [
      @DIAGNOSTICS,
      qr/diagnostic merge: encountered error while merging forge!9; will attempt to find conflict/,
      qr/diagnostic merge: merging known-bad MR: forge!9/,
    ],
    no_logs => [ qr/to check for conflict/ ],
  },
};

build_ok "two merge requests that conflict with each other" => {
  config => simple_config(),
  mrs    => {
    forge => [
      mr(1, alice => 'three', files => { 'imap/append.c' => append_c(3) }),
      mr(2, bob   => 'four',  files => { 'imap/append.c' => append_c(4) }),
    ],
  },
  expect => {
    error => qr{fatal conflict between forge!1 and forge!2; giving up},
    logs  => [
      @DIAGNOSTICS,
      qr/encountered error while merging forge!2; will attempt to find conflict/,
      qr/merging known-bad MR: forge!2/,
      qr/merging forge!1 to check for conflict/,
    ],
  },
};

build_ok "the guilty pair among several merge requests" => {
  config => simple_config(),
  mrs    => {
    forge => [
      mr(1, alice => 'one'),
      mr(2, alice => 'three', files => { 'imap/append.c' => append_c(3) }),
      mr(3, bob   => 'bystander'),
      mr(4, bob   => 'four',  files => { 'imap/append.c' => append_c(4) }),
      mr(5, carol => 'five'),
    ],
  },
  expect => {
    error => qr{fatal conflict between forge!2 and forge!4; giving up},
    logs  => [
      qr/merging known-bad MR: forge!4/,
      qr/merging forge!1 to check for conflict/,
      qr/merging forge!2 to check for conflict/,
    ],
    no_logs => [
      qr/merging forge!3 to check for conflict/,
      qr/merging forge!5 to check for conflict/,
    ],
  },
};

# An octopus merge can't cope with a rename on one side and a change to the
# renamed file on the other, but an ordinary merge can.  So the octopus fails,
# and then the diagnostic merge can't find anything wrong.
build_ok "merge requests that only an octopus can't merge" => {
  config => simple_config(),
  mrs    => {
    forge => [
      mr(1, alice => 'rename', files => { 'lib/util.c' => undef, 'lib/utility.c' => $UTIL_C }),
      mr(2, bob   => 'change', files => { 'lib/util.c' => $UTIL_C =~ s/util \*/utilities */r }),
      mr(3, carol => 'bystander'),
    ],
  },
  expect => {
    error => qr{giving up after conflicts},
    logs  => [
      @DIAGNOSTICS,
      qr/diagnostic merge succeeded somehow, so here are multiply-affected files/,
      qr{lib/util\.c affected by all of forge!1, forge!2},
    ],
    no_logs => [ qr/will attempt to find conflict/, qr/topic\S+ affected by/ ],
  },
};

subtest "a conflict with an earlier step" => sub {
  my %mrs = (
    github => [
      mr(101, alice => 'bystander'),
      mr(102, alice => 'three', files => { 'imap/append.c' => append_c(3) }),
    ],
    gitlab => [
      mr(7, carol => 'four', files => { 'imap/append.c' => append_c(4) }),
      mr(8, carol => 'another-bystander'),
    ],
  );

  build_ok "when the later step rebases, the rebase fails" => {
    config => cyrus_config(),
    mrs    => \%mrs,
    expect => {
      error => qr{Error rebasing gitlab!7 \(\w{40}\) onto HEAD},
      tag   => undef,
    },
  };

  build_ok "when the later step doesn't rebase, we find the conflict" => {
    config => cyrus_config(capstone => { rebase => \0 }),
    mrs    => \%mrs,
    expect => {
      error => qr{fatal conflict between github!102 and gitlab!7; giving up},
      tag   => undef,
      logs  => [
        qr/capstone: octopus merge failed with error/,
        qr/encountered error while merging gitlab!7; will attempt to find conflict/,
        qr/merging known-bad MR: gitlab!7/,
        qr/merging github!101 to check for conflict/,
        qr/merging github!102 to check for conflict/,
      ],
      no_logs => [ qr/diagnostic merge succeeded somehow/ ],
    },
  };

  # This is the rename trouble again:  the first step renames a file, and then
  # the second step's octopus can't merge a change to that file.
  build_ok "when only an octopus can't merge the later step, earlier steps are suspects" => {
    config => cyrus_config(capstone => { rebase => \0 }),
    mrs    => {
      github => [
        mr(101, alice => 'rename', files => { 'lib/util.c' => undef, 'lib/utility.c' => $UTIL_C }),
      ],
      gitlab => [
        mr(7, carol => 'change', files => { 'lib/util.c' => $UTIL_C =~ s/util \*/utilities */r }),
        mr(8, carol => 'bystander'),
      ],
    },
    expect => {
      error => qr{giving up after conflicts},
      tag   => undef,
      logs  => [
        qr/capstone: octopus merge failed with error/,
        qr/diagnostic merge succeeded somehow, so here are multiply-affected files/,
        qr{lib/util\.c affected by all of github!101, gitlab!7},
      ],
    },
  };
};

subtest "building again after a conflict" => sub {
  my ($world) = build_ok "a build that fails" => {
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ mr(1, alice => 'one'), $STALE_MR ] },
    expect => { error => qr{forge!9 conflicts with forge/master}, tag => undef },
  };

  mint_ok $world, "the same build fails the same way" => {
    expect => { error => qr{forge!9 conflicts with forge/master}, tag => undef },
  };

  $world->forge('forge')->set_labels(9);

  mint_ok $world, "once the bad merge request is unlabeled, the build works" => {
    expect => {
      merged  => [ 'forge!1' ],
      history => [ 'base', 'forge!1' ],
      tag     => qr/\Abuild-20261120\.001-g\w{8}\z/,
    },
  };
};

done_testing;
