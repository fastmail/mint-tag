use v5.20;
package App::MintTag::MergeRequest;
# ABSTRACT: a tiny class to represent merge requests from different places

use Moo;
use experimental qw(postderef signatures);

has remote => (
  is => 'ro',
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has number => (
  is => 'ro',
  required => 1,
);

has author => (
  is => 'ro',
  required => 1,
);

has title => (
  is => 'ro',
  required => 1,
);

# Maybe: not required, and maybe we want something different, but will wait
# and see. All this is really here to do is so that eventually we can say
# git fetch $some_string that will fetch and set FETCH_HEAD

has fetch_spec => (
  is => 'ro',
  required => 1,
);

has refname => (
  is => 'ro',
  required => 1,
);

has sha => (
  is => 'ro',
  required => 1,
);

has short_sha => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return substr $self->sha, 0, 8;
  },
);

has ident => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return sprintf('%s!%d', $self->remote_name, $self->number);
  },
);

has merge_base => (
  is => 'ro',
  writer => 'set_merge_base',
);

has patch_id => (
  is => 'ro',
  writer => 'set_patch_id',
);

has state => (
  is => 'ro',
);

sub as_fetch_args ($self) {
  return ($self->fetch_spec, $self->refname);
}

sub oneline_desc ($self) {
  return sprintf("!%d, %s (%s) - %s",
    $self->number,
    $self->short_sha,
    $self->author,
    $self->title
  );
}

# Silly, but I've now typed this like 8 times, so.
sub as_commit_message ($self) {
  return "Merge " . $self->oneline_desc;
}

1;
