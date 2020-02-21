use v5.20;
use warnings;
package Buildotron::App::Command;
use base 'App::Cmd::Command';

binmode(STDIN, ":encoding(UTF-8)");
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");


sub config { $_[0]->app->config }

1;
