use v5.20;
package Mergeotron::MergeRequest;
# ABSTRACT: a tiny class to represent merge requests from different places

use Moo;
use experimental qw(postderef signatures);

use Types::Standard qw(Int Str ConsumerOf);

has remote => (
  is => 'ro',
  isa => ConsumerOf["Mergeotron::Remote"],
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has number => (
  is => 'ro',
  isa => Int,
  required => 1,
);

has author => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has title => (
  is => 'ro',
  isa => Str,
  required => 1,
);

# Maybe: not required, and maybe we want something different, but will wait
# and see. All this is really here to do is so that eventually we can say
# git fetch $some_string that will fetch and set FETCH_HEAD

has fetch_spec => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has refname => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has sha => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has ident => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return sprintf('%s!%d', $self->remote_name, $self->number);
  },
);

sub as_fetch_args ($self) {
  return ($self->fetch_spec, $self->refname);
}

sub oneline_desc ($self) {
  return sprintf("%s!%d (%s) - %s",
    $self->remote_name,
    $self->number,
    $self->author,
    $self->title
  );
}

# Silly, but I've now typed this like 8 times, so.
sub as_commit_message ($self) {
  return "Merge " . $self->oneline_desc;
}

1;