use v5.36;

use lib 't/lib';
use Test::MintTag;

use Path::Tiny ();
use Test::Deep;
use Test::More;

# The rest of the test suite trusts the pretend forges to hold what the tests
# say they hold.  These tests are here to see whether that trust is deserved,
# and they don't run mint-tag at all.

my sub world_with (@mrs) {
  return new_world(
    config => cyrus_config(),
    mrs    => { github => [ grep {; $_->{on} eq 'github' } @mrs ],
                gitlab => [ grep {; $_->{on} eq 'gitlab' } @mrs ] },
  );
}

my sub on ($remote, $mr) { return { %$mr, on => $remote } }

# Check what a forge says about one merge request, and what its repository
# holds for it.
#
#   state   - the state the forge reports
#   labels  - the labels the forge reports
#   source  - "golden" or "fork": where the source branch must be
#   files   - a hashref of (path => content) to find at the MR's head, with
#             undef meaning the file must not exist
#   changes - the paths the forge says the MR changes
my sub mr_is ($world, $ident, $want) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my ($remote, $number) = split /!/, $ident;
  my $forge = $world->forge($remote);
  my $repo  = $forge->repo;
  my $data  = $forge->mr_data($number);

  subtest "merge request $ident" => sub {
    is(
      $repo->rev("refs/merge-requests/$number/head"),
      $data->{sha},
      "golden repo has a head ref at the reported sha",
    );

    is($data->{state}, $want->{state}, "state") if $want->{state};

    cmp_deeply($data->{labels}, $want->{labels}, "labels") if $want->{labels};

    if (my $source = $want->{source}) {
      my $in_golden = $data->{source_url} eq $forge->clone_url;
      is($in_golden ? 'golden' : 'fork', $source, "source branch is in the $source repo");

      my $source_repo = Test::MintTag::Repo->new({
        path => Path::Tiny::path($data->{source_url} =~ s{\Afile://}{}r),
      });

      is(
        $source_repo->rev("refs/heads/$data->{branch}"),
        $data->{sha},
        "source branch is at the reported sha",
      );
    }

    for my $path (sort keys(($want->{files} // {})->%*)) {
      is($repo->file($data->{sha}, $path), $want->{files}{$path}, "content of $path");
    }

    if ($want->{changes}) {
      cmp_deeply(
        [ $forge->files_changed_by_mr($number) ],
        bag($want->{changes}->@*),
        "changed files",
      );
    }
  };
}

subtest "the standard upstream history" => sub {
  my $world  = world_with();
  my $github = $world->forge('github')->repo;
  my $gitlab = $world->forge('gitlab')->repo;

  is($github->git(qw(rev-list --count master)), 3, "upstream has three commits");

  is(
    $gitlab->rev('master'),
    $github->rev('master'),
    "the mirror has the same master as the upstream",
  );

  like($github->file('master',   'imap/mailbox.c'), qr/return 1/, "mailbox.c at master");
  like($github->file('master~2', 'imap/mailbox.c'), qr/return 0/, "mailbox.c at the root");

  is(
    new_world(config => cyrus_config())->forge('github')->repo->rev('master'),
    $github->rev('master'),
    "two worlds get the very same upstream commits",
  );
};

subtest "merge requests are what we said they'd be" => sub {
  my $world = world_with(
    on(github => mr(1, alice => 'plain')),
    on(github => mr(2, bob   => 'forked', fork => 1, labels => [ 'wip' ])),
    on(gitlab => mr(3, carol => 'edits',
      base  => 'master~1',
      files => { 'imap/append.c' => "/* gone fishing */\n", 'README' => undef },
    )),
  );

  mr_is($world, 'github!1', {
    state   => 'opened',
    labels  => [ 'include-in-fastmail' ],
    source  => 'golden',
    files   => { 'topic/plain.txt' => "the work from plain\n" },
    changes => [ 'topic/plain.txt' ],
  });

  mr_is($world, 'github!2', {
    state   => 'opened',
    labels  => [ 'wip' ],
    source  => 'fork',
    changes => [ 'topic/forked.txt' ],
  });

  mr_is($world, 'gitlab!3', {
    source  => 'golden',
    files   => {
      'imap/append.c' => "/* gone fishing */\n",
      'README'        => undef,
      'lib/util.c'    => "/* util */\nint util(void) {\n  return 0;\n}\n",
    },
    changes => [ 'imap/append.c', 'README' ],
  });

  my $github = $world->forge('github');

  is(
    $github->repo->rev('refs/heads/forked'),
    undef,
    "a fork's branch is not in the golden repo",
  );

  cmp_deeply(
    [ map {; $_->{number} } $github->open_mrs_with_label('include-in-fastmail') ],
    [ 1 ],
    "only labeled merge requests are listed for a label",
  );
};

subtest "merge requests change over time" => sub {
  my $world = world_with(
    on(github => mr(1, alice => 'one', fork => 1)),
    on(github => mr(2, alice => 'two')),
    on(github => mr(3, alice => 'three')),
  );

  my $github = $world->forge('github');
  my $before = $github->mr_data(1)->{sha};

  $github->update_mr(1, files => { 'topic/more.txt' => "more\n" });

  isnt($github->mr_data(1)->{sha}, $before, "updating an MR moves its head");
  is_deeply([ $github->repo->parents($github->mr_data(1)->{sha}) ], [ $before ],
    "...to a child of the old head");

  mr_is($world, 'github!1', {
    source  => 'fork',
    changes => [ 'topic/one.txt', 'topic/more.txt' ],
  });

  $github->close_mr(2);
  $github->set_labels(3);

  cmp_deeply(
    [ map {; $_->{number} } $github->open_mrs_with_label('include-in-fastmail') ],
    [ 1 ],
    "closed and unlabeled merge requests are not listed",
  );

  # Somebody merges MR 1, and pushes that to master.
  my $fork = Test::MintTag::Repo->new({
    path => Path::Tiny::path($github->mr_data(1)->{source_url} =~ s{\Afile://}{}r),
  });

  $fork->git('push', '--quiet', $github->clone_url, 'refs/heads/one:refs/heads/master');

  mr_is($world, 'github!1', { state => 'merged' });
  mr_is($world, 'github!2', { state => 'closed' });
  mr_is($world, 'github!3', { state => 'opened' });

  # Somebody pushes to the source branch without telling the forge's API.
  my $pushed = $github->repo->commit(
    ref    => 'refs/heads/three',
    parent => $github->mr_data(3)->{sha},
    epoch  => 1_700_000_000,
    files  => { 'topic/pushed.txt' => "pushed\n" },
  );

  is($github->mr_data(3)->{sha}, $pushed, "the forge notices a push to a source branch");
};

done_testing;
