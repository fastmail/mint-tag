use v5.20;
package Buildotron;
use Moo;

use Buildotron::Config;

has config => (
  is => 'ro',
  required => 1,
);

sub from_config_file {
  my ($class, $config_file) = @_;
  return $class->new({
    config => Buildotron::Config->from_file($config_file),
  });
};

sub build {
  my ($self) = @_;

  say "can we build it?\nno not yet!";
}


1;
