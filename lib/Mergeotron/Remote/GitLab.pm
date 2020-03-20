use v5.20;
package Mergeotron::Remote::GitLab;
use Moo;
use experimental qw(postderef signatures);

with 'Mergeotron::Remote';

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

sub get_mrs_for_label ($self, $label) {
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

    push @mrs, Mergeotron::MergeRequest->new({
      remote     => $self,
      number     => $number,
      title      => $mr->{title},
      author     => $mr->{author}->{username},
      fetch_spec => $self->name,
      refname    => "merge-requests/$number/head",
      sha        => $mr->{sha},
    });
  }

  return @mrs;
}

sub obtain_clone_url ($self) {
  my $repo = $self->http_get($self->uri_for(''));
  return $repo->{ssh_url_to_repo};
}

1;
