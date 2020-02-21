use v5.20;
use warnings;
package Buildotron::Logger;
use parent 'Log::Dispatchouli::Global';

use Log::Dispatchouli 2.019; # ->enable_std{err,out}

sub logger_globref {
  no warnings 'once';
  \*Logger;
}

sub default_logger_class { 'Buildotron::Logger::_Logger' }

sub default_logger_args {
  return {
    ident     => "buildotron",
    facility  => 'daemon',
    to_stderr => $_[0]->default_logger_class->env_value('STDERR') ? 1 : 0,
  }
}

{
  package Buildotron::Logger::_Logger;
  use parent 'Log::Dispatchouli';

  sub env_prefix { 'BUILDOTRON_LOG' }
}

1;
