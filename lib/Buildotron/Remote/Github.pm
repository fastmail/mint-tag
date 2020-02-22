use v5.20;
package Buildotron::Remote::Github;
use Moo;
use experimental qw(postderef signatures);

with 'Buildotron::Remote';

use LWP::UserAgent;
use URI;

use Buildotron::MergeRequest;

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

sub get_mrs_for_label ($self, $label) {
  # Github does not allow you to get pull requests by label directly, so we
  # need to make one to fetch everything with the label we want, and then a
  # bunch of others to get the PRs themselves. (This sure would be easier if
  # it were JMAP!)
  my $issues = $self->http_get($self->uri_for('/issues', {
    labels => $label,
    sort => 'created',
    direction => 'asc',
  }));

  my @pr_urls = map  {; $_->{pull_request}{url} }
                grep {; $_->{pull_request}      }
                @$issues;

  my @prs;

  for my $url (@pr_urls) {
    my $pr = $self->http_get($url);
    my $head = $pr->{head};

    push @prs, Buildotron::MergeRequest->new({
      remote     => $self,
      number     => $pr->{number},
      author     => $pr->{user}->{login},
      title      => $pr->{title},
      fetch_spec => $head->{repo}{git_url},
      refname    => $head->{ref},
      sha        => $head->{sha},
    });
  }

  return @prs;
}

1;
