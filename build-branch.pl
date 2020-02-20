#!/usr/bin/perl

use 5.014;
use warnings;
use strict;

use Getopt::Long::Descriptive;
use IPC::System::Simple qw(runx);
use List::MoreUtils qw(uniq);
use HTTP::Tiny;
use JSON qw(decode_json);
use Data::Dumper;

my ($opt, $desc) = describe_options(
  '%c %o',
  [ 'target=s',   'branch name we are building', { required => 1 } ],
  [ 'include=s@', 'include MRs with these labels', { required => 1 } ],
  [ 'origin=s',   'the remote from which to fetch', { default => 'fastmail' } ],
  [ 'base=s',     'branch to use as the base', { default => 'master' } ],
);

my $api_token = $ENV{FM_API_TOKEN};
unless ($api_token) {
  die "E: no FM_API_TOKEN! configure one via project-level secret variables in Gitlab\n";
}

chdir "/home/mod_perl/hm" or die "couldn't chdir to /home/mod_perl/hm: $!\n";

my $gitlab_ua = HTTP::Tiny->new(
  default_headers => {
    'Private-Token' => $api_token,
  },
);

my $project_id = 2;

my $target = $opt->target;
my @labels = @{ $opt->include // [] };
die "no --include given\n" unless @labels;

{
  say "I: creating branch: $target";
  runx('git', 'reset', '--hard');
  # runx('git', 'clean', '-fdx');
  runx('git', 'checkout', '-B', $target, join(q{/}, $opt->origin, $opt->base));
  runx("git", "submodule", "update");

  {
    my @mrs = get_mrs(@labels);
    if (@mrs) {
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
    else {
      say "W: no branches labels @labels";
    }
  }

}

exit 0;

sub get_mrs {
  my @labels = @_;

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

sub gitlab_get {
  my $path = shift;

  $path =~ s{^/*}{};

  my $res = $gitlab_ua->get("https://gitlab.fm/api/v4/$path");
  unless ($res->{status} eq '200') {
    die "Failed to get $path: " . Dumper($res);
  }

  my $content = eval { decode_json($res->{content}); };
  if ($@) {
    die "Failed to decode json from gitlab $path: $@ ($res->{content})\n";
  }

  return $content;
}

