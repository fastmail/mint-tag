use v5.20;
package App::MintTag::MergeRequest;
# ABSTRACT: a tiny class to represent merge requests from different places

use Moo;
use experimental qw(postderef signatures);

use App::MintTag::Util qw(run_git compute_patch_id);

has remote => (
  is => 'ro',
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has [qw(
  author
  branch_name
  fetch_spec
  number
  ref_name
  force_push_url
  title
  web_url
)] => (
  is => 'ro',
  required => 1,
);

has sha => (
  is => 'ro',
  required => 1,
  writer => '_set_sha',
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

has has_been_rebased_locally => (
  is => 'rw',
  default => 0,
);

sub as_fetch_args ($self) {
  return ($self->fetch_spec, $self->ref_name);
}

sub oneline_desc ($self) {
  return sprintf("%d, %s (%s) - %s",
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

sub as_multiline_commit_message ($self, $target_branch) {
  return sprintf(
    "Merge branch '%s' into '%s'\n\nSee %s\n",
    $self->branch_name,
    $target_branch,
    $self->web_url,
  );
}

sub rebase ($self, $new_base) {
  run_git('rebase', $new_base, $self->sha);   # might die, and should!

  # we succeeded; we need to reset our sha, merge base, and patch id
  my $new_sha = run_git('rev-parse', 'HEAD');
  $self->_set_sha($new_sha);
  $self->set_merge_base($new_base);

  my $patch_id = compute_patch_id($new_base, $new_sha);
  $self->set_patch_id($patch_id);

  $self->has_been_rebased_locally(1);

  return 1;
}

1;
