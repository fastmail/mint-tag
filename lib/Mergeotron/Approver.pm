use v5.20;
package Mergeotron::Approver;
use Moo;
use experimental qw(postderef signatures);

use List::Util qw(sum0);
use Term::ANSIColor qw(color colored);
use Try::Tiny;
use Types::Standard qw(HashRef InstanceOf Maybe);

use Mergeotron::Logger '$Logger';
use Mergeotron::Util qw(run_git re_for_tag);

has config => (
  is => 'ro',
  required => 1,
  isa => InstanceOf['Mergeotron::Config'],
);

has last_build => (
  is => 'ro',
  isa => Maybe[HashRef],
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
    printf("The last tag I found for this config was %s.\n\n",
      colored($self->last_build->{meta}{tag}, 'bright_blue'),
    );
  }

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

  my $data = try {
    TOML::Parser->new->parse($body);
  } catch {
    my $e = $_;
    $Logger->log("error reading TOML from commit message; ignoring");
  };

  return unless $data;

  if ($data->{meta}{annotation_version} != $Mergeotron::ANNOTATION_VERSION) {
    $Logger->log([
      "ignoring previous build; built with annotation version %s, current is %s",
      $data->{meta}{annotation_version},
      $Mergeotron::ANNOTATION_VERSION,
    ]);
  }

  $data->{meta}{tag} = $tagname;

  # TODO: maybe, make this an object
  $self->_set_last_build($data);
}

1;
