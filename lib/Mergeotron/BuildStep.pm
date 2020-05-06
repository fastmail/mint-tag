use v5.20;
package Mergeotron::BuildStep;
use Moo;
use experimental qw(signatures postderef);

use Types::Standard qw(Str ConsumerOf Maybe ArrayRef InstanceOf);

use Mergeotron::Logger '$Logger';

has name => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has remote => (
  is => 'ro',
  isa => ConsumerOf["Mergeotron::Remote"],
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has label => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has tag_format => (
  is => 'ro',
  isa => Maybe[Str],
);

has _merge_requests => (
  is => 'ro',
  init_arg => undef,
  isa => ArrayRef[InstanceOf["Mergeotron::MergeRequest"]],
  writer => 'set_merge_requests'
);

sub merge_requests { $_[0]->_merge_requests->@* }

sub proxy_logger ($self) {
  return $Logger->proxy({proxy_prefix => $self->name . ': ' });
}

1;
