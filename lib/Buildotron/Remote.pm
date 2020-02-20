use v5.20;
package Buildotron::Remote;
use Moo::Role;

requires 'get_mrs';

has url => (
  is => 'ro',
  required => 1,
);

has labels => (
  is => 'ro',
  default => sub { [] },
);

1;
