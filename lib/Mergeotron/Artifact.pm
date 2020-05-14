use v5.20;
package Mergeotron::Artifact;
use Moo;
use experimental qw(postderef signatures);

use Types::Standard qw(InstanceOf Maybe Str);

has config => (
  is => 'ro',
  required => 1,
  isa => InstanceOf['Mergeotron::Config'],
);

has base => (
  is => 'ro',
  required => 1,
  isa => Str,
);

has tag_name => (
  is => 'ro',
  required => 1,
  isa => Str,
);

# used when building from a mergeotron object, not when generating from tag
# message
has this_step => (
  is => 'ro',
  isa => Maybe[InstanceOf['Mergeotron::BuildStep']],
  predicate => 'has_this_step',
);

has step_data => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my @steps;

    for my $step ($self->config->steps) {
      my $data = {
        name           => $step->name,
        remote         => $step->remote->clone_url,
        merge_requests => [],
      };

      for my $mr ($step->merge_requests) {
        push $data->{merge_requests}->@*, {
          number => $mr->number,
          sha    => $mr->sha,
        };
      }

      push @steps, $data;
      last if $self->has_this_step && $step eq $self->this_step;
    }

    return \@steps;
  },
);

# The TOML generation perl library kinda stinks, so I'ma construct it
# manually. It's fine. -- michael, 2020-05-13
sub as_toml ($self) {
  my $version = do {
     no warnings 'once';
     $Mergeotron::ANNOTATION_VERSION;
  };

  # This wants to be a template, BUT ALSO.
  my @lines = (
    '[meta]',
    sprintf('tag_name = "%s"', $self->tag_name),
    sprintf('annotation_version = %d', $version),
    sprintf('base = "%s"', $self->base),
    "",
  );

  for my $step ($self->step_data->@*) {
    push @lines, '[[build_steps]]';
    push @lines, sprintf('name = "%s"', $step->{name});
    push @lines, sprintf('remote = "%s"', $step->{remote});
    push @lines, 'merge_requests = [';

    for my $mr ($step->{merge_requests}->@*) {
      push @lines, sprintf('  { number="%s", sha="%s" },', $mr->{number}, $mr->{sha});
    }

    push @lines, ']';
    push @lines, '';
  }

  return join "\n", @lines;
}

1;
