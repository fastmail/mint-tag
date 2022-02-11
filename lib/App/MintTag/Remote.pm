use v5.20;
package App::MintTag::Remote;
# ABSTRACT: a role for HTTP Git APIs to consume

use Moo::Role;
use experimental qw(signatures postderef);

use JSON::MaybeXS qw(decode_json is_bool);

use App::MintTag::Logger '$Logger';

requires 'obtain_clone_url';    # get_clone_url was confusing...
requires 'get_mrs_for_label';
requires 'get_mr';
requires 'ua';
requires 'get_default_branch_name';
requires '_fetch_raw_repo_data';

has name => (
  is => 'ro',
  required => 1,
);

has api_url => (
  is => 'ro',
  required => 1,
);

has api_key => (
  is => 'ro',
  required => 1,
  coerce => sub ($val) {
    if ($val =~ s/^ENV://) {
      my $got = $ENV{$val};
      return $got if $got;

      die "I was looking for an environment variable $val, but didn't find one!\n";
    }

    return $val;
  },
);

# owner/name
has repo => (
  is => 'ro',
  required => 1,
);

has clone_url => (
  is => 'ro',
  lazy => 1,
  builder => 'obtain_clone_url',
);

has _org_memberships => (
  is => 'ro',
  lazy => 1,
  default => sub { {} },
);

has _raw_repo_data => (
  is => 'ro',
  lazy => 1,
  builder => '_fetch_raw_repo_data',
);

sub is_member_of_org    ($self, $name) { $self->_org_memberships->{$name}     }
sub note_org_membership ($self, $name) { $self->_org_memberships->{$name} = 1 }

sub http_get ($self, $url) {
  my $res = $self->ua->get($url);

  unless ($res->is_success) {
    my $class = (ref $self) =~ s/.*:://r;
    die "Something went wrong talking to $class\n" . $res->as_string;
  }

  my $data = decode_json($res->decoded_content);
  return wantarray ? ($data, $res) : $data;
}

# This parser sucks, but it's Good Enough for GitHub/GitLab, I think. (For the
# full thing, see RFC 5988).  This return a hashref like
# {
#   next => URI,
#   prev => URI,
#   first => URI,
#   ...
# }
sub extract_link_header ($self, $http_res) {
  my %links;

  if (my $link = $http_res->header('Link')) {
    # each link separated by commas, so split on those (naively)
    for my $hunk (split /,\s*/, $link) {
      # value/params separated by semicolons
      my ($uri, @params) = split /\s*;\s*/, $hunk;

      # we only care about rel=
      my ($rel) = map  {; /^rel="(.*?)"$/ }
                  grep {; /^rel=/ }
                  @params;

      # kill whitespace and brackets
      $uri =~ s/^\s*<|>\s*$//g;

      $links{$rel} = $uri;
    }
  }

  return \%links;
}

around get_mrs_for_label => sub ($orig, $self, $label, $trusted_org) {
  # explicit false means "do not use label, require named MRs"
  if (! $label && is_bool($label)) {
    $Logger->log([
      "not fetching MRs for remote %s, no label provided",
      $self->name,
    ]);

    return;
  }

  $Logger->log([ "fetching MRs from remote %s with label %s",
    $self->name,
    $label,
  ]);

  return $self->$orig($label, $trusted_org);
};

1;
