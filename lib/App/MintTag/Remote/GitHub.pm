use v5.20;
package App::MintTag::Remote::GitHub;
# ABSTRACT: a remote implementation for GitHub

use Moo;
use experimental qw(postderef signatures);

with 'App::MintTag::Remote';

use LWP::UserAgent;
use Try::Tiny;
use URI;

use App::MintTag::Logger '$Logger';
use App::MintTag::MergeRequest;

sub ua;
has ua => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $token = $self->api_key;

    my $ua = LWP::UserAgent->new;
    $ua->default_header(Authorization => "token $token");
    $ua->default_header(Accept => "application/vnd.github.v3+json");

    return $ua;
  },
);

sub _fetch_raw_repo_data ($self) {
  my $repo = $self->http_get($self->uri_for(''));
  return $repo;
}

sub uri_for ($self, $part, $query = {}) {
  my $uri = URI->new(sprintf(
    "%s/repos/%s%s",
    $self->api_url,
    $self->repo,
    $part,
  ));

  $uri->query_form($query);
  return $uri;
}

sub get_mrs_for_label ($self, $label, $trusted_org_name = undef) {
  my $should_filter = !! $trusted_org_name;
  my %ok_usernames;

  if ($trusted_org_name) {
    %ok_usernames = map {; $_ => 1 } $self->usernames_for_org($trusted_org_name);
  }

  # GitHub does not allow you to get pull requests by label directly, so here
  # we grab *all* the open PRs and filter the label client-side, to reduce the
  # number of HTTP requests.  (This sure would be easier if it were JMAP!)
  my @prs;

  my $url = $self->uri_for('/pulls', {
    sort => 'created',
    direction => 'asc',
    state => 'open',
    per_page => 100,
    page => 1,
  });

  while (1) {
    my ($prs, $http_res) = $self->http_get($url);

    PR: for my $pr (@$prs) {
      my $head = $pr->{head};
      my $number = $pr->{number};
      my $username = $pr->{user}{login};

      my $labels = $pr->{labels} // [];
      my $is_relevant = grep {; $_->{name} eq $label} @$labels;

      next PR unless $is_relevant;

      if ($should_filter && ! $ok_usernames{$username}) {
        $Logger->log([
          "ignoring MR %s!%s from untrusted user %s (not in org %s)",
          $self->name,
          $number,
          $username,
          $trusted_org_name,
        ]);

        next PR;
      }

      push @prs, $self->_mr_from_raw($pr);
    }

    # Now, examine the link header to see if there's more to fetch.
    my $links = $self->extract_link_header($http_res);

    last unless defined $links->{next};
    $url = $links->{next};
  }

  return @prs;
}

sub get_mr ($self, $number) {
  my $pr = $self->http_get($self->uri_for("/pulls/$number"));
  return $self->_mr_from_raw($pr);
}

sub _mr_from_raw ($self, $raw) {
  my $number = $raw->{number};

  return App::MintTag::MergeRequest->new({
    remote      => $self,
    number      => $number,
    author      => $raw->{user}->{login},
    title       => $raw->{title},
    fetch_spec  => $self->name,
    ref_name    => "pull/$number/head",
    sha         => $raw->{head}->{sha},
    state       => $raw->{state},
    web_url     => $raw->{html_url},
    is_merged   => !! $raw->{merge_commit_sha},
    branch_name => $raw->{head}->{ref},
    force_push_url => $raw->{head}->{repo}->{clone_url},
    should_delete_branch => 0,  # github is sensible about this, set it there
    fetch_affected_files_callback => sub ($mr) {
      my $remote = $mr->remote;
      my $uri = $remote->uri_for("/pulls/" . $mr->number . "/files");
      my $res = $mr->remote->http_get($uri);
      return [ map {; $_->{filename} } @$res ];
    },
  });
}

sub obtain_https_clone_url ($self) {
  my $url = URI->new($self->_raw_repo_data->{clone_url});
  $url->userinfo($self->api_key);
  return $url;
}

sub obtain_ssh_clone_url ($self) {
  return $self->_raw_repo_data->{ssh_url};
}

sub get_default_branch_name ($self) {
  return $self->_raw_repo_data->{default_branch};
}

sub usernames_for_org ($self, $name) {
  $self->assert_org_membership($name);

  my $members = $self->http_get(sprintf("%s/orgs/%s/members",
    $self->api_url,
    $name,
  ));

  unless (@$members) {
    die "Hmm...we didn't find any members for the trusted org named $name!\n";
  }

  return map {; $_->{login} } @$members;
}

sub assert_org_membership ($self, $name) {
  return if $self->is_member_of_org($name);

  my $res = try {
    $self->http_get(sprintf("%s/user/memberships/orgs/%s",
      $self->api_url,
      $name,
    ));
  } catch {
    die "Error getting organization members from Github; are you a member of org '$name'?\n";
  };

  die "You don't seem to be a member of org '$name'; giving up."
    unless $res->{role} =~ /^(member|admin)$/;

  $self->note_org_membership($name);
}

1;
