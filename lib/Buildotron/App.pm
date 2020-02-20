package Buildotron::App;
use App::Cmd::Setup -app;

sub build_config {
  my ($self, $config_file) = @_;

  require Buildotron::Config;
  $self->{config} = Buildotron::Config->from_file($config_file);
}

sub config {
  my ($self) = @_;
  return $self->{config} if $self->{config};

  require Carp;
  Carp::confess("tried to call ->config without first calling ->build_config");
}

1;
