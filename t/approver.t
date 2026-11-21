use v5.36;

use lib 't/lib';
use Test::MintTag;

use Test::More;

# These tests are about interactive mode, where mint-tag shows the user its
# plan, and how that plan differs from the last build, and then asks whether
# to go ahead.

# Run mint-tag interactively and check the plan it shows.  The spec has:
#
#   input  - an arrayref of lines to type at the prompt; by default, just "no"
#   plan   - an arrayref of the lines we expect in the plan, where only the
#            step headings and merge request lines count, and where the merge
#            request lines have been boiled down from this:
#               3: !12, 0123abcd (was 4567cdef, rebased but unchanged)
#            to this:
#               3: !12 (was SHA, rebased but unchanged)
#   expect - expectations for result_ok
#
# The result is returned.
my sub plan_ok ($world, $desc, $spec) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $result = $world->mint(input => $spec->{input} // [ 'no' ]);

  subtest $desc => sub {
    result_ok($result, "the run went as expected", $spec->{expect} // {});

    return unless $spec->{plan};

    # If the user asked to see the plan again, there'll be more than one.
    my (undef, $plan) = split /^Okay, here's the plan!/m, $result->output;

    my @lines;
    for my $line (split /\n/, $plan // '') {
      push @lines, $line if $line =~ /\AStep \d+: /;

      if (my ($index, $number, $delta) = $line =~ /\A(\d+|-): !(\d+), \w{8} \((.+)\)\z/) {
        push @lines, "$index: !$number (" . ($delta =~ s/\b[0-9a-f]{8}\b/SHA/gr) . ")";
      }
    }

    is_deeply(\@lines, $spec->{plan}, "the plan is what we expected")
      or diag $result->output;
  };

  return $result;
}

my $PROMPT = qr/^Continue with merge\? yes\/no\/help\n> /m;
my $FM_TAG = qr/fm-20261120\.001-g\w{8}/;

subtest "the first build" => sub {
  my %spec = (
    config => cyrus_config(),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix'), mr(102, bob => 'sieve-fix') ],
      gitlab => [ mr(7, carol => 'fm-tweaks') ],
    },
  );

  my @plan = (
    'Step 1: github',
    '1: !101 (no previous build)',
    '2: !102 (no previous build)',
    'Step 2: capstone',
    '3: !7 (no previous build)',
  );

  plan_ok new_world(%spec), "the user says yes" => {
    input  => [ 'yes' ],
    plan   => \@plan,
    expect => {
      merged => [ 'github!101', 'github!102', 'gitlab!7' ],
      tag    => qr/\A$FM_TAG\z/,
      output => [
        qr/^Okay, here's the plan! We're going to build a branch called deploy\.$/m,
        qr/^We're starting with github\/master, which is at commit [0-9a-f]{12}\.$/m,
        qr/^We'll include these merge requests from the remote named github:$/m,
        qr/^1: !101, \w{8} \(no previous build\)\n    alice - Do the work from jmap-fix$/m,
        qr/^NB: each of these will be rebased before merging!$/m,
        qr/^We'd tag that and push it tag to the remote named gitlab\.$/m,
        $PROMPT,
        qr/^> Great\.\.\.here we go!$/m,
      ],
      no_output => [ qr/The last tag I found/ ],
    },
  };

  for my $input ([ 'no' ], [ 'q' ], [ ]) {
    my $typed = @$input ? "says $input->[0]" : "hangs up";

    plan_ok new_world(%spec), "the user $typed" => {
      input  => $input,
      plan   => \@plan,
      expect => {
        history   => 'base',
        tag       => undef,
        output    => [ $PROMPT, qr/^> Alright then\.\.\.see you next time!$/m ],
        no_output => [ qr/here we go/ ],
        no_logs   => [ qr/merging/ ],
      },
    };
  }

  plan_ok new_world(config => cyrus_config()), "there's nothing to merge" => {
    input  => [ 'yes' ],
    plan   => [ ],
    expect => {
      tag       => undef,
      output    => [ qr/I couldn't find anything\nto merge\. I guess I'll give up now/ ],
      no_output => [ $PROMPT ],
    },
  };
};

subtest "what's changed since the last build" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build'),
    mrs    => {
      forge => [
        mr(1, alice => 'unchanged'),
        mr(2, alice => 'updated'),
        mr(3, alice => 'rebased', base => 'master~1'),
        mr(4, alice => 'rebased-and-updated', base => 'master~1'),
        mr(5, bob   => 'closed'),
        mr(6, bob   => 'unlabeled'),
      ],
    },
  );

  my $first = mint_ok $world, "the last build" => {
    expect => { tag => qr/\Abuild-20261120\.001-g\w{8}\z/ },
  };

  my $forge = $world->forge('forge');

  $forge->update_mr(2);
  $forge->rebase_mr(3);
  $forge->rebase_mr(4);
  $forge->update_mr(4);
  $forge->close_mr(5);
  $forge->set_labels(6);
  $world->add_mr(forge => mr(7, carol => 'new')->%*);

  my $old_sha = substr $first->rev_for('forge!2'), 0, 8;
  my $new_sha = substr $forge->mr_data(2)->{sha}, 0, 8;

  plan_ok $world, "the plan says how each merge request has changed" => {
    plan => [
      'Step 1: build',
      '1: !1 (unchanged)',
      '2: !2 (was SHA)',
      '3: !3 (was SHA, rebased but unchanged)',
      '4: !4 (was SHA, rebased and altered)',
      '5: !7 (new branch)',
      '-: !5 (status: closed)',
      '-: !6 (status: opened)',
    ],
    expect => {
      output => [
        qr/^The last tag I found for this config was build-20261120\.001-g\w{8}\.$/m,
        qr/^2: !2, $new_sha \(was $old_sha\)$/m,
        qr/^Last time, we included these merge requests, which have disappeared:$/m,
        qr/^-: !5, \w{8} \(status: closed\)\n    bob - Do the work from closed$/m,
      ],
    },
  };

  $world->config->{build_steps}[0]{name} = 'renamed';
  $world->write_config;

  plan_ok $world, "the plan says when a merge request was in a different step" => {
    plan => [
      'Step 1: renamed',
      '1: !1 (unchanged, was in step named build)',
      '2: !2 (was SHA, was in step named build)',
      '3: !3 (was SHA, rebased but unchanged, was in step named build)',
      '4: !4 (was SHA, rebased and altered, was in step named build)',
      '5: !7 (new branch)',
      '-: !5 (status: closed)',
      '-: !6 (status: opened)',
    ],
  };
};

subtest "when everything in a step has disappeared" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build'),
    mrs    => { forge => [ map {; mr($_, alice => "branch-$_") } 1, 2, 3, 10, 11, 12 ] },
  );

  mint_ok $world, "the last build" => { expect => { tag => qr/\Abuild-/ } };

  $world->forge('forge')->close_mr($_) for 1, 2, 3, 10, 11, 12;

  plan_ok $world, "the plan says what's gone, in order, even though there's nothing to merge" => {
    plan   => [ 'Step 1: build', map {; "-: !$_ (status: closed)" } 1, 2, 3, 10, 11, 12 ],
    expect => {
      output    => [ qr/I couldn't find anything\nto merge/ ],
      no_output => [ $PROMPT ],
    },
  };

  $world = new_world(
    config => cyrus_config(),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix') ],
      gitlab => [ mr(7, carol => 'fm-tweaks') ],
    },
  );

  mint_ok $world, "the last build" => { expect => { tag => qr/\A$FM_TAG\z/ } };

  $world->forge('github')->close_mr(101);

  plan_ok $world, "the plan says what's gone from a step with nothing left in it" => {
    plan   => [
      'Step 1: github',
      '-: !101 (status: closed)',
      'Step 2: capstone',
      '1: !7 (unchanged)',
    ],
    expect => {
      output => [ qr/^Nothing to do! No merge requests labeled include-in-fastmail found on remote github$/m ],
    },
  };
};

subtest "what's changed since the last build, when steps rebase" => sub {
  my $world = new_world(
    config => cyrus_config(),
    mrs    => {
      github => [ mr(101, alice => 'jmap-fix') ],
      gitlab => [
        mr(7, carol => 'unchanged'),
        mr(8, carol => 'updated'),
        mr(9, carol => 'rebased', base => 'master~1'),
        mr(10, carol => 'rebased-and-updated', base => 'master~1'),
      ],
    },
  );

  my $gitlab  = $world->forge('gitlab');
  my $old_sha = substr $gitlab->mr_data(8)->{sha}, 0, 8;

  mint_ok $world, "the last build" => { expect => { tag => qr/\A$FM_TAG\z/ } };

  # mint-tag rebased everything from gitlab, but that's not the kind of change
  # the plan is talking about.  It's about what's changed on the forge.
  plan_ok $world, "nothing has changed" => {
    plan => [
      'Step 1: github',
      '1: !101 (unchanged)',
      'Step 2: capstone',
      '2: !7 (unchanged)',
      '3: !8 (unchanged)',
      '4: !9 (unchanged)',
      '5: !10 (unchanged)',
    ],
  };

  $gitlab->update_mr(8, message => "Update some more\n");
  $gitlab->rebase_mr(9);
  $gitlab->rebase_mr(10);
  $gitlab->update_mr(10);

  plan_ok $world, "the plan says how each merge request has changed on the forge" => {
    input  => [ 'log 3' ],
    plan   => [
      'Step 1: github',
      '1: !101 (unchanged)',
      'Step 2: capstone',
      '2: !7 (unchanged)',
      '3: !8 (was SHA)',
      '4: !9 (was SHA, rebased but unchanged)',
      '5: !10 (was SHA, rebased and altered)',
    ],
    expect => {
      output => [
        qr/^3: !8, \w{8} \(was $old_sha\)$/m,
        qr/^> [0-9a-f]{7} Update some more\n\n$PROMPT/m,
      ],
    },
  };
};

subtest "finding the last build" => sub {
  my sub fresh_world (%arg) {
    my $world = new_world(
      config => cyrus_config(%arg),
      mrs    => {
        github => [ mr(101, alice => 'jmap-fix') ],
        gitlab => [ mr(7, carol => 'fm-tweaks') ],
      },
    );

    mint_ok $world, "the last build" => { expect => {} };

    return $world;
  }

  my @known = ('Step 1: github', '1: !101 (unchanged)',
               'Step 2: capstone', '2: !7 (unchanged)');

  my @unknown = ('Step 1: github', '1: !101 (no previous build)',
                 'Step 2: capstone', '2: !7 (no previous build)');

  plan_ok fresh_world(github => { tag_prefix => 'upstream' }),
    "when several steps make tags, we use the last step's" => {
      plan   => \@known,
      expect => { output => [ qr/^The last tag I found for this config was $FM_TAG\.$/m ] },
    };

  {
    my $world = fresh_world();
    $world->set_date('2026-11-21');
    $world->forge('gitlab')->update_mr(7);
    mint_ok $world, "another build, the next day" => { expect => {} };

    plan_ok $world, "when there are several tags, we use the newest" => {
      plan   => \@known,
      expect => { output => [ qr/^The last tag I found for this config was fm-20261121\.001-g\w{8}\.$/m ] },
    };
  }

  {
    my $world = fresh_world();
    $world->forge('gitlab')->repo->git(qw(tag other-20261120.999-g01234567 master));

    plan_ok $world, "tags with some other prefix don't matter" => {
      plan   => \@known,
      expect => { output => [ qr/^The last tag I found for this config was $FM_TAG\.$/m ] },
    };
  }

  # A tag that sorts after our last build, but that isn't one of our builds,
  # gets in the way: we find it, can't use it, and give up on finding the last
  # build at all.
  {
    my $world = fresh_world();
    $world->forge('gitlab')->repo->git(qw(tag fm-20261120.002-hotfix master));

    plan_ok $world, "a newer tag that we didn't make hides the last build" => {
      plan   => \@unknown,
      expect => {
        logs      => [ qr/got weird commit message for fm-20261120\.002-hotfix; ignoring/ ],
        output    => [ qr/^We're starting with/m ],
        no_output => [ qr/The last tag I found/ ],
      },
    };
  }

  {
    my $world = fresh_world();
    local $App::MintTag::ANNOTATION_VERSION = 2;

    plan_ok $world, "a last build with an old annotation version is ignored" => {
      plan   => \@unknown,
      expect => {
        logs      => [ qr/ignoring previous build; built with annotation version 1, current is 2/ ],
        no_output => [ qr/The last tag I found/ ],
      },
    };
  }
};

subtest "asking questions at the prompt" => sub {
  my $world = new_world(
    config => simple_config(tag_prefix => 'build'),
    mrs    => {
      forge => [
        mr(1, alice => 'steady', base => 'master~1'),
        mr(2, bob   => 'moving', message => "Start moving\n"),
      ],
    },
  );

  my @basic_help = (
    qr/^> yes        go ahead, merge away!$/m,
    qr/^no         that doesn't look right; abort!$/m,
    qr/^plan       print the whole plan again$/m,
    qr/^logall #   show oneline log for entry #, starting from its merge base$/m,
    qr/^diffall #  show diff for entry #, starting from its merge base$/m,
  );

  my @last_build_help = (
    qr/^log #      show oneline log for entry #, starting from last build$/m,
    qr/^diff #     show diff for entry #, starting from last build$/m,
  );

  my $confused = qr/Sorry, I didn't understand that! Try again\?/;

  plan_ok $world, "help, before there's a last build" => {
    input  => [ 'help' ],
    expect => { output => \@basic_help, no_output => \@last_build_help },
  };

  plan_ok $world, "asking to see the plan again" => {
    input  => [ 'plan', 'plan' ],
    expect => { output => [ qr/(?:Okay, here's the plan!.+){3}/s ] },
  };

  plan_ok $world, "things we don't understand" => {
    input  => [ 'make me a sandwich' ],
    expect => { output => [ qr/^> $confused\n> Alright then/m ] },
  };

  plan_ok $world, "commands with no number, or with too much" => {
    input  => [ 'logall', 'logall 1 2', 'frobnicate 1' ],
    expect => { output => [ qr/(?:> $confused\n){3}/ ] },
  };

  plan_ok $world, "a merge request that isn't in the plan" => {
    input  => [ 'logall 3' ],
    expect => { output => [ qr/^> Hmm, you said you wanted MR #3, but that doesn't seem valid\.$/m ] },
  };

  plan_ok $world, "log and diff, before there's a last build" => {
    input  => [ 'log 1', 'diff 1' ],
    expect => { output => [ qr/(?:> $confused\n){2}/ ] },
  };

  plan_ok $world, "logall and diffall" => {
    input  => [ 'logall 2', 'diffall 1' ],
    expect => {
      output => [
        qr/^> [0-9a-f]{7} Start moving\n\n$PROMPT/m,
        qr{\+\+\+ b/topic/steady\.txt},
      ],
      no_output => [ qr{topic/moving\.txt}, qr/util: return two/ ],
    },
  };

  # Now we'll have a last build.
  mint_ok $world, "a build" => { expect => { tag => qr/\Abuild-/ } };

  $world->forge('forge')->update_mr(2, message => "Keep moving\n");
  $world->add_mr(forge => mr(3, carol => 'new', message => "Arrive\n")->%*);

  plan_ok $world, "help, once there's a last build" => {
    input  => [ 'help' ],
    expect => { output => [ @basic_help, @last_build_help ] },
  };

  plan_ok $world, "log and diff show what's new since the last build" => {
    input  => [ 'log 2', 'diff 2' ],
    expect => {
      output    => [ qr/^> [0-9a-f]{7} Keep moving\n\n$PROMPT/m, qr{\+\+\+ b/topic/moving-4\.txt} ],
      no_output => [ qr/Start moving/, qr{topic/moving\.txt} ],
    },
  };

  plan_ok $world, "logall still shows everything" => {
    input  => [ 'logall 2' ],
    expect => { output => [ qr/^> [0-9a-f]{7} Keep moving\n[0-9a-f]{7} Start moving\n\n$PROMPT/m ] },
  };

  plan_ok $world, "log and diff for a merge request that hasn't changed" => {
    input  => [ 'log 1', 'diff 1' ],
    expect => { output => [ qr/(?:No changes detected since last build!\n\n$PROMPT){2}/m ] },
  };

  # There's nothing to compare a new merge request to, so we show all of it.
  my $all_of_it = qr/This merge request wasn't in the last build, so here's all of it:\n\n/;

  plan_ok $world, "log and diff for a merge request that's new since the last build" => {
    input  => [ 'log 3', 'diff 3' ],
    expect => {
      output => [
        qr/^> $all_of_it[0-9a-f]{7} Arrive\n\n$PROMPT/m,
        qr{^> $all_of_it.+\+\+\+ b/topic/new\.txt}ms,
      ],
    },
  };
};

subtest "when a build fails in interactive mode" => sub {
  my $world = new_world(
    config => simple_config(),
    mrs    => {
      forge => [
        mr(1, alice => 'three', files => { 'imap/append.c' => "int append(void) { return 3; }\n" }),
        mr(2, bob   => 'four',  files => { 'imap/append.c' => "int append(void) { return 4; }\n" }),
      ],
    },
  );

  my $local = $world->local_repo->path;

  plan_ok $world, "the user is told where to find the mess" => {
    input  => [ 'yes' ],
    expect => {
      error  => qr/fatal conflict between forge!1 and forge!2/,
      output => [
        qr/^Something went wrong during the merge process\. Your local tree is probably$/m,
        qr/^Working directory:\n    \Q$local\E$/m,
      ],
    },
  };

  mint_ok $world, "in auto mode, nobody is told anything" => {
    expect => {
      error     => qr/fatal conflict between forge!1 and forge!2/,
      no_output => [ qr/./ ],
    },
  };
};

done_testing;
