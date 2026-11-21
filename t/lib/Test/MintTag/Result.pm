use v5.36;
package Test::MintTag::Result;
# ABSTRACT: what happened when we ran mint-tag in a Test::MintTag::World

use Moo;

use Carp ();

has world => (
  is => 'ro',
  required => 1,
);

# The App::MintTag object that did the work.  If the config was so bad that
# we couldn't make one, this is undef.
has app => (
  is => 'ro',
);

# The exception that mint-tag threw, if it threw one.
has error => (
  is => 'ro',
);

# an arrayref of every message logged during the run
has logs => (
  is => 'ro',
  required => 1,
);

# an arrayref of the names of the tags that this run made: the ones in the
# local repository now that weren't there, or on any forge, before the run
has new_tags => (
  is => 'ro',
  required => 1,
);

# The sha of the commit that was checked out in the local repository when the
# run ended, which is what mint-tag built.  We record this when the run ends,
# because the next run is going to check out something else.
has head => (
  is => 'ro',
);

# The one tag made by this run, or undef if there wasn't one.  If there were
# more than one, something is up, and we'll die.
sub tag ($self) {
  my @tags = $self->new_tags->@*;
  Carp::confess("more than one new tag: @tags") if @tags > 1;
  return $tags[0];
}

# Every merge request that mint-tag picked up, as App::MintTag::MergeRequest
# objects, in the order that mint-tag would've merged them.
sub mrs ($self) {
  return unless $self->app;
  return map {; $_->merge_requests } $self->app->config->steps;
}

sub local_repo ($self) { $self->world->local_repo }

# The merge request object, as mint-tag left it, for an ident like "github!12".
sub mr ($self, $ident) {
  my ($mr) = grep {; $_->ident eq $ident } $self->mrs;
  return $mr // Carp::confess("no merge request $ident in this build");
}

# Given a name for a commit, return its sha.  The names we know:
#
#   head      - the commit that mint-tag built, which was checked out when
#               the run ended; this is not always the tip of the target
#               branch, because mint-tag sometimes works on a detached HEAD
#   base      - the commit that the build started from
#   REMOTE!N  - the head of the merge request with that ident, as merged,
#               meaning that if mint-tag rebased it, it's the rebased head
#
# Anything else is taken as a revision in the local repository.  That does not
# include "HEAD" in lowercase, even if your filesystem thinks otherwise.
sub rev_for ($self, $name) {
  # Any of our names can have a suffix like ^2 or ~3, as git would allow.
  my ($base, $suffix) = $name =~ /\A([^~^]+)([~^].*)?\z/;

  my $rev = $base eq 'head' ? $self->head
          : $base eq 'base' ? $self->app->merge_base
          : $base =~ /!/    ? $self->mr($base)->sha
          :                   $base;

  return $self->local_repo->rev($rev . ($suffix // ''))
    // Carp::confess("can't resolve $name in the local repository");
}

# Check the shape of the history leading to a commit.  A shape is one of:
#
#   * a name, as understood by rev_for, meaning "this commit"
#   * an arrayref of shapes, meaning "a commit with exactly these parents, in
#     this order"
#   * a hashref of { name => arrayref }, meaning "this commit, and it has
#     exactly these parents, in this order"
#
# So, this:
#
#   [ [ 'base', 'github!1' ], { 'gitlab!2' => [ 'base' ] } ]
#
# ...is a merge of gitlab!2 into a merge of github!1 into the base commit, and
# the head of gitlab!2 is a direct child of the base commit.
#
# This returns a list of complaints, which is empty if the shape fits.
sub shape_problems ($self, $rev, $shape, $where = 'head') {
  my $repo = $self->local_repo;
  my $sha  = $repo->rev($rev);

  if (ref $shape eq 'HASH') {
    my ($name, $parents) = %$shape;

    return (
      $self->shape_problems($sha, $name, $where),
      $self->shape_problems($sha, $parents, $where),
    );
  }

  unless (ref $shape) {
    my $want = $self->rev_for($shape);
    return if $sha eq $want;
    return sprintf "%s: wanted %s (%s), but found %s",
      $where, $shape, substr($want, 0, 8), substr($sha, 0, 8);
  }

  my @parents = $repo->parents($sha);

  unless (@parents == @$shape) {
    return sprintf "%s: wanted a commit with %d parents, but %s has %d",
      $where, 0+@$shape, substr($sha, 0, 8), 0+@parents;
  }

  return map {; $self->shape_problems($parents[$_], $shape->[$_], "$where^" . ($_ + 1)) }
         keys @parents;
}

1;
