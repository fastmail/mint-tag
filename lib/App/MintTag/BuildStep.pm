use v5.20;
package App::MintTag::BuildStep;
# ABSTRACT: defines a step of the tag-building process

use Moo;
use experimental qw(signatures postderef);
use Try::Tiny;

use App::MintTag::Logger '$Logger';
use App::MintTag::Util qw(run_git compute_patch_id);

has name => (
  is => 'ro',
  required => 1,
);

has remote => (
  is => 'ro',
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has label => (
  is => 'ro',
  required => 1,
);

# If this is here, it's the name of a group/organization that we trust; if our
# label was added by someone not in this group, we'll reject it.
has trusted_org => (
  is => 'ro',
);

has tag_prefix => (
  is => 'ro',
);

has push_tag_to => (
  is => 'ro',
);

# whether we should rebase before merging
has rebase => (
  is => 'ro',
  default => 0,
);

sub BUILD ($self, $arg) {
  if ($self->push_tag_to && ! $self->tag_prefix) {
    my $name = $self->name;
    die "Remote $name doesn't make sense: you defined a tag push target but no tag prefix!\n";
  }
}

has _merge_requests => (
  is => 'ro',
  init_arg => undef,
  writer => 'set_merge_requests'
);

sub merge_requests { $_[0]->_merge_requests->@* }

sub proxy_logger ($self) {
  return $Logger->proxy({proxy_prefix => $self->name . ': ' });
}

sub fetch_mrs ($self, $merge_base) {
  $Logger->log([ "fetching MRs from remote %s with label %s",
    $self->remote->name,
    $self->label,
  ]);

  my @mrs = $self->remote->get_mrs_for_label($self->label, $self->trusted_org);
  $self->set_merge_requests(\@mrs);

  for my $mr ($self->merge_requests) {
    # If we have the sha, we don't need to fetch
    my $sha_exists = try { run_git('cat-file', '-e', $mr->sha); 1 };

    if ($sha_exists) {
      $Logger->log([
        "already have %s!%s (%s) locally, will not fetch",
        $mr->remote_name,
        $mr->number,
        substr($mr->sha, 0, 8),
      ]);
    } else {
      run_git('fetch', $mr->as_fetch_args);
      $Logger->log([ "fetched %s!%s",  $mr->remote_name, $mr->number ]);
    }

    my $base = run_git('merge-base', $merge_base, $mr->sha);
    $mr->set_merge_base($base);

    my $patch_id = compute_patch_id($base, $mr->sha);
    $mr->set_patch_id($patch_id);
  }
}

1;
