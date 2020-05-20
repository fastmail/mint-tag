use v5.20;
package App::MintTag::Approver;
# ABSTRACT: ask a human to confirm a merge plan

use Moo;
use experimental qw(postderef signatures);

use List::Util qw(sum0);
use Term::ANSIColor qw(color colored);
use Try::Tiny;

use App::MintTag::Artifact;
use App::MintTag::Logger '$Logger';
use App::MintTag::Util qw(run_git re_for_tag);

has config => (
  is => 'ro',
  required => 1,
);

around BUILDARGS => sub ($orig, $self, $config) {
  return $self->$orig({ config => $config });
};

# a MintTag::Artifact object
has last_build => (
  is => 'ro',
  predicate => 'has_last_build',
  writer => '_set_last_build',
);

has mrs_by_index => (
  is => 'ro',
  lazy => 1,
  default => sub { {} },
);

sub is_valid_mr_index ($self, $idx) { exists $self->mrs_by_index->{$idx} }
sub data_for_mr_index ($self, $idx) { $self->mrs_by_index->{$idx} }

# Returns true to continue, false to abort
sub confirm_plan ($self) {
  my $head = run_git('rev-parse', 'HEAD');

  $self->maybe_set_last_build;

  say '';

  printf("Okay, here's the plan! We're going to build a branch called %s.\n",
    colored($self->config->target_branch_name, 'bright_blue'),
  );

  printf("We're starting with %s, which is at commit %s.\n",
    colored($self->config->upstream_base, 'bright_blue'),
    colored(substr($head, 0, 12), 'bright_blue'),
  );

  if ($self->has_last_build) {
    printf("The last tag I found for this config was %s.\n",
      colored($self->last_build->tag_name, 'bright_blue'),
    );
  }

  say '';

  my $step_counter = 1;
  my $mr_counter = 1;

  my $total_mr_count = sum0 map {; scalar $_->merge_requests } $self->config->steps;
  unless ($total_mr_count > 0) {
    say "Well, that would have been a great branch, but I couldn't find anything";
    say "to merge. I guess I'll give up now; maybe next time!";
    return;
  }

  for my $step ($self->config->steps) {
    my $header = "Step $step_counter: " . $step->name;
    $step_counter++;
    say $header;
    say '-' x length $header;

    $self->output_step($step, \$mr_counter);
  }

  return $self->enter_interactive_mode;
}

sub enter_interactive_mode ($self) {
  my $header = "Continue with merge? yes/no/help\n> ";
  my $does_not_compute = "Sorry, I didn't understand that! Try again?\n> ";

  # Rik will say I should use CLI_M8 for this; maybe he's right.
  print $header;

  while (my $input = <STDIN>) {
    chomp($input);
    $input =~ s/^\s*|\s*$//g;
    $input = lc $input;

    last if $input =~ /^no?/ || $input =~ /^q(uit)?/;

    return $self->confirm_plan if $input eq 'plan';

    if ($input =~ /^y(es)?/) {
      say "Great...here we go!\n";
      return 1;
    }

    if ($input eq 'help') {
      say "yes        go ahead, merge away!";
      say "no         that doesn't look right; abort!";
      say "plan       print the whole plan again";

      say "log #      show oneline log for entry #, starting from last build"
        if $self->has_last_build;

      say "diff #     show diff for entry #, starting from last build"
        if $self->has_last_build;

      say "logall #   show oneline log for entry #, starting from its merge base";
      say "diffall #  show diff for entry #, starting from its merge base";

      print "> ";
      next;
    }

    my ($action, $num, @rest) = split /\s+/, $input;

    if (@rest || ! $num) {
      print $does_not_compute;
      next;
    }

    # We can't meaningfully provide log/diff if we don't have base.
    if (! $self->has_last_build && ($action eq 'diff' || $action eq 'log')) {
      print $does_not_compute;
      next;
    }

    unless ($self->is_valid_mr_index($num)) {
      print "Hmm, you said you wanted MR #$num, but that doesn't seem valid.\n> ";
      next;
    }

    state $ACTIONS = {
      diff    => \&print_diff_for_mr,
      log     => \&print_log_for_mr,
      logall  => \&print_total_log_for_mr,
      diffall => \&print_total_diff_for_mr,
    };

    my $sub = $ACTIONS->{$action};

    unless ($sub) {
      print $does_not_compute;
      next;
    }

    $sub->($self, $num);
    print $header;
  }

  # EOF; assume abort
  say "Alright then...see you next time!";
  return;
}

# return the most recent tag matching this config's *last* defined step.
sub last_tag_for_config ($self) {
  my ($prefix) = map  {; $_->tag_prefix         }
                 grep {; defined $_->tag_prefix }
                 reverse $self->config->steps;

  return unless $prefix;

  my $output = run_git(qw(tag -l), "$prefix-*");

  my $re = re_for_tag($prefix);

  my @have = sort {; $b cmp $a }
             grep {; $_ =~ $re }
             split /\n/, $output;

  return $have[0];
}

sub maybe_set_last_build ($self) {
  my $tagname = $self->last_tag_for_config;
  return unless $tagname;

  my $body = run_git(qw(tag -l --format=%(contents)), $tagname);

  unless ($body =~ /\Amint-tag generated commit/) {
    $Logger->log("got weird commit message for $tagname; ignoring");
    return;
  }

  # slice off header and blank line
  $body =~ s/\A.*?\n\n//m;

  my $build = App::MintTag::Artifact->from_toml($self->config, $body);
  return unless $build;

  if ($build->annotation_version != $App::MintTag::ANNOTATION_VERSION) {
    $Logger->log([
      "ignoring previous build; built with annotation version %s, current is %s",
      $build->annotation_version,
      $App::MintTag::ANNOTATION_VERSION,
    ]);

    return;
  }

  $self->_set_last_build($build);
}

sub output_step ($self, $step, $counter_ref) {
  unless ($step->merge_requests) {
    printf("Nothing to do! No merge requests labeled %s found on remote %s\n\n",
      $step->label,
      $step->remote->name,
    );

    return;
  }

  printf("We'll include these merge requests from the remote named %s:\n\n",
    $step->remote->name,
  );

  if ($step->rebase) {
    say colored("NB: each of these will be rebased before merging!\n", 'yellow');
  }

  for my $mr ($step->merge_requests) {
    my $idx = $$counter_ref++;
    $self->output_mr($step, $mr, $idx);
  }

  # Find anything that was in the last build, but has now disappeared
  if ($self->has_last_build) {
    my @missing = $self->last_build->mrs_not_in($step);
    $self->output_missing_mrs(\@missing);
  }

  if (my $remote = $step->push_tag_to) {
    say "\nWe'd tag that and push it tag to the remote named " . $remote->name . '.';
  }

  say "";
}

sub output_mr ($self, $step, $mr, $idx) {
  my $delta = 'no previous build';
  my $old;

  if (my $artifact = $self->last_build) {
    if ($artifact->contains_mr($mr)) {
      $old = $artifact->data_for_mr($mr);
      my $short = substr $old->{sha}, 0, 8;

      $delta =
          $mr->sha eq $old->{sha}               ? 'unchanged'
        : $mr->patch_id eq $old->{patch_id}     ? "was $short, rebased but unchanged"
        : $mr->merge_base ne $old->{merge_base} ? "was $short, rebased and altered"
        :                                         "was $short";

      if ($old->{step_name} ne $step->name) {
        $delta .= ", was in step named $old->{step_name}";
      }
    } else {
      $delta = 'new branch';
    }
  }

  my $mr_desc = sprintf("!%d, %s (%s)\n    %s - %s",
    $mr->number,
    $mr->short_sha,
    $delta,
    $mr->author,
    $mr->title,
  );

  say "$idx: $mr_desc";
  $self->mrs_by_index->{$idx} = [ $old,  $mr ];
}

sub output_missing_mrs ($self, $missing) {
  return unless @$missing;

  if (@$missing) {
    say "\nLast time, we included these merge requests, which have disappeared:";
  }

  for my $gone (@$missing) {
    # Try to get some details about them, if we can.
    my $short_sha = substr $gone->{sha}, 0, 8;
    my $mr_desc = "!$gone->{number} (was $short_sha; unable to get more data)";

    # NOTE: this is inefficient in the face of 'plan', because it'll
    # refetch every time. I think that's fine for right now.
    if (my $remote = $gone->{remote}) {
      my $mr = $remote->get_mr($gone->{number});
      $mr_desc = sprintf("!%d, %s (status: %s)\n    %s - %s",
        $mr->number,
        $mr->short_sha,
        $mr->state,
        $mr->author,
        $mr->title,
      );
    }

    say "-: $mr_desc";
  }
}

sub _run_git_for_mr ($self, $idx, $code) {
  my ($old, $mr) = $self->data_for_mr_index($idx)->@*;

  my $out = $code->($old, $mr);

  if (!$out) {
    say "No changes detected since last build!\n";
    return;
  }

  print "$out\n\n";
}

sub print_diff_for_mr ($self, $idx) {
  return $self->_run_git_for_mr($idx, sub ($old, $mr) {
    run_git('diff', '--color', $old->{sha}, $mr->sha);
  });
}

sub print_total_diff_for_mr ($self, $idx) {
  my (undef, $mr) = $self->data_for_mr_index($idx)->@*;
  my $out = run_git('diff', '--color', $mr->merge_base, $mr->sha);
  print "$out\n\n";
}

sub print_log_for_mr ($self, $idx) {
  return $self->_run_git_for_mr($idx, sub ($old, $mr) {
    run_git('log', '--oneline', join(q{..}, $old->{sha}, $mr->sha));
  });
}

sub print_total_log_for_mr ($self, $idx) {
  my (undef, $mr) = $self->data_for_mr_index($idx)->@*;

  my $out = run_git(
    'log',
    '--oneline',
    join(q{..}, $mr->merge_base, $mr->sha),
  );

  print "$out\n\n";
}

1;
