use v5.20;
use warnings;
package Buildotron::App::Command::build;

use Buildotron::App -command;

use Getopt::Long::Descriptive;
use IPC::System::Simple qw(runx);
use List::MoreUtils qw(uniq);
use LWP::UserAgent;
use JSON qw(decode_json);
use Data::Dumper::Concise;

# XXX All of this stuff should go away into config
my $api_token = $ENV{GITHUB_API_TOKEN};
unless ($api_token) {
  die "E: no GITHUB_API_TOKEN! Configure one in Github Developer Settings\n";
}

sub usage_desc { "%c build %o" }

sub opt_spec {
  return (
    [ 'config|c=s', 'config file to use', { required => 1 } ],
    [ 'target=s',   'branch name we are building'  ],
    [ 'include=s@', 'include MRs with these labels'  ],
    [ 'origin=s',   'the remote from which to fetch'  ],
    [ 'base=s',     'branch to use as the base' ],
  );
}

sub validate_args {
  my ($self, $opt, $args) = @_;
}

sub execute {
  my ($self, $opt, $args) = @_;

  require Buildotron;
  my $bob = Buildotron->from_config_file($opt->config);

  $bob->build();

  return;

  my @labels = @{ $opt->include // [] };
  # die "no --include given\n" unless @labels;

  for my $remote ($self->config->remote_names) {
    $self->process_remote_mrs($remote);
  }

  warn "still need an implementation!";
  return;

  my @mrs = $self->get_mrs(@labels);

  unless (@mrs) {
    say "W: no branches labeled @labels";
    return;
  }

  $self->do_merge($opt, \@mrs);
  return;
}

sub process_remote_mrs {
  my ($self, $remote_name) = @_;

}

sub get_mrs {
  my ($self, @labels) = @_;

  my $project_id = 2;

  my $labels = join(",", @labels);

  my $mrs = gitlab_get("/projects/$project_id/merge_requests?state=opened&labels=$labels&per_page=50");

  $mrs = [
    sort { $a->{iid} <=> $b->{iid} } grep { $_->{target_branch} eq 'master' } @$mrs,
  ];

  my @results;
  # If we want the username/branch string again, it's from this commented-out
  # stuff. It can be nice sometimes (though MR number is more useful), but it
  # slows things down with more API requests, so we're skipping it for now.
  # my %projects;

  for my $mr (@$mrs) {
    # my $spid = $mr->{source_project_id};
    # my $sb = $mr->{source_branch};

    # my $project = $projects{$spid} ||= gitlab_get("/projects/$spid");
    push @results, {
      number => $mr->{iid},
      sha => $mr->{sha},
      author => $mr->{author}->{username},
      title => $mr->{title},
      # branch => $project->{namespace}{name} . "/" . $sb,
    };
  }

  return @results;
}

sub do_merge {
  my ($self, $opt, $mrs) = @_;

  my @mrs = @$mrs;

  say "I: fetching all the MRs";
  # We could use "--refmap=+refs/merge-requests/*/head:refs/remotes/origin/mr/*"
  # to get a ref to refer to, but because we're doing selective fetching
  # they'd never get purged. We'd need to either add the fetch refmap to
  # .git/config, and use a regular fetch, or prune them somehow, which is
  # easier said than done. Easier to just fetch without creating a local
  # ref, which sets FETCH_HEAD a bunch of times and ensures we have the
  # objects at least until a gc, so we should be fine.
  runx("git", "fetch", $opt->origin,
    map { "refs/merge-requests/$_/head" } map { $_->{number} } @mrs);

  eval {
    say "I: merging MRs: " . join(", ", map { "!$_->{number}" } @mrs);
    runx("git", "merge", "--no-ff",
      "-m", "Merge " . ($#mrs + 1) . " tagged MR" . ($#mrs ? "s" : "") . "\n\n"
      # We’re not using the “hm!” or “!” prefix, lest GitLab treat it as a
      # reference to the MR, and add a line in the MR’s history, resetting
      # its updated time and generally cluttering things up. Ditto on sha.
      . join("\n", map { "- $_->{number} by $_->{author}\n  $_->{title}" } @mrs),
      map { $_->{sha} } @mrs);
    # submodule update not needed, no more merges will happen
  };
  if ($@) {
    say "E: octopus merge failed, merging one-by-one for diagnostics";
    runx('git', 'reset', '--hard');
    runx('git', 'clean', '-fdx');
    runx("git", "submodule", "update");  # not sure whether needed
    for my $mr (@mrs) {
      say "I: merging !$mr->{number} ($mr->{sha})";
      runx("git", "merge", "--no-ff",
        "-m", "Merge !$mr->{number}", $mr->{sha});
      runx("git", "submodule", "update");
    }
    # There may be no *need* to give up here, but this really shouldn’t
    # happen, and if it does I’d prefer to know about it and investigate,
    # because it would indicate that we’ve got *something* wrong.
    die "E: octopus merge failed, but sequential merge succeeded; panic!"
  }
}

sub gitlab_get {
  my $path = shift;

  $path =~ s{^/*}{};

  my $github_ua;

  my $res = $github_ua->get("https://gitlab.fm/api/v4/$path");
  unless ($res->{status} eq '200') {
    die "Failed to get $path: " . Dumper($res);
  }

  my $content = eval { decode_json($res->{content}); };
  if ($@) {
    die "Failed to decode json from gitlab $path: $@ ($res->{content})\n";
  }

  return $content;
}

1;
