use v5.20;
package App::MintTag::Remote::GitLab;
# ABSTRACT: a remote implementation for GitLab

use Moo;
use experimental qw(postderef signatures);

with 'App::MintTag::Remote';

use List::Util qw(uniq);
use LWP::UserAgent;
use Try::Tiny;
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

has my_user_id => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $me = $self->http_get(sprintf("%s/user", $self->api_url));
    return $me->{id};
  },
);

sub _fetch_raw_repo_data ($self) {
  my $repo = $self->http_get($self->uri_for(''));
  return $repo;
}

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

  # TODO: import pagination logic from Github. -- michael, 2020-05-19

  return unless @$mrs;

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

  # This is so jank, but I want to save an HTTP request
  my $reference = $raw->{references}{full};   # michael/mint-tag!42
  my $ssh_url = $self->obtain_clone_url;      # git@gitlab.com:fastmail/mint-tag.git
  my ($ssh_base)  = split /:/, $ssh_url;
  my ($push_spec) = split /!/, $reference;
  my $force_push_url = "$ssh_base:$push_spec.git";

  return App::MintTag::MergeRequest->new({
    remote      => $self,
    number      => $number,
    title       => $raw->{title},
    author      => $raw->{author}->{username},
    fetch_spec  => $self->name,
    ref_name    => "merge-requests/$number/head",
    sha         => $raw->{sha},
    state       => $raw->{state},
    web_url     => $raw->{web_url},
    branch_name => $raw->{source_branch},
    force_push_url => $force_push_url,
  });
}

sub obtain_clone_url ($self) {
  return $self->_raw_repo_data->{ssh_url_to_repo};
}

sub get_default_branch_name ($self) {
  return $self->_raw_repo_data->{default_branch};
}

sub usernames_for_org ($self, $name) {
  $self->assert_org_membership($name);

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

sub assert_org_membership ($self, $name) {
  return if $self->is_member_of_org($name);

  # Grab our auth info, then check if we're in the trusted group.
  my $me_id = $self->my_user_id;

  my $member = try {
    $self->http_get(sprintf("%s/groups/%s/members/all/%s",
      $self->api_url,
      uri_escape($name),
      $me_id,
    ));
  } catch {
    die "Error getting organization members from GitLab; are you a member of org '$name'?\n";
  };

  die "You don't seem to be a member of org '$name'; giving up."
    unless $member->{access_level} >= 10;  # 10 == "guest"

  $self->note_org_membership($name);
}

1;
