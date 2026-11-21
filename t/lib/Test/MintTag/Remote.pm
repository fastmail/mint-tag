use v5.36;
package Test::MintTag::Remote;
# ABSTRACT: a mint-tag remote that talks to a Test::MintTag::Forge

use Moo;

use Carp ();

use App::MintTag::Logger '$Logger';
use App::MintTag::MergeRequest;

# This is what goes in the interface_class of a remote in a test config.
# Config files can only hold strings, so to find the forge, we look up the
# remote's api_url in %FORGE_FOR.  Whoever builds the forge has to put it
# there.
#
# The real remotes decide which merge requests have the right label and come
# from a trusted author by talking to the forge's API.  We don't talk to
# anything, so we have our own implementation of those rules.  That means the
# real implementations are not tested by anything that uses this class!
our %FORGE_FOR;

has forge => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  default => sub ($self) {
    $FORGE_FOR{ $self->api_url }
      // Carp::confess("no forge registered for " . $self->api_url);
  },
);

sub ua { Carp::confess("the test remote does not speak HTTP") }

sub _fetch_raw_repo_data ($self) { return {} }

sub obtain_https_clone_url ($self) { $self->forge->clone_url }
sub obtain_ssh_clone_url   ($self) { $self->forge->clone_url }

sub get_default_branch_name ($self) { $self->forge->default_branch }

sub get_mrs_for_label ($self, $label, $trusted_org_name = undef) {
  my %ok_usernames;

  if ($trusted_org_name) {
    %ok_usernames = map {; $_ => 1 } $self->forge->org_members($trusted_org_name);
  }

  my @mrs;

  for my $data ($self->forge->open_mrs_with_label($label)) {
    if ($trusted_org_name && ! $ok_usernames{ $data->{author} }) {
      $Logger->log([
        "ignoring MR %s!%s from untrusted user %s (not in org %s)",
        $self->name,
        $data->{number},
        $data->{author},
        $trusted_org_name,
      ]);

      next;
    }

    push @mrs, $self->_mr_from_data($data);
  }

  return @mrs;
}

sub get_mr ($self, $number) {
  return $self->_mr_from_data($self->forge->mr_data($number));
}

sub _mr_from_data ($self, $data) {
  return App::MintTag::MergeRequest->new({
    remote      => $self,
    number      => $data->{number},
    title       => $data->{title},
    author      => $data->{author},
    fetch_spec  => $self->name,
    ref_name    => "merge-requests/$data->{number}/head",
    sha         => $data->{sha},
    state       => $data->{state},
    web_url     => $data->{web_url},
    branch_name => $data->{branch},
    is_merged   => $data->{state} eq 'merged',
    force_push_url => $data->{source_url},
    should_delete_branch => $data->{delete_branch},
    fetch_affected_files_callback => sub ($mr) {
      return [ $mr->remote->forge->files_changed_by_mr($mr->number) ];
    },
  });
}

with 'App::MintTag::Remote';

1;
