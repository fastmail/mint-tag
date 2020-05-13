use v5.20;
package Mergeotron::Approver;
use Moo;
use experimental qw(postderef signatures);

use List::Util qw(sum0);
use Term::ANSIColor qw(color colored);
use Types::Standard qw(InstanceOf);

use Mergeotron::Util qw(run_git);

has config => (
  is => 'ro',
  required => 1,
  isa => InstanceOf['Mergeotron::Config'],
);

around BUILDARGS => sub ($orig, $self, $config) {
  return $self->$orig({ config => $config });
};

sub confirm_plan ($self) {
  my $head = run_git('rev-parse', 'HEAD');

  say '';

  printf("Okay, here's the plan! We're going to build a branch called %s.\n",
    colored($self->config->target_branch_name, 'bright_blue'),
  );

  printf("We're starting with %s, which is at commit %s.\n\n",
    colored($self->config->upstream_base, 'bright_blue'),
    colored(substr($head, 0, 12), 'bright_blue'),
  );

  my $i = 1;

  my $total_mr_count = sum0 map {; scalar $_->merge_requests } $self->config->steps;
  unless ($total_mr_count > 0) {
    say "Well, that would have been a great branch, but I couldn't find anything";
    say "to merge. I guess I'll give up now; maybe next time!";
    exit 0;
  }

  for my $step ($self->config->steps) {
    my $header = "Step $i: " . $step->name;
    $i++;
    say $header;
    say '-' x length $header;

    unless ($step->merge_requests) {
      printf("Nothing to do! No merge requests labeled %s found on remote %s\n",
        $step->label,
        $step->remote->name,
      );
      next;
    }

    say "We're going to include the following merge requests:\n";

    for my $mr ($step->merge_requests) {
      say "* " . $mr->oneline_desc;
    }

    if (my $remote = $step->push_tag_to) {
      say "\nWe'd tag that and push it tag to the remote named " . $remote->name . '.';
    }

    say "";
  }

  say "From here, you can do several things:\n";
  say "1. Get more information";
  say "2. Continue with the build";
  say "3. Give up";
  print "\nWhich would you prefer? ";

  while (my $input = <STDIN>) {
    chomp($input);

    if (lc $input eq '2') {
      say "Great...here we go!\n";
      return;
    }

    if (lc $input eq '3') {
      say "Alright then...see you next time!";
      exit 1;
    }

    print "Sorry, I didn't understand that! Try again? ";
  }

  die "wait, how did you get here?";
}

1;
