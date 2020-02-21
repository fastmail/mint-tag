use v5.20;
package Buildotron::Remote;
use Moo::Role;
use experimental qw(signatures postderef);

use JSON::MaybeXS qw(decode_json);
use Types::Standard qw(Str ArrayRef);

requires 'get_mrs';
requires 'ua';

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

# owner/name
has repo => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has labels => (
  is => 'ro',
  isa => ArrayRef[Str],
  default => sub { [] },
);

sub http_get ($self, $url) {
  my $res = $self->ua->get($url);

  unless ($res->is_success) {
    my $class = ref $self =~ s/.*:://;
    die "Something went wrong talking to $class\n" . $res->as_string;
  }

  my $data = decode_json($res->decoded_content);
  return $data;
}

1;
