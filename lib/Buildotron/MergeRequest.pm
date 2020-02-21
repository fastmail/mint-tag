use v5.20;
package Buildotron::MergeRequest;
# ABSTRACT: a tiny class to represent merge requests from different places

use Moo;
use experimental qw(postderef signatures);

use Types::Standard qw(Int Str ConsumerOf);

has remote => (
  is => 'ro',
  isa => ConsumerOf["Buildotron::Remote"],
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

1;
