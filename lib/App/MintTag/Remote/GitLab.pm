use v5.20;
package App::MintTag::Remote::GitLab;
use Moo;
use experimental qw(postderef signatures);

with 'App::MintTag::Remote';

use List::Util qw(uniq);
use LWP::UserAgent;
use URI;
use URI::Escape qw(uri_escape);

use App::MintTag::Logger '$Logger';

sub ua;
has ua => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $ua = LWP::UserAgent->new;
    $ua->default_header('Private-Token' => $self->api_key);
    return $ua;
  },
);

sub uri_for ($self, $part, $query = {}) {
  my $uri = URI->new(sprintf(
    "%s/projects/%s%s",
    $self->api_url,
    uri_escape($self->repo),
    $part,
  ));

  $uri->query_form($query);

  return $uri;
}

sub get_mrs_for_label ($self, $label, $trusted_org_name) {
  my $should_filter = !! $trusted_org_name;
  my %ok_usernames;

  if ($trusted_org_name) {
    %ok_usernames = map {; $_ => 1 } $self->usernames_for_org($trusted_org_name);
  }

  my $mrs = $self->http_get($self->uri_for('/merge_requests', {
    labels => $label,
    state => 'opened',
    per_page => 50,
  }));

  return [] unless @$mrs;

  my @sorted = sort { $a->{iid} <=> $b->{iid} } @$mrs;
  my @mrs;

  for my $mr (@sorted) {
    my $number = $mr->{iid};
    my $username = $mr->{author}{username};

    if ($should_filter && ! $ok_usernames{$username}) {
      $Logger->log([
        "ignoring MR %s!%s from untrusted user %s (not in org %s)",
        $self->name,
        $number,
        $username,
        $trusted_org_name,
      ]);

      next;
    }

    push @mrs, $self->_mr_from_raw($mr);
  }

  return @mrs;
}

sub get_mr ($self, $number) {
  my $mr = $self->http_get($self->uri_for("/merge_requests/$number"));
  return $self->_mr_from_raw($mr);
}

sub _mr_from_raw ($self, $raw) {
  my $number = $raw->{iid};

  return App::MintTag::MergeRequest->new({
    remote     => $self,
    number     => $number,
    title      => $raw->{title},
    author     => $raw->{author}->{username},
    fetch_spec => $self->name,
    refname    => "merge-requests/$number/head",
    sha        => $raw->{sha},
    state      => $raw->{state},
  });
}

sub obtain_clone_url ($self) {
  my $repo = $self->http_get($self->uri_for(''));
  return $repo->{ssh_url_to_repo};
}

sub usernames_for_org ($self, $name) {
  my $members = $self->http_get(sprintf("%s/groups/%s/members?per_page=100",
    $self->api_url,
    $name,
  ));

  unless (@$members) {
    die "Hmm...we didn't find any members for the trusted org named $name!\n";
  }

  return map  {; $_->{username} }
         grep {; $_->{state} eq 'active' }
         @$members;
}

1;
