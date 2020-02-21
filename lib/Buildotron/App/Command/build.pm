use v5.20;
use warnings;
package Buildotron::App::Command::build;

use Buildotron::App -command;

sub usage_desc { "%c build %o" }

sub opt_spec {
  return (
    [ 'config|c=s', 'config file to use', { required => 1 } ],
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
}

1;
