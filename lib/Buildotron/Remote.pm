use v5.20;
package Buildotron::Remote;
use Moo::Role;
use Types::Standard qw(Str ArrayRef);

requires 'get_mrs';

has name => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has api_url => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has api_key => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has url => (
  is => 'ro',
  # maybe required, but not sure yet.
);

has labels => (
  is => 'ro',
  isa => ArrayRef[Str],
  default => sub { [] },
);

1;
