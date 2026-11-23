use v5.20;
package App::MintTag::Util;
# ABSTRACT: Tiny subs needed in more than one place

use experimental qw(postderef signatures);

use IPC::Run3 qw(run3);
use App::MintTag::Logger '$Logger';
use Process::Status;
use URI;
use Sub::Exporter -setup => [ qw(
  run_git
  compute_patch_id
  url_without_credentials
) ];

sub run_git (@cmd) {
  # A little silly, but hey.
  my $arg = {};
  $arg = pop @cmd if ref $cmd[-1] eq 'HASH';

  $Logger->log_debug([ "run: %s", join(q{ }, 'git', @cmd) ]);

  my $in = $arg->{stdin} // undef;
  my $out;

  unshift @cmd, 'git';
  run3(\@cmd, $in, \$out, \$out);
  my $ps = Process::Status->new;

  chomp $out;

  if ($Logger->get_debug) {
    local $Logger = $Logger->proxy({ proxy_prefix => '(git): ' });
    my @lines = split /\r?\n/, $out;
    $Logger->log_debug($_) for @lines;
  }

  if (! $ps->is_success) {
    # Sometimes we run git just to check if something exists, where an error
    # is not exceptional, in which case the extra log is just noise.
    die "git failed: @cmd" if $arg->{suppress_log_error};

    $Logger->log_fatal([
      "encountered error while running %s: %s",
      "@cmd",
      $out,
    ]);
  }

  return $out;
}

sub compute_patch_id ($base, $head) {
  # Compute the patch id, but turn off debug logging, because it's gonna be
  # super noisy.
  local $Logger = $Logger->proxy({ debug => 0 });

  my $patch = run_git('diff-tree', '--patch-with-raw', $base, $head);

  my $line = run_git('patch-id', { stdin => \$patch });

  my ($patch_id) = split /\s/, $line;
  return $patch_id;
}

# Given a URL, return it as a string with any username and password removed.
# Things that aren't quite URLs, like the user@host:path form used for git over
# ssh, come back unchanged.
sub url_without_credentials ($url) {
  my $uri = URI->new("$url");
  $uri->userinfo(undef) if $uri->can('userinfo');
  return "$uri";
}

1;
