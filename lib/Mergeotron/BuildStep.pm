use v5.20;
package Mergeotron::BuildStep;
use Moo;
use experimental qw(signatures postderef);

use Types::Standard qw(Bool Str ConsumerOf Maybe ArrayRef InstanceOf);

use Mergeotron::Logger '$Logger';
use Mergeotron::Util qw(run_git);

has name => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has remote => (
  is => 'ro',
  isa => ConsumerOf["Mergeotron::Remote"],
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has label => (
  is => 'ro',
  isa => Str,
  required => 1,
);

# If this is here, it's the name of a group/organization that we trust; if our
# label was added by someone not in this group, we'll reject it.
has trusted_org => (
  is => 'ro',
  isa => Maybe[Str],
);

has tag_prefix => (
  is => 'ro',
  isa => Maybe[Str],
);

has push_tag_to => (
  is => 'ro',
  isa => Maybe[ConsumerOf["Mergeotron::Remote"]],
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
  isa => ArrayRef[InstanceOf["Mergeotron::MergeRequest"]],
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
    run_git('fetch', $mr->as_fetch_args);
    $Logger->log([ "fetched %s!%s",  $mr->remote_name, $mr->number ]);

    my $base = run_git('merge-base', $merge_base, $mr->sha);
    $mr->set_merge_base($base);
  }
}

1;
