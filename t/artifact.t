use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::Deep;
use Test::More;

use App::MintTag::Artifact;
use App::MintTag::BuildStep;
use App::MintTag::Config;
use App::MintTag::MergeRequest;
use Test::MintTag::Remote;

# These tests don't run git or mint-tag.  They build configs, steps, and merge
# requests by hand, and then see what an artifact makes of them.

package Local::Remote {
  use Moo;
  extends 'Test::MintTag::Remote';

  # This remote doesn't have a forge, just a couple URLs.
  has [ qw(https_url ssh_url) ] => (is => 'ro', required => 1);

  sub obtain_https_clone_url ($self) { $self->https_url }
  sub obtain_ssh_clone_url   ($self) { $self->ssh_url   }
}

# Make a remote that we clone over ssh, unless you say (https => 1).
my sub remote ($name, %arg) {
  return Local::Remote->new({
    name      => $name,
    api_url   => "mock://nowhere/$name",
    api_key   => 'hunter2',
    repo      => "example/$name",
    https_url => "https://minttag:hunter2\@$name.example.com/example/$name.git",
    ssh_url   => "git\@$name.example.com:example/$name.git",
    do_clone_via_https => $arg{https} ? 1 : 0,
  });
}

# Make a merge request object.  Its sha, merge base, and patch id are made up
# from its number, unless you provide them.
my sub mr_obj ($remote, $number, %arg) {
  my $mr = App::MintTag::MergeRequest->new({
    remote      => $remote,
    number      => $number,
    title       => $arg{title} // "Merge request $number",
    sha         => $arg{sha}   // sprintf('%040x', $number),
    author      => 'alice',
    branch_name => "branch-$number",
    fetch_spec  => $remote->name,
    ref_name    => "merge-requests/$number/head",
    web_url     => "https://example.com/$number",
    state       => 'opened',
    is_merged   => 0,
    force_push_url => undef,
    should_delete_branch => 0,
    fetch_affected_files_callback => sub { [] },
  });

  $mr->set_merge_base($arg{merge_base} // 'b' x 40);
  $mr->set_patch_id($arg{patch_id} // sprintf('%040x', 0xFFFF + $number));

  return $mr;
}

# Make a build step.  The arguments are its name, its remote, and then its
# merge requests.
my sub step ($name, $remote, @mrs) {
  my $step = App::MintTag::BuildStep->new({
    name   => $name,
    remote => $remote,
    label  => 'include',
  });

  $step->set_merge_requests(\@mrs);

  return $step;
}

my sub config (@steps) {
  my %remote = map {; $_->remote->name => $_->remote } @steps;

  return App::MintTag::Config->new({
    cfg     => {},
    steps   => \@steps,
    remotes => \%remote,
    committer_email    => 'minttag@example.com',
    local_repo_dir     => '/local/path',
    target_branch_name => 'deploy',
    upstream_base      => 'forge/master',
  });
}

my sub artifact ($config, %arg) {
  return App::MintTag::Artifact->new({
    config   => $config,
    base     => 'a' x 40,
    tag_name => 'build-20261120.001-g01234567',
    annotation_version => 1,
    %arg,
  });
}

# Turn an artifact into TOML and back again.
my sub round_trip ($artifact) {
  return App::MintTag::Artifact->from_toml($artifact->config, $artifact->as_toml);
}

my $github = remote('github');
my $gitlab = remote('gitlab');

subtest "an artifact as TOML" => sub {
  my $config = config(
    step(upstream => $github, mr_obj($github, 101), mr_obj($github, 102)),
    step(nothing  => $github),
    step(capstone => $gitlab, mr_obj($gitlab, 7, title => 'Say "hello"')),
  );

  my $artifact = artifact($config);

  my $want = <<~'END' =~ s/\n\z//r;
    [meta]
    tag_name = "build-20261120.001-g01234567"
    annotation_version = 1
    base = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    [[build_steps]]
    name = "upstream"
    remote = "git@github.example.com:example/github.git"

      [[build_steps.merge_requests]]
      number = "101"
      title = "Merge request 101"
      sha = "0000000000000000000000000000000000000065"
      merge_base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      patch_id = "0000000000000000000000000000000000010064"

      [[build_steps.merge_requests]]
      number = "102"
      title = "Merge request 102"
      sha = "0000000000000000000000000000000000000066"
      merge_base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      patch_id = "0000000000000000000000000000000000010065"

    [[build_steps]]
    name = "nothing"
    remote = "git@github.example.com:example/github.git"

    [[build_steps]]
    name = "capstone"
    remote = "git@gitlab.example.com:example/gitlab.git"

      [[build_steps.merge_requests]]
      number = "7"
      title = "Say \"hello\""
      sha = "0000000000000000000000000000000000000007"
      merge_base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      patch_id = "0000000000000000000000000000000000010006"

    END

  is($artifact->as_toml, $want, "the TOML is just what we expected");

  my $loaded = round_trip($artifact);

  cmp_deeply(
    $loaded,
    methods(
      tag_name => $artifact->tag_name,
      base     => $artifact->base,
      annotation_version => 1,
    ),
    "the metadata survives a round trip",
  );

  # A step with no merge requests comes back with no merge_requests key at
  # all, rather than with an empty one.
  my @want_steps = map {; +{ %$_ } } $artifact->step_data->@*;
  delete $want_steps[1]{merge_requests};

  cmp_deeply($loaded->step_data, \@want_steps, "the step data survives a round trip");
};

subtest "an artifact made partway through a build" => sub {
  my @steps = (
    step(first  => $github, mr_obj($github, 1)),
    step(second => $gitlab, mr_obj($gitlab, 2)),
    step(third  => $gitlab, mr_obj($gitlab, 3)),
  );

  my $config = config(@steps);

  my sub recorded_steps ($artifact) { [ map {; $_->{name} } $artifact->step_data->@* ] }

  cmp_deeply(recorded_steps(artifact($config, this_step => $steps[0])), [ 'first' ],
    "an artifact for the first step records only the first step");

  cmp_deeply(recorded_steps(artifact($config, this_step => $steps[1])), [ qw(first second) ],
    "an artifact for the second step records the first two steps");

  cmp_deeply(recorded_steps(artifact($config)), [ qw(first second third) ],
    "an artifact for no step in particular records every step");
};

# Check which merge request titles come through a round trip in one piece.
my sub title_round_trip_is ($title, $want, $desc) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $loaded = round_trip(artifact(config(step(build => $github, mr_obj($github, 1, title => $title)))));
  my $got    = $loaded ? $loaded->step_data->[0]{merge_requests}[0]{title} : undef;

  is($got, $want, $desc);
}

subtest "merge request titles" => sub {
  title_round_trip_is('Fix the thing',     'Fix the thing',     "a plain title");
  title_round_trip_is('Fix "the" thing',   'Fix "the" thing',   "a title with double quotes");
  title_round_trip_is("Fix l'chose",       "Fix l'chose",       "a title with a single quote");
  title_round_trip_is('Fix [the] #thing',  'Fix [the] #thing',  "a title with TOML punctuation");
  title_round_trip_is("Fix th\x{e9} thing", "Fix th\x{e9} thing", "a title with a non-ASCII character");

  title_round_trip_is('Fix \d+ regex',   'Fix \d+ regex',   "a title with a backslash");
  title_round_trip_is('Fix C:\temp',     'Fix C:\temp',     "a title with a backslash that looks like an escape");
  title_round_trip_is('Ends with a \\',  'Ends with a \\',  "a title ending in a backslash");
  title_round_trip_is('Fix \"this\"',     'Fix \"this\"',     "a title with backslashes and quotes");
};

subtest "finding merge requests in an artifact" => sub {
  my @steps = (
    step(upstream => $github, mr_obj($github, 1), mr_obj($github, 2)),
    step(capstone => $gitlab, mr_obj($gitlab, 1), mr_obj($gitlab, 3)),
  );

  my $config   = config(@steps);
  my $artifact = round_trip(artifact($config));

  ok($artifact->contains_mr(mr_obj($github, 1)),   "github!1 is in the artifact");
  ok($artifact->contains_mr(mr_obj($gitlab, 3)),   "gitlab!3 is in the artifact");
  ok(! $artifact->contains_mr(mr_obj($github, 3)), "github!3 is not in the artifact");
  ok(! $artifact->contains_mr(mr_obj($gitlab, 2)), "gitlab!2 is not in the artifact");

  cmp_deeply(
    $artifact->data_for_mr(mr_obj($gitlab, 1)),
    {
      number     => 1,
      title      => 'Merge request 1',
      sha        => sprintf('%040x', 1),
      merge_base => 'b' x 40,
      patch_id   => sprintf('%040x', 0xFFFF + 1),
      key        => 'git@gitlab.example.com:example/gitlab.git!1',
      step_name  => 'capstone',
      remote     => shallow($gitlab),
    },
    "the data for gitlab!1 is from the right step, and has its remote",
  );

  is($artifact->data_for_mr(mr_obj($gitlab, 2)), undef, "there is no data for gitlab!2");

};

subtest "finding merge requests that have gone missing" => sub {
  # The last build had these steps...
  my $artifact = round_trip(artifact(config(
    step(upstream => $github, mr_obj($github, 1), mr_obj($github, 2)),
    step(capstone => $gitlab, mr_obj($gitlab, 1), mr_obj($gitlab, 3)),
  )));

  # ...and the next one will have the steps given here, each of which is
  # [ name => $remote, @mr_numbers ].  We say what we expect to be reported as
  # missing, as { step name => [ MR numbers ] }.  Missing merge requests that
  # don't belong to any step are listed under the name "(no step)".
  my sub missing_is ($steps, $want, $desc) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my @steps = map {;
      my ($name, $remote, @numbers) = @$_;
      step($name => $remote, map {; mr_obj($remote, $_) } @numbers);
    } @$steps;

    my %got;
    for my $pair ($artifact->missing_mrs(@steps)) {
      my ($step, $mr) = @$pair;
      push $got{ $step ? $step->name : '(no step)' }->@*, $mr->{number};
    }

    cmp_deeply(\%got, { map {; $_ => bag($want->{$_}->@*) } keys %$want }, $desc);
  }

  missing_is(
    [ [ upstream => $github, 1, 2 ], [ capstone => $gitlab, 1, 3 ] ],
    { },
    "nothing is missing",
  );

  missing_is(
    [ [ upstream => $github, 2, 9 ], [ capstone => $gitlab, 3 ] ],
    { upstream => [ 1 ], capstone => [ 1 ] },
    "one merge request is missing from each step",
  );

  missing_is(
    [ [ upstream => $github ], [ capstone => $gitlab, 1, 3 ] ],
    { upstream => [ 1, 2 ] },
    "everything is missing from one step",
  );

  missing_is(
    [ [ renamed => $github, 2 ], [ capstone => $gitlab, 1, 3 ] ],
    { renamed => [ 1 ] },
    "a merge request missing from a renamed step is reported for the step using its remote",
  );

  missing_is(
    [ [ upstream => $github, 1 ], [ extras => $github, 2 ], [ capstone => $gitlab, 1, 3 ] ],
    { },
    "a merge request that has moved to another step is not missing",
  );

  missing_is(
    [ [ first => $github, 1 ], [ second => $github ], [ capstone => $gitlab, 1, 3 ] ],
    { first => [ 2 ] },
    "when a renamed step's remote is used by two steps, the first one gets the report",
  );

  missing_is(
    [ [ extras => $github ], [ upstream => $github, 1 ], [ capstone => $gitlab, 1, 3 ] ],
    { upstream => [ 2 ] },
    "a step with the right name beats an earlier step with the right remote",
  );

  missing_is(
    [ [ upstream => $github, 1, 2 ] ],
    { '(no step)' => [ 1, 3 ] },
    "merge requests from a remote that no step uses belong to no step",
  );

  # Missing merge requests come back in order: first by remote, then by number.
  my @numbers = (1, 2, 3, 10, 11, 12);

  my $big = round_trip(artifact(config(
    step(upstream => $github, map {; mr_obj($github, $_) } @numbers),
    step(capstone => $gitlab, map {; mr_obj($gitlab, $_) } @numbers),
  )));

  cmp_deeply(
    [ map {; $_->[1]{key} =~ s/\A.+(github|gitlab)\.git!/$1!/r } $big->missing_mrs() ],
    [ (map {; "github!$_" } @numbers), (map {; "gitlab!$_" } @numbers) ],
    "missing merge requests are in order",
  );
};

subtest "remotes with credentials in their URLs" => sub {
  my $https  = remote('gitlab', https => 1);
  my $config = config(step(build => $https, mr_obj($https, 1)));

  like($https->clone_url, qr/hunter2/, "the clone URL has a secret in it");

  my $artifact = artifact($config);

  unlike($artifact->as_toml, qr/hunter2/, "the TOML does not");
  like($artifact->as_toml, qr{^remote = "https://gitlab\.example\.com/example/gitlab\.git"$}m,
    "...but it does have the rest of the URL");

  my $loaded = round_trip($artifact);

  ok($loaded->contains_mr(mr_obj($https, 1)), "a merge request can still be found in the artifact");

  is(
    ($loaded->data_for_mr(mr_obj($https, 1)) // {})->{remote},
    $https,
    "...and so can its remote",
  );

  # Tags made before we started leaving the credentials out have them in.
  my $old_toml = $artifact->as_toml =~ s{https://gitlab}{https://minttag:hunter2\@gitlab}r;
  my $old = App::MintTag::Artifact->from_toml($config, $old_toml);

  ok($old->contains_mr(mr_obj($https, 1)), "a merge request can be found in an old artifact");

  is(
    ($old->data_for_mr(mr_obj($https, 1)) // {})->{remote},
    $https,
    "...and so can its remote",
  );
};

subtest "TOML that isn't an artifact" => sub {
  my $config = config(step(build => $github));

  is(
    App::MintTag::Artifact->from_toml($config, 'this is [not TOML'),
    undef,
    "we get nothing from unparseable TOML",
  );

  cmp_deeply(
    App::MintTag::Artifact->from_toml($config, qq{[something]\nelse = "entirely"\n}),
    methods(tag_name => undef, base => undef, annotation_version => undef),
    "we get a pretty empty artifact from TOML that's about something else",
  );
};

done_testing;
