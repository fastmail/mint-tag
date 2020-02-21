use v5.20;
package Buildotron::Remote::GitLab;
use Moo;
use experimental qw(postderef signatures);

with 'Buildotron::Remote';

use List::Util qw(uniq);
use LWP::UserAgent;
use URI;
use URI::Escape qw(uri_escape);

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

sub get_mrs ($self) {
  my $labels = join q{,}, $self->labels->@*;
  my $mrs = $self->http_get($self->uri_for('/merge_requests', {
    labels => $labels,
    state => 'opened',
    per_page => 50,
  }));

  return [] unless @$mrs;

  # For every MR, we want to grab its git url, which means we need to fetch
  # the projects
  my %git_urls;

  my @project_ids = uniq map {; $_->{source_project_id} } @$mrs;

  for my $id (@project_ids) {
    my $url = sprintf("%s/projects/%d", $self->api_url, $id);
    my $project = $self->http_get($url);
    $git_urls{$id} = $project->{ssh_url_to_repo};
  }

  my @sorted = sort { $a->{iid} <=> $b->{iid} } @$mrs;
  my @mrs;

  for my $mr (@sorted) {
    push @mrs, Buildotron::MergeRequest->new({
      remote     => $self,
      number     => $mr->{iid},
      title      => $mr->{title},
      author     => $mr->{author}->{username},
      fetch_spec => $git_urls{ $mr->{source_project_id} },
      refname    => $mr->{source_branch},
      sha        => $mr->{sha},
    });
  }

  return @mrs;
}

1;
