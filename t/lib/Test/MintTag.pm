use v5.36;
package Test::MintTag;
# ABSTRACT: the things every mint-tag test wants

use File::Temp ();

# The tests run a lot of git, and git's behavior depends on the configuration
# of whoever is running it.  Here, we make sure that there isn't any.  This is
# in BEGIN so it's done before anything else gets a chance to run git.
my $HOME;
BEGIN {
  $HOME = File::Temp->newdir('minttag-home-XXXXXX', TMPDIR => 1);

  delete @ENV{ grep {; /\AGIT_/ } keys %ENV };

  $ENV{HOME}                  = "$HOME";
  $ENV{GIT_CONFIG_GLOBAL}     = '/dev/null';
  $ENV{GIT_CONFIG_NOSYSTEM}   = 1;
  $ENV{GIT_TERMINAL_PROMPT}   = 0;
  $ENV{ANSI_COLORS_DISABLED}  = 1;
}

# We log to an array in memory, so that tests can see what was logged.  If
# you're trying to work out why a test is failing, set MINTTAG_LOG_STDERR=1 and
# the logs will also go to your terminal.
use App::MintTag::Logger '$Logger' => { init => {
  ident     => 'mint-tag-test',
  to_self   => 1,
  to_stderr => $ENV{MINTTAG_LOG_STDERR} ? 1 : 0,
  log_pid   => 0,
} };

use Test::More;

use Test::MintTag::World;

use Exporter 'import';
our @EXPORT = qw(
  simple_config
  cyrus_config
  mr

  new_world
  build_ok
  mint_ok
  result_ok
);

# A config with one remote, "forge", and one build step, "build", which will
# include merge requests labeled "include".  Any arguments are added to the
# build step's configuration.
sub simple_config (%step) {
  return {
    meta   => _meta(),
    local  => { target_branch => 'deploy', upstream_base => 'forge/master' },
    remote => { forge => { repo => 'example/project' } },
    build_steps => [
      { name => 'build', remote => 'forge', label => 'include', %step },
    ],
  };
}

# A config like the one used to build Cyrus for Fastmail.  First, trusted pull
# requests from the upstream project on "github" are merged.  Then, trusted
# merge requests from a private mirror on "gitlab" are rebased onto that and
# merged, and the result is tagged, and the tag is pushed to gitlab.
#
# The arguments are (step name => { config to add to that step }).
sub cyrus_config (%arg) {
  return {
    meta   => _meta(),
    local  => { target_branch => 'deploy', upstream_base => 'github/master' },
    remote => {
      github => { repo => 'cyrusimap/cyrus-imapd' },
      gitlab => { repo => 'fastmail/cyrus-imapd'  },
    },
    build_steps => [
      {
        name   => 'github',
        remote => 'github',
        label  => 'include-in-fastmail',
        trusted_org => 'fastmail',
        ($arg{github} // {})->%*,
      },
      {
        name   => 'capstone',
        remote => 'gitlab',
        label  => 'include-in-fastmail',
        trusted_org => 'fastmail',
        tag_prefix  => 'fm',
        rebase      => \1,
        push_tag_to => 'gitlab',
        ($arg{capstone} // {})->%*,
      },
    ],
  };
}

sub _meta {
  return {
    committer_name  => 'MintTag',
    committer_email => 'minttag@example.com',
  };
}

# This is sugar for writing a merge request spec, as taken by a World.  You
# say:
#
#   mr(12, alice => 'fix-things', fork => 1)
#
# ...and get merge request 12, from alice's branch "fix-things".  Everything
# after the branch name is passed along to Test::MintTag::Forge's add_mr.
sub mr ($number, $author, $branch, %rest) {
  return { number => $number, author => $author, branch => $branch, %rest };
}

# Build a world.  The arguments are those of Test::MintTag::World's
# constructor, most notably "config" and "mrs".
sub new_world (%arg) {
  return Test::MintTag::World->new(\%arg);
}

# Build a world, run mint-tag in it, and check on how it went.  The spec is a
# hashref with the arguments to new_world, plus:
#
#   with    - a hashref of arguments to pass to the world's mint method
#   expect  - a hashref of expectations, as described at result_ok
#
# This returns the world and the result, in case there's more to do.
sub build_ok ($desc, $spec) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my %spec   = %$spec;
  my $with   = delete $spec{with}   // {};
  my $expect = delete $spec{expect} // {};

  my $world  = new_world(%spec);
  my $result = $world->mint(%$with);

  result_ok($result, $desc, $expect);

  return ($world, $result);
}

# Run mint-tag in an existing world, and check on how it went.  The spec is
# like the one for build_ok, but only has "with" and "expect".  This returns
# the result.
sub mint_ok ($world, $desc, $spec) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $result = $world->mint(($spec->{with} // {})->%*);
  result_ok($result, $desc, $spec->{expect} // {});

  return $result;
}

# Check a Test::MintTag::Result against a hashref of expectations.  All of
# them are optional, except that we always check on whether mint-tag died.
#
#   error   - a regex that the exception has to match; without this, we
#             expect that there was no exception
#   merged  - an arrayref of the idents (like "github!12") of exactly the
#             merge requests that were picked up, in order; each one's head
#             has to be reachable from the built branch
#   history - the shape of the built branch's history; see shape_problems in
#             Test::MintTag::Result
#   message - a regex that the commit message at the head of the built branch
#             has to match
#   tag     - a regex that the name of the new tag has to match, or undef to
#             say that there must be no new tag
#   logs    - an arrayref of regexes, each of which has to match a log line
#   no_logs - an arrayref of regexes, none of which may match a log line
#
# If anything fails, the logs from the run are dumped as diagnostics.
sub result_ok ($result, $desc, $expect) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my %expect = %$expect;

  my $ok = subtest $desc => sub {
    if (my $want = delete $expect{error}) {
      like($result->error, $want, "mint-tag died as expected");
    } else {
      is($result->error, undef, "mint-tag did not die");
    }

    if (my $want = delete $expect{merged}) {
      my @mrs = $result->mrs;

      is_deeply([ map {; $_->ident } @mrs ], $want, "picked up the right MRs")
        or diag explain [ map {; $_->ident } @mrs ];

      my $head = $result->rev_for('head');
      my @lost = grep {; ! $result->local_repo->is_ancestor($_->sha, $head) } @mrs;

      ok(! @lost, "every MR is in the built branch")
        or diag "not merged: " . join q{, }, map {; $_->ident } @lost;
    }

    if (my $want = delete $expect{history}) {
      my @problems = $result->shape_problems($result->rev_for('head'), $want);
      ok(! @problems, "history is the right shape") or diag $_ for @problems;
    }

    if (my $want = delete $expect{message}) {
      my $message = $result->local_repo->message($result->rev_for('head'));
      like($message, $want, "commit message at head");
    }

    if (exists $expect{tag}) {
      my $want = delete $expect{tag};

      if (defined $want) {
        like($result->tag // '(no tag)', $want, "made the right tag");
      } else {
        is_deeply($result->new_tags, [], "made no new tag");
      }
    }

    for my $want ((delete $expect{logs} // [])->@*) {
      ok((grep {; $_ =~ $want } $result->logs->@*), "logged: $want");
    }

    for my $want ((delete $expect{no_logs} // [])->@*) {
      ok(! (grep {; $_ =~ $want } $result->logs->@*), "did not log: $want");
    }

    # If somebody misspells an expectation, we don't want to quietly pass.
    ok(! %expect, "understood every expectation")
      or diag "unknown expectations: @{[ sort keys %expect ]}";
  };

  diag join qq{\n}, "logs from this run:", map {; "  $_" } $result->logs->@*
    unless $ok;

  return $ok;
}

1;
