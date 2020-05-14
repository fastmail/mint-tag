use v5.20;
package Mergeotron::Approver;
use Moo;
use experimental qw(postderef signatures);

use List::Util qw(sum0);
use Term::ANSIColor qw(color colored);
use Try::Tiny;
use Types::Standard qw(HashRef InstanceOf Maybe);

use Mergeotron::Artifact;
use Mergeotron::Logger '$Logger';
use Mergeotron::Util qw(run_git re_for_tag);

has config => (
  is => 'ro',
  required => 1,
  isa => InstanceOf['Mergeotron::Config'],
);

has last_build => (
  is => 'ro',
  isa => Maybe[InstanceOf['Mergeotron::Artifact']],
  predicate => 'has_last_build',
  writer => '_set_last_build',
);

around BUILDARGS => sub ($orig, $self, $config) {
  return $self->$orig({ config => $config });
};

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
    exit 0;
  }

  for my $step ($self->config->steps) {
    my $header = "Step $step_counter: " . $step->name;
    $step_counter++;
    say $header;
    say '-' x length $header;

    $self->output_step($step, \$mr_counter);
  }

  print "Continue? yes/no/help\n> ";

  while (my $input = <STDIN>) {
    chomp($input);

    if ($input =~ /^y(es)?/i) {
      say "Great...here we go!\n";
      return;
    }

    if ($input =~ /^no?/i || $input eq 'q') {
      say "Alright then...see you next time!";
      exit 1;
    }

    print "Sorry, I didn't understand that! Try again? ";
  }

  die "wait, how did you get here?";
}

# return the most recent tag matching this config's *last* defined step.
sub last_tag_for_config ($self) {
  my ($prefix) = map  {; $_->tag_prefix         }
                 grep {; defined $_->tag_prefix }
                 reverse $self->config->steps;

  return unless $prefix;

  my $output = run_git(qw(tag -l), "$prefix*");

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

  unless ($body =~ /\Amergeotron-tagged commit/) {
    $Logger->log("got weird commit message for $tagname; ignoring");
    return;
  }

  # slice off header and blank line
  $body =~ s/\A.*?\n\n//m;

  my $build = Mergeotron::Artifact->from_toml($self->config, $body);
  return unless $build;

  if ($build->annotation_version != $Mergeotron::ANNOTATION_VERSION) {
    $Logger->log([
      "ignoring previous build; built with annotation version %s, current is %s",
      $build->annotation_version,
      $Mergeotron::ANNOTATION_VERSION,
    ]);
  }

  $self->_set_last_build($build);
}

sub output_step ($self, $step, $counter_ref) {
  unless ($step->merge_requests) {
    printf("Nothing to do! No merge requests labeled %s found on remote %s\n",
      $step->label,
      $step->remote->name,
    );

    return;
  }

  printf("We'll include these merge requests from the remote named %s:\n\n",
    $step->remote->name,
  );

  for my $mr ($step->merge_requests) {
    my $delta = 'no previous build';

    if (my $artifact = $self->last_build) {
      if ($artifact->contains_mr($mr)) {
        my $old = $artifact->data_for_mr($mr);
        my $short_sha = substr $old->{sha}, 0, 8;

        $delta = $mr->sha        eq $old->{sha}  ? 'unchanged'
               : $mr->merge_base ne $old->{base} ? "was $short_sha, has been rebased"
               :                                   "was $short_sha";

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

    my $i = $$counter_ref++;
    say "$i: $mr_desc";
  }

  # Find anything that was in the last build, but has now disappeared
  if ($self->has_last_build) {
    my @missing = $self->last_build->mrs_not_in($step);
    if (@missing) {
      say "\nLast time, we included these merge requests, which have disappeared:";
    }

    for my $gone (@missing) {
      # Try to get some details about them, if we can.
      my $short_sha = substr $gone->{sha}, 0, 8;
      my $mr_desc = "!$gone->{number} (was $short_sha; unable to get more data)";

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

  if (my $remote = $step->push_tag_to) {
    say "\nWe'd tag that and push it tag to the remote named " . $remote->name . '.';
  }

  say "";
}

1;
