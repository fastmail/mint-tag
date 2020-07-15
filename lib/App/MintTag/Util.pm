use v5.20;
package App::MintTag::Util;
# ABSTRACT: Tiny subs needed in more than one place

use experimental qw(postderef signatures);

use IPC::Run3 qw(run3);
use App::MintTag::Logger '$Logger';
use Process::Status;
use Sub::Exporter -setup => [ qw(
  run_git
  re_for_tag
  compute_patch_id
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

  unless ($ps->is_success) {
    $Logger->log_fatal([
      "encountered error while running %s: %s",
      "@cmd",
      $out,
    ]);
  }

  return $out;
}

sub re_for_tag ($prefix) {
  return qr/\Q$prefix\E-\d{8}\.\d{3}/a;
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

1;
