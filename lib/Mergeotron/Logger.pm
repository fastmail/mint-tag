use v5.20;
use warnings;
package Mergeotron::Logger;
use parent 'Log::Dispatchouli::Global';

use Log::Dispatchouli 2.019; # ->enable_std{err,out}

sub logger_globref {
  no warnings 'once';
  \*Logger;
}

sub default_logger_class { 'Mergeotron::Logger::_Logger' }

sub default_logger_args {
  return {
    ident     => "Mergeotron",
    facility  => 'daemon',
    to_stderr => $_[0]->default_logger_class->env_value('STDERR') ? 1 : 0,
  }
}

{
  package Mergeotron::Logger::_Logger;
  use parent 'Log::Dispatchouli';

  sub env_prefix { 'MERGEOTRON_LOG' }
}

1;
