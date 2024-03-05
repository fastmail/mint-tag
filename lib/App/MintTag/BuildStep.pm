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

has cleanup_tag_days => (
  is => 'ro',
  default => 0
);

# Hashref: {
#   remote => $remote,
#   force => $bool
#   branch => 'branchname' OR use_matching_branch => 1,
# }
has push_spec => (
  is => 'ro',
  predicate => 'has_push_spec',
);

# whether we should rebase before merging
has rebase => (
  is => 'ro',
  default => 0,
);

has use_semilinear_merge => (
  is => 'ro',
  default => 0,
);

has force_push_rebased_branches => (
  is => 'ro',
  default => 0,
);

has allow_source_branch_deletion => (
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
  default => sub { [] },
  writer => 'set_merge_requests',
);

sub merge_requests { $_[0]->_merge_requests->@* }

sub proxy_logger ($self) {
  return $Logger->proxy({proxy_prefix => $self->name . ': ' });
}

sub fetch_mrs ($self, $merge_base, $extra_mrs = []) {
  my @mrs = $self->remote->get_mrs_for_label($self->label, $self->trusted_org);

  for my $mr_num (@$extra_mrs) {
    $Logger->log([ "fetching extra MR: #%s, from remote %s",
      $mr_num,
      $self->remote->name,
    ]);

    push @mrs, $self->remote->get_mr($mr_num)
  }

  $self->set_merge_requests(\@mrs);

  for my $mr ($self->merge_requests) {
    # If we have the sha, we don't need to fetch
    my $sha_exists = try {
      run_git('cat-file', '-e', $mr->sha, { suppress_log_error => 1 });
      1;
    };

    if ($sha_exists) {
      $Logger->log([
        "already have %s!%s (%s) locally, will not fetch",
        $mr->remote_name,
        $mr->number,
        substr($mr->sha, 0, 8),
      ]);
    } else {
      run_git('fetch', $mr->as_fetch_args);
      $Logger->log([ "fetched %s!%s (%s)",  $mr->remote_name, $mr->number, $mr->short_sha ]);
    }

    my $base = run_git('merge-base', $merge_base, $mr->sha);
    $mr->set_merge_base($base);

    my $patch_id = compute_patch_id($base, $mr->sha);
    $mr->set_patch_id($patch_id);
  }
}

1;
