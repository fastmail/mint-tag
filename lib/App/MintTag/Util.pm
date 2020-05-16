use v5.20;
package App::MintTag::Util;

use experimental qw(postderef signatures);

use IPC::Run3 qw(run3);
use App::MintTag::Logger '$Logger';
use Process::Status;
use Sub::Exporter -setup => [ qw(
  run_git
  re_for_tag
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

  $ps->assert_ok(join(q{ }, @cmd[0..1]));

  return $out;
}

sub re_for_tag ($prefix) {
  return qr/\Q$prefix\E-\d{8}\.\d{3}/a;
}

1;
