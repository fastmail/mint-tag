use v5.36;
package Test::MintTag::Repo;
# ABSTRACT: a git repository on disk, and some ways to poke at it

use Moo;

use Carp ();
use Encode ();
use IPC::Run3 qw(run3);

# The directory holding the repository, as a Path::Tiny.  It might be bare.
has path => (
  is => 'ro',
  required => 1,
);

# Run git in this repository and return its (chomped) output.  The last
# argument can be a hashref of options:
#
#   stdin     - a string to feed to git on standard input
#   allow_failure - if true, return undef on failure instead of dying
sub git ($self, @cmd) {
  my $arg = ref $cmd[-1] eq 'HASH' ? pop @cmd : {};

  my $stdin = $arg->{stdin};
  run3(
    [ 'git', '-C', $self->path->stringify, @cmd ],
    (defined $stdin ? \$stdin : \undef),
    \my $out,
    \my $err,
  );

  if ($?) {
    return undef if $arg->{allow_failure};
    Carp::croak("git @cmd failed in " . $self->path . ": $err");
  }

  chomp $out;
  return $out;
}

# Run git for its exit status alone; true if it exited zero.
sub git_ok ($self, @cmd) {
  return defined $self->git(@cmd, { allow_failure => 1 });
}

# The full sha for a revision, or undef if there's no such thing.
sub rev ($self, $rev) {
  return $self->git(qw(rev-parse --verify --quiet), "$rev^{commit}", {
    allow_failure => 1,
  });
}

sub parents ($self, $rev) {
  my (undef, @parents) = split /\s+/, $self->git(qw(rev-list --parents -n 1), $rev);
  return @parents;
}

sub is_ancestor ($self, $maybe_ancestor, $rev) {
  return $self->git_ok(qw(merge-base --is-ancestor), $maybe_ancestor, $rev);
}

# The whole commit message of a commit, or the annotation of a tag.
sub message ($self, $rev) {
  my $type = $self->git(qw(cat-file -t), $rev);

  my $raw = $type eq 'tag'
    ? $self->git(qw(tag -l --format=%(contents)), $rev)
    : $self->git(qw(show --no-patch --format=%B), $rev);

  return Encode::decode('UTF-8', $raw);
}

# The content of a file at a revision, or undef if it isn't there.
sub file ($self, $rev, $path) {
  my $content = $self->git('show', "$rev:$path", { allow_failure => 1 });
  return defined $content ? "$content\n" : undef;
}

sub tags ($self) {
  return split /\n/, $self->git(qw(tag -l));
}

# A hash of (branch name => sha) for every branch.
sub branches ($self) {
  return map {; split /\t/ } split /\n/, $self->git(
    'for-each-ref',
    "--format=%(refname:short)\t%(objectname)",
    'refs/heads',
  );
}

# Make one commit with git fast-import, which means we don't need a work tree,
# and so this works just fine on bare repositories.  The arguments:
#
#   ref     - the full name of the ref to put the commit on; required
#   parent  - the sha of the parent commit; without it, you get a root commit
#   files   - a hashref of (path => content); undef content deletes the file
#   message - the commit message
#   author  - a username, used for both author and committer
#   epoch   - when the commit was made, in epoch seconds
#
# The commit's sha is returned.
sub commit ($self, %arg) {
  my $ref    = $arg{ref}    // Carp::confess("no ref given");
  my $epoch  = $arg{epoch}  // Carp::confess("no epoch given");
  my $author = $arg{author} // 'upstream';
  my $files  = $arg{files}  // {};

  my $ident = "$author <$author\@example.com> $epoch +0000";

  my $stream = join q{},
    "commit $ref\n",
    "author $ident\n",
    "committer $ident\n",
    _data($arg{message} // "a commit\n"),
    ($arg{parent} ? "from $arg{parent}\n" : ()),
    (map {; defined $files->{$_}
              ? ("M 100644 inline $_\n", _data($files->{$_}))
              : "D $_\n" } sort keys %$files),
    "\n";

  # --force, because sometimes we replace a branch's history on purpose, like
  # when pretending that somebody has rebased their merge request.
  $self->git(qw(fast-import --quiet --force), { stdin => $stream });

  return $self->rev($ref);
}

sub _data ($str) {
  my $bytes = Encode::encode('UTF-8', $str);
  return sprintf "data %d\n%s\n", length $bytes, $bytes;
}

1;
