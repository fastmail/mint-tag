use v5.36;
package Test::MintTag::Forge;
# ABSTRACT: a pretend code forge, backed by real git repositories

use Moo;

use Carp ();
use Test::MintTag::Repo;

# A forge is a place that hosts one project.  It has a "golden" repository,
# which is a real bare git repository on disk, and it has merge requests, which
# are mostly just a hash in memory.  Every merge request has a source branch,
# which lives either in the golden repository or in a fork of it.  Like GitLab,
# we also keep a ref for the head of every merge request in the golden repo,
# at refs/merge-requests/NUMBER/head.
#
# Nothing here talks to mint-tag.  That's the job of Test::MintTag::Remote,
# which presents a forge to mint-tag in the shape that it expects.

has name => (
  is => 'ro',
  required => 1,
);

# a Path::Tiny directory under which we'll make our repositories
has root => (
  is => 'ro',
  required => 1,
);

# If given, this is another Forge, and our golden repository will start as a
# copy of that one's, and will keep up with its default branch.  Without it,
# we'll start with our own copy of the standard upstream history.
has mirror_of => (
  is => 'ro',
);

# A hashref of (org name => [ usernames ])
has orgs => (
  is => 'ro',
  default => sub { {} },
);

# A coderef that returns a new, later epoch time every time it's called.  All
# the commits we make are dated by this, so that the shas come out the same on
# every run.
has tick => (
  is => 'ro',
  default => sub {
    my $epoch = 1_600_000_000;
    return sub { $epoch += 60 };
  },
);

has repo => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  default => sub ($self) {
    Test::MintTag::Repo->new({ path => $self->root->child($self->name . '.git') });
  },
);

has _mrs => (
  is => 'ro',
  default => sub { {} },
);

has _forks => (
  is => 'ro',
  default => sub { {} },
);

sub default_branch { 'master' }

# We give out file:// URLs, not plain paths, because git treats a clone of a
# plain path specially, and copies over every object in the repository, even
# the ones the clone has no business having yet.  With a URL, git behaves the
# way it would with a real remote.
sub clone_url ($self) { _url_for($self->repo) }

sub _url_for ($repo) { "file://" . $repo->path->stringify }

# This is the history every upstream forge starts with.  It's small, but it
# has a few files and a few commits, so that merge requests have something to
# conflict with and somewhere other than the tip to branch from.
my @UPSTREAM_HISTORY = (
  {
    message => "initial import\n",
    files   => {
      'README'         => "This is a pretend mail server.\n",
      'imap/append.c'  => "/* append */\nint append(void) {\n  return 0;\n}\n",
      'imap/mailbox.c' => "/* mailbox */\nint mailbox(void) {\n  return 0;\n}\n",
      'lib/util.c'     => "/* util */\nint util(void) {\n  return 0;\n}\n",
    },
  },
  {
    message => "mailbox: return one\n",
    files   => {
      'imap/mailbox.c' => "/* mailbox */\nint mailbox(void) {\n  return 1;\n}\n",
    },
  },
  {
    message => "util: return two\n",
    files   => {
      'lib/util.c'     => "/* util */\nint util(void) {\n  return 2;\n}\n",
    },
  },
);

sub BUILD ($self, $arg) {
  my $path = $self->repo->path;
  $path->parent->mkpath;

  if (my $source = $self->mirror_of) {
    Test::MintTag::Repo->new({ path => $path->parent })->git(
      qw(clone --quiet --bare), $source->clone_url, $path->stringify,
    );

    return;
  }

  $path->mkpath;
  $self->repo->git(qw(init --quiet --bare --initial-branch), $self->default_branch);

  $self->add_upstream_commit(%$_) for @UPSTREAM_HISTORY;

  return;
}

# Put a new commit on the default branch of the golden repository.  This takes
# the files and message arguments of Test::MintTag::Repo's commit method.
sub add_upstream_commit ($self, %arg) {
  Carp::confess("a mirror can't have upstream commits; add them to its source")
    if $self->mirror_of;

  my $branch = $self->default_branch;

  return $self->repo->commit(
    %arg,
    ref    => "refs/heads/$branch",
    parent => $self->repo->rev($branch),
    epoch  => $self->tick->(),
  );
}

# If we're a mirror, catch up with the default branch of the forge we mirror.
sub _sync_from_upstream ($self) {
  my $source = $self->mirror_of;
  return unless $source;

  $source->_sync_from_upstream;

  my $branch = $self->default_branch;
  $self->repo->git(
    qw(fetch --quiet), $source->clone_url, "+refs/heads/$branch:refs/heads/$branch",
  );
}

sub _fork_for ($self, $username) {
  return $self->_forks->{$username} //= do {
    my $path = $self->root->child($self->name . "-fork-$username.git");

    $self->repo->git(qw(clone --quiet --bare), $self->clone_url, $path->stringify);

    Test::MintTag::Repo->new({ path => $path });
  };
}

# Open a merge request.  The arguments:
#
#   number  - the number of the merge request; required
#   author  - the username of its author; required
#   branch  - the name of its source branch; required
#   title   - its title; we'll make one up if you don't
#   labels  - an arrayref of labels
#   fork    - if true, the source branch is in the author's fork of the
#             project; otherwise, it's in the golden repository
#   base    - what to branch from: any revision in the golden repository,
#             defaulting to the default branch
#   files   - a hashref of (path => content) for the merge request's one
#             commit; if you give none, it adds a file nothing else will touch
#   message - the commit message for that commit
#   delete_branch - if true, the author asked for the source branch to be
#             deleted after merge
sub add_mr ($self, %arg) {
  my $number = $arg{number} // Carp::confess("no number given");
  my $author = $arg{author} // Carp::confess("no author given");
  my $branch = $arg{branch} // Carp::confess("no branch given");

  Carp::confess("already have a merge request numbered $number")
    if $self->_mrs->{$number};

  $self->_sync_from_upstream;

  my $base = $self->repo->rev($arg{base} // $self->default_branch)
    // Carp::confess("can't find base $arg{base}");

  my $mr = $self->_mrs->{$number} = {
    number  => $number,
    author  => $author,
    branch  => $branch,
    title   => $arg{title} // "Do the work from $branch",
    labels  => [ ($arg{labels} // [])->@* ],
    source  => $arg{fork} ? $self->_fork_for($author) : $self->repo,
    state   => 'opened',
    delete_branch => $arg{delete_branch} ? 1 : 0,
  };

  $self->_commit_to_mr($mr, $base, {
    files   => $arg{files} // { "topic/$branch.txt" => "the work from $branch\n" },
    message => $arg{message} // "$mr->{title}\n",
  });

  return $number;
}

sub _mr ($self, $number) {
  return $self->_mrs->{$number}
    // Carp::confess("no merge request numbered $number on " . $self->name);
}

sub _commit_to_mr ($self, $mr, $parent, $commit) {
  my $source = $mr->{source};

  # A fork doesn't hear about new commits in the golden repository unless
  # somebody tells it, and it will need to have the parent commit.
  if ($source != $self->repo) {
    $source->git(qw(fetch --quiet), $self->clone_url, '+refs/heads/*:refs/upstream/*');
  }

  $source->commit(
    %$commit,
    ref    => "refs/heads/$mr->{branch}",
    parent => $parent,
    author => $mr->{author},
    epoch  => $self->tick->(),
  );

  $self->_notice_pushes_to($mr);
}

# This is the forge noticing that somebody has pushed to the source branch of
# a merge request, which means updating the ref we keep for its head.  If the
# source branch has been deleted, the merge request keeps its last known head.
sub _notice_pushes_to ($self, $mr) {
  my $branch_ref = "refs/heads/$mr->{branch}";
  my $head_ref   = "refs/merge-requests/$mr->{number}/head";

  my $sha = $mr->{source}->rev($branch_ref);
  return unless $sha;

  if ($mr->{source} == $self->repo) {
    $self->repo->git('update-ref', $head_ref, $sha);
  } else {
    $self->repo->git(
      qw(fetch --quiet), _url_for($mr->{source}), "+$branch_ref:$head_ref",
    );
  }

  return;
}

# Add a commit to the source branch of a merge request.  This takes the files
# and message arguments of Test::MintTag::Repo's commit method.  If you don't
# give any files, the commit adds a file that nothing else will touch.
sub update_mr ($self, $number, %arg) {
  my $mr = $self->_mr($number);
  $self->_notice_pushes_to($mr);

  my $head = $self->repo->rev("refs/merge-requests/$number/head");

  $arg{files} //= {
    sprintf("topic/%s-%d.txt", $mr->{branch}, $self->repo->git(qw(rev-list --count), $head))
      => "more work from $mr->{branch}\n",
  };

  $self->_commit_to_mr($mr, $head, \%arg);

  return;
}

sub close_mr ($self, $number) {
  $self->_mr($number)->{state} = 'closed';
  return;
}

sub set_labels ($self, $number, @labels) {
  $self->_mr($number)->{labels} = [ @labels ];
  return;
}

# Everything the forge knows about one merge request, as a hashref.  This is a
# snapshot, and getting it makes the forge catch up with reality, the way a
# real one does shortly after you push to it.  So: the sha is whatever the
# source branch now points to, and if that's been merged into the default
# branch, then the merge request is merged.
sub mr_data ($self, $number) {
  my $mr = $self->_mr($number);
  $self->_notice_pushes_to($mr);

  my $sha = $self->repo->rev("refs/merge-requests/$number/head");

  if ($mr->{state} eq 'opened' && $self->repo->is_ancestor($sha, $self->default_branch)) {
    $mr->{state} = 'merged';
  }

  return {
    %$mr,
    labels     => [ $mr->{labels}->@* ],
    sha        => $sha,
    source_url => _url_for($mr->{source}),
    web_url    => sprintf('https://%s.example.com/merge-requests/%s', $self->name, $number),
  };
}

# The data, as from mr_data, for every open merge request with the given
# label, in order of merge request number.
sub open_mrs_with_label ($self, $label) {
  return grep {; $_->{state} eq 'opened' && grep {; $_ eq $label } $_->{labels}->@* }
         map  {; $self->mr_data($_) }
         sort {; $a <=> $b } keys $self->_mrs->%*;
}

# The usernames in an org.  It's fatal to ask about an org we don't have.
sub org_members ($self, $org) {
  my $members = $self->orgs->{$org}
    // die "no org named $org on forge " . $self->name . "\n";

  return @$members;
}

# The paths of all the files a merge request changes.
sub files_changed_by_mr ($self, $number) {
  my $data = $self->mr_data($number);

  return split /\n/, $self->repo->git(
    qw(diff --name-only),
    join(q{...}, $self->default_branch, $data->{sha}),
  );
}

1;
