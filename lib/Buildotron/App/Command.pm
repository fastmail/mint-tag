use v5.20;
use warnings;
package Buildotron::App::Command;
use base 'App::Cmd::Command';

use IPC::System::Simple qw(runx);

binmode(STDIN, ":encoding(UTF-8)");
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");


sub config { $_[0]->app->config }

sub run_git {
  my ($self, @rest) = @_;

  my $str = join(q{ }, 'git', @rest);
  say "I: running $str";
  runx('git', @rest);
}

1;
