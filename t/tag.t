use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::Deep;
use Test::More;
use TOML::Parser;

# Run mint-tag and expect it to make one tag, pointing at what it built, named
# "$stem-gSHA", where the SHA is the start of the sha of what it built.
my sub mints_tag ($world, $desc, $stem) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $result = mint_ok($world, $desc => { expect => { tag => qr/\A\Q$stem\E-g\w{8}\z/ } });

  my $head = $result->rev_for('head');
  my $tag  = $result->tag // return $result;

  is($tag, "$stem-g" . substr($head, 0, 8), "...and the tag name ends with the sha");
  is($world->local_repo->rev($tag), $head,  "...and the tag points at what we built");

  return $result;
}

# Run mint-tag and expect it to make no tag, because what it built already has
# the named tag.
my sub mints_no_tag ($world, $desc, $existing) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  return mint_ok($world, $desc => {
    expect => {
      tag  => undef,
      logs => [ qr/already tagged as \Q$existing\E-g\w{8}; skipping/ ],
    },
  });
}

# Check the annotation on a tag made by a run of mint-tag.  We want:
#
#   step  - the name of the step that made the tag
#   steps - an arrayref with a hashref for each step that should be recorded:
#             name   - the name of the step
#             remote - the name of the step's remote
#             mrs    - the idents of the merge requests the step merged
my sub annotation_ok ($result, $tag, $want) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my ($header, $toml) = split /\n\n/, $result->local_repo->message($tag), 2;

  my @steps;
  for my $step ($want->{steps}->@*) {
    my @mrs = map {; my $ident = $_; grep {; $_->ident eq $ident } $result->mrs }
              $step->{mrs}->@*;

    push @steps, {
      name   => $step->{name},
      remote => $result->world->forge($step->{remote})->clone_url,
      (@mrs ? (merge_requests => [
        map {; {
          number     => $_->number,
          title      => $_->title,
          sha        => $_->sha,
          merge_base => $_->merge_base,
          patch_id   => all($_->patch_id, re(qr/\A[0-9a-f]{40}\z/)),
        } } @mrs
      ]) : ()),
    };
  }

  subtest "annotation of $tag" => sub {
    is($header, "mint-tag generated commit from step named $want->{step}", "header line");

    is(
      $result->local_repo->git(qw(tag -l), '--format=%(taggername) %(taggeremail)', $tag),
      'MintTag <minttag@example.com>',
      "tagged by the committer from the config",
    );

    cmp_deeply(
      TOML::Parser->new->parse($toml),
      {
        meta => {
          tag_name => $tag,
          base     => $result->rev_for('base'),
          annotation_version => 1,
        },
        build_steps => \@steps,
      },
      "TOML body",
    ) or diag $toml;
  };
}

subtest "serial numbers" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
  );

  my $forge = $world->forge('forge');

  mints_tag($world, "the first build of the day", 'build-20261120.001');

  $forge->update_mr(1);
  mints_tag($world, "a second build, after an MR changed", 'build-20261120.002');

  mints_no_tag($world, "a third build, but nothing changed", 'build-20261120.002');

  $world->set_date('2026-11-21');
  mints_no_tag($world, "the next day, and still nothing changed", 'build-20261120.002');

  $forge->update_mr(1);
  mints_tag($world, "the first new build of the next day", 'build-20261121.001');

  $world->add_mr(forge => mr(2, bob => 'two')->%*);
  mints_tag($world, "another build, after an MR was added", 'build-20261121.002');
};

subtest "serial numbers continue from tags we didn't make" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
  );

  # mint-tag fetches tags from every remote, so that it'll know about tags
  # made by runs on other machines.
  my $repo = $world->forge('forge')->repo;
  $repo->git(qw(tag build-20261120.041-g12345678 master));
  $repo->git(qw(tag build-20261119.107-g12345678 master));
  $repo->git(qw(tag other-20261120.300-g12345678 master));

  mints_tag($world, "a build when the remote has tags", 'build-20261120.042');
};

subtest "tags from every step that has a prefix" => sub {
  my ($world, $result) = build_ok "a build with two tagging steps" => {
    config => cyrus_config(github => { tag_prefix => 'upstream' }),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix'), mr(102, bob => 'sieve-fix') ],
      gitlab => [ mr(7, carol => 'fm-tweaks', title => 'Say "hello" to Fastmail') ],
    },
    expect => {
      merged      => [ 'github!101', 'github!102', 'gitlab!7' ],
      remote_tags => {
        github => [ ],
        gitlab => [ re(qr/\Afm-20261120\.001-g\w{8}\z/) ],
      },
    },
  };

  my ($fm_tag, $upstream_tag) = sort $result->new_tags->@*;
  my $local = $world->local_repo;

  like($fm_tag,       qr/\Afm-20261120\.001-g\w{8}\z/,       "tag from the second step");
  like($upstream_tag, qr/\Aupstream-20261120\.001-g\w{8}\z/, "tag from the first step");

  is($local->rev($fm_tag), $result->rev_for('head'), "second step's tag is on the final build");

  is_deeply(
    [ $local->parents($fm_tag) ],
    [ $local->rev($upstream_tag), $result->rev_for('gitlab!7') ],
    "first step's tag is on the first step's merge",
  );

  annotation_ok($result, $upstream_tag, {
    step  => 'github',
    steps => [
      { name => 'github', remote => 'github', mrs => [ 'github!101', 'github!102' ] },
    ],
  });

  annotation_ok($result, $fm_tag, {
    step  => 'capstone',
    steps => [
      { name => 'github',   remote => 'github', mrs => [ 'github!101', 'github!102' ] },
      { name => 'capstone', remote => 'gitlab', mrs => [ 'gitlab!7' ] },
    ],
  });
};

subtest "a tag for a build with nothing merged" => sub {
  my ($world, $result) = build_ok "a tagging build with no merge requests" => {
    config => cyrus_config(),
    expect => {
      history => 'base',
      tag     => qr/\Afm-20261120\.001-g\w{8}\z/,
    },
  };

  annotation_ok($result, $result->tag, {
    step  => 'capstone',
    steps => [
      { name => 'github',   remote => 'github', mrs => [ ] },
      { name => 'capstone', remote => 'gitlab', mrs => [ ] },
    ],
  });
};

subtest "a tag with a prefix that ends with our prefix is not ours" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'rebuild'),
    mrs    => { forge => [ mr(1, alice => 'one') ] },
  );

  mints_tag($world, "a build with the prefix 'rebuild'", 'rebuild-20261120.001');

  $world->config->{build_steps}[0]{tag_prefix} = 'build';
  $world->write_config;

  mints_tag($world, "the same build with the prefix 'build'", 'build-20261120.001');
};

# Tag an arbitrary sha, and check on how it went.  The $rev is a revision in
# the upstream forge's repository, and $expect is as for result_ok.
my sub tag_sha_ok ($world, $rev, $desc, $expect) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $sha    = $world->forge('github')->repo->rev($rev);
  my $result = $world->tag_sha($sha);

  result_ok($result, $desc, $expect);

  return ($result, $sha);
}

subtest "tagging an arbitrary sha" => sub {
  my $world = new_world(
    config => cyrus_config(),
    mrs    => { github => [ mr(101, alice => 'jmap-fix') ] },
  );

  my ($result, $sha) = tag_sha_ok($world, 'master~1', "tag an old upstream commit" => {
    tag         => qr/\Afm-20261120\.001-g\w{8}\z/,
    remote_tags => { gitlab => [ re(qr/\Afm-20261120\.001-g\w{8}\z/) ] },
    no_logs     => [ qr/fetching MRs/ ],
  });

  my $tag = $result->tag // return;
  is($tag, 'fm-20261120.001-g' . substr($sha, 0, 8), "the tag is named for the sha");
  is($world->local_repo->rev($tag), $sha, "the tag points at the sha");

  annotation_ok($result, $tag, {
    step  => 'capstone',
    steps => [
      { name => 'github',   remote => 'github', mrs => [ ] },
      { name => 'capstone', remote => 'gitlab', mrs => [ ] },
    ],
  });

  tag_sha_ok($world, 'master~1', "tag the same commit again" => {
    tag  => undef,
    logs => [ qr/already tagged as fm-20261120\.001-g\w{8}; skipping/ ],
  });

  tag_sha_ok($world, 'master~2', "tag a different commit" => {
    tag         => qr/\Afm-20261120\.002-g\w{8}\z/,
    remote_tags => { gitlab => [ (re(qr/\Afm-20261120\.00\d-g\w{8}\z/)) x 2 ] },
  });
};

subtest "refusing to tag an arbitrary sha" => sub {
  my $ambiguous = qr/refusing to tag sha; config file is ambiguous/;

  tag_sha_ok(
    new_world(config => cyrus_config(github => { tag_prefix => 'upstream' })),
    'master',
    "two steps have tag prefixes" => { error => $ambiguous, tag => undef },
  );

  tag_sha_ok(
    new_world(config => cyrus_config(capstone => { tag_prefix => undef, push_tag_to => undef })),
    'master',
    "no step has a tag prefix" => { error => $ambiguous, tag => undef },
  );
};

done_testing;
