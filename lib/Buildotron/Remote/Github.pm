use v5.20;
package Buildotron::Remote::Github;
use Moo;
use experimental qw(postderef signatures);

with 'Buildotron::Remote';

use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use Types::Standard qw(Str);
use URI;

# owner/reponame
has repo => (
  is => 'ro',
  isa => Str,
  required => 1,
);

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

sub http_get ($self, $url, $arg = {}) {
  my $res = $self->ua->get($url);

  unless ($res->is_success) {
    die "Something went wrong talking to Github:\n" . $res->as_string;
  }

  my $data = decode_json($res->decoded_content);
  return $data;
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

sub get_mrs ($self) {
  # Github does not allow you to get pull requests by label directly, so we
  # need to make one to fetch everything with the labels we want, and then a
  # bunch of others to get the PRs themselves. (This sure would be easier if
  # it were JMAP!)
  my $labels = join q{,}, $self->labels->@*;
  my $issues = $self->http_get($self->uri_for('/issues', { labels => $labels }));

  my @pr_urls = map  {; $_->{pull_request}{url} }
                grep {; $_->{pull_request}      }
                @$issues;

  my @prs;

  for my $url (@pr_urls) {
    my $pr = $self->http_get($url);
    my $head = $pr->{head};

    # maybe this should be an object instead.
    push @prs, {
      number  => $pr->{number},
      title   => $pr->{title},
      refname => $head->{ref},
      git_url => $head->{repo}{git_url},
    };
  }

  return \@prs;
}

1;
