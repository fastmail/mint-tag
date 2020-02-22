use v5.20;
package Buildotron::Remote;
use Moo::Role;
use experimental qw(signatures postderef);

use JSON::MaybeXS qw(decode_json);
use Types::Standard qw(Str ArrayRef Maybe);

requires 'get_mrs_for_label';
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
  coerce => sub ($val) {
    if ($val =~ s/^ENV://) {
      return $ENV{$val};
    }

    return $val;
  },
);

# owner/name
has repo => (
  is => 'ro',
  isa => Str,
  required => 1,
);

sub http_get ($self, $url) {
  my $res = $self->ua->get($url);

  unless ($res->is_success) {
    my $class = (ref $self) =~ s/.*:://r;
    die "Something went wrong talking to $class\n" . $res->as_string;
  }

  my $data = decode_json($res->decoded_content);
  return $data;
}

1;
