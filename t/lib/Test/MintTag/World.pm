use v5.36;
package Test::MintTag::World;
# ABSTRACT: everything mint-tag needs to run: a config, forges, and a clock

use Moo;

use Carp ();
use DateTime;
use Path::Tiny ();
use Storable ();
use Try::Tiny;

use App::MintTag;
use App::MintTag::Logger '$Logger';

use Test::MintTag::Forge;
use Test::MintTag::Remote;
use Test::MintTag::Repo;
use Test::MintTag::Result;

# A world is built from a mint-tag config, given as a Perl data structure in
# the same shape as the TOML.  We fill in the boring parts:
#
#   * every remote gets the test interface_class, an api_url that leads to a
#     forge of its own, and an api_key
#   * local.path is pointed into the world's temporary directory, and
#     local.clone is turned on, unless you've set them yourself
#
# The remote named by local.upstream_base gets a forge with the standard
# upstream history.  Every other remote's forge is a mirror of that one.
#
# The config gets written out as TOML, and that file is what mint-tag reads,
# so that every run goes through the real config loader.
#
# We work on a copy of the config we were given, so one config can safely be
# used to build several worlds.

has config => (
  is => 'ro',
  required => 1,
  coerce => sub ($config) { Storable::dclone($config) },
);

# A hashref of (remote name => [ merge request specs ]), where the specs are
# the arguments to Test::MintTag::Forge's add_mr method.  A merge request with
# no labels argument at all gets the label wanted by the first build step that
# uses its remote.
has mrs => (
  is => 'ro',
  default => sub { {} },
);

# A hashref of (org name => [ usernames ]), known to every forge.
has orgs => (
  is => 'ro',
  default => sub { { fastmail => [ qw(alice bob carol) ] } },
);

# The time mint-tag will think it is, in epoch seconds.  This is later than
# any commit the forges will make.
has now => (
  is => 'rw',
  default => sub { _epoch_for('2026-11-20') },
);

sub _epoch_for ($ymd) {
  my ($y, $m, $d) = split /-/, $ymd;

  return DateTime->new(
    year => $y, month => $m, day => $d, hour => 12, time_zone => 'UTC',
  )->epoch;
}

# Set the clock to noon UTC on a date given as YYYY-MM-DD.
sub set_date ($self, $ymd) {
  $self->now(_epoch_for($ymd));
  return;
}

# The temporary directory is deleted when this object goes away, so we hang on
# to it, and give out its real path, because git will resolve symlinks, and
# then paths we compare will not match.
has _tempdir => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub { Path::Tiny->tempdir('minttag-test-XXXXXX') },
);

sub root ($self) { $self->_tempdir->realpath }

has _forges => (
  is => 'ro',
  init_arg => undef,
  default => sub { {} },
);

sub forge ($self, $name) {
  return $self->_forges->{$name} // Carp::confess("no forge named $name");
}

sub config_file ($self) { $self->root->child('mint-tag.toml') }

# The repository mint-tag does its work in.  It won't exist until mint-tag has
# run (or you've made it yourself).
sub local_repo ($self) {
  return Test::MintTag::Repo->new({
    path => Path::Tiny::path($self->config->{local}{path}),
  });
}

my $WORLD_COUNT = 0;

sub BUILD ($self, $arg) {
  my $config = $self->config;
  my $id     = ++$WORLD_COUNT;

  $config->{local}{path}  //= $self->root->child('local')->stringify;
  $config->{local}{clone} //= \1;

  my $upstream = $config->{local}{upstream_remote}
              // (split m{/}, $config->{local}{upstream_base} // '')[0]
              // Carp::confess("can't work out the upstream remote from config");

  Carp::confess("upstream remote $upstream is not in the config")
    unless $config->{remote}{$upstream};

  my $epoch = 1_600_000_000;
  my $tick  = sub { $epoch += 60 };

  my @names = sort {; ($b eq $upstream) <=> ($a eq $upstream) || $a cmp $b }
              keys $config->{remote}->%*;

  for my $name (@names) {
    my $forge = Test::MintTag::Forge->new({
      name => $name,
      root => $self->root->child('forge'),
      orgs => $self->orgs,
      tick => $tick,
      ($name eq $upstream ? () : (mirror_of => $self->forge($upstream))),
    });

    $self->_forges->{$name} = $forge;

    my $remote = $config->{remote}{$name};
    $remote->{interface_class} //= 'Test::MintTag::Remote';
    $remote->{api_url}         //= "mock://world-$id/$name";
    $remote->{api_key}         //= 'hunter2';

    $Test::MintTag::Remote::FORGE_FOR{ $remote->{api_url} } = $forge;
  }

  for my $name (sort keys $self->mrs->%*) {
    $self->add_mr($name, %$_) for $self->mrs->{$name}->@*;
  }

  $self->write_config;
}

# Write the config file.  This happens when the world is built, but if you
# change the config afterward, you'll need to do it again.
sub write_config ($self) {
  $self->config_file->spew_utf8(_toml_for($self->config));
  return;
}

# Open a merge request on the forge behind the named remote.  This takes the
# arguments of Test::MintTag::Forge's add_mr, but if you don't provide labels,
# the merge request gets the label that'll get it included in a build.
sub add_mr ($self, $remote_name, %arg) {
  unless ($arg{labels}) {
    my ($step) = grep {; $_ && $_->{remote} eq $remote_name }
                 ($self->config->{build_steps} // [ $self->config->{release_mode} ])->@*;

    $arg{labels} = [ $step && ! ref $step->{label} ? $step->{label} : () ];
  }

  return $self->forge($remote_name)->add_mr(%arg);
}

# Run mint-tag, in auto mode, just like bin/mint-tag would.  This returns a
# Test::MintTag::Result.  The arguments, all optional:
#
#   mrs  - an arrayref of extra merge request numbers, like --mr
#   repo - the repo name to use in release mode, like --repo
sub mint ($self, %arg) {
  return $self->_run(sub ($app) { $app->mint_tag(1, $arg{mrs} // []) }, %arg);
}

# Run mint-tag to tag an arbitrary sha, like bin/mint-tag --sha would.
sub tag_sha ($self, $sha) {
  return $self->_run(sub ($app) { $app->tag_arbitrary_sha($sha) });
}

sub _run ($self, $code, %arg) {
  my $cwd = Path::Tiny->cwd;
  my $now = $self->now;

  my $local = $self->local_repo;
  my %had_tag = $local->path->is_dir ? (map {; $_ => 1 } $local->tags) : ();

  $Logger->clear_events;

  my ($app, $error);

  {
    no warnings 'redefine';
    local *App::MintTag::now = sub { $now };

    # mint-tag sets the dates on its octopus merges, but everything else it
    # commits (or tags) is dated "now", which had better be our now.
    local $ENV{GIT_AUTHOR_DATE}    = "$now +0000";
    local $ENV{GIT_COMMITTER_DATE} = "$now +0000";

    try {
      $app = App::MintTag->from_config_file($self->config_file->stringify, $arg{repo});
      $code->($app);
    } catch {
      $error = $_;
    };
  }

  # mint-tag will have changed into its working directory.  If we leave things
  # that way, the next thing to compute a relative path is in for a surprise.
  chdir $cwd or die "can't chdir back to $cwd: $!";

  my @new_tags = $local->path->is_dir
               ? (grep {; ! $had_tag{$_} } $local->tags)
               : ();

  return Test::MintTag::Result->new({
    world    => $self,
    app      => $app,
    error    => $error,
    logs     => [ map {; $_->{message} } $Logger->events->@* ],
    new_tags => \@new_tags,
  });
}

# This turns a config data structure into TOML.  It knows exactly as much TOML
# as a mint-tag config needs: tables of scalars, tables of tables, and arrays
# of tables.  Booleans are written as references: \1 and \0.
sub _toml_for ($config) {
  return join q{}, map {; _toml_table($_, $config->{$_}, 0) } sort keys %$config;
}

sub _toml_table ($name, $value, $is_array_member) {
  if (ref $value eq 'ARRAY') {
    return join q{}, map {; _toml_table($name, $_, 1) } @$value;
  }

  my @scalar_keys = grep {; ref $value->{$_} ne 'HASH' && ref $value->{$_} ne 'ARRAY' }
                    sort keys %$value;

  my @table_keys  = grep {; ref $value->{$_} eq 'HASH' || ref $value->{$_} eq 'ARRAY' }
                    sort keys %$value;

  my $toml = $is_array_member ? "[[$name]]\n" : "[$name]\n";
  $toml .= sprintf "%s = %s\n", $_, _toml_scalar($value->{$_}) for @scalar_keys;
  $toml .= "\n";
  $toml .= _toml_table("$name.$_", $value->{$_}, 0) for @table_keys;

  return $toml;
}

sub _toml_scalar ($value) {
  return $$value ? 'true' : 'false' if ref $value eq 'SCALAR';
  return $value if $value =~ /\A-?[0-9]+\z/;
  return '"' . ($value =~ s/(["\\])/\\$1/gr) . '"';
}

1;
