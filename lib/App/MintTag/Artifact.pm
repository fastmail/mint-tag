use v5.20;
package App::MintTag::Artifact;
# ABSTRACT: object representing a built tag

use Moo;
use experimental qw(postderef signatures);

use TOML::Parser;
use Try::Tiny;

use App::MintTag::Logger '$Logger';
use App::MintTag::Util qw(url_without_credentials);

has config => (
  is => 'ro',
  required => 1,
);

has base => (
  is => 'ro',
  required => 1,
);

has tag_name => (
  is => 'ro',
  required => 1,
);

has annotation_version => (
  is => 'ro',
  required => 1,
);

# used when building from a minttag object, not when generating from tag
# message
has this_step => (
  is => 'ro',
  predicate => 'has_this_step',
);

has step_data => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my @steps;

    for my $step ($self->config->steps) {
      my $data = {
        name           => $step->name,
        remote         => $step->remote->clone_url,
        merge_requests => [],
      };

      for my $mr ($step->merge_requests) {
        push $data->{merge_requests}->@*, {
          number => $mr->number,
          title  => $mr->title,
          sha    => $mr->sha,
          merge_base => $mr->merge_base,
          patch_id   => $mr->patch_id,
          original_sha        => $mr->original_sha,
          original_merge_base => $mr->original_merge_base,
        };
      }

      push @steps, $data;
      last if $self->has_this_step && $step eq $self->this_step;
    }

    return \@steps;
  },
);

# The TOML generation perl library kinda stinks, so I'ma construct it
# manually. It's fine. -- michael, 2020-05-13
sub as_toml ($self) {
  # This wants to be a template, BUT ALSO.
  my @lines = (
    '[meta]',
    sprintf('tag_name = "%s"', $self->tag_name),
    sprintf('annotation_version = %d', $self->annotation_version),
    sprintf('base = "%s"', $self->base),
    "",
  );

  for my $step ($self->step_data->@*) {
    push @lines, '[[build_steps]]';
    push @lines, sprintf('name = "%s"', $step->{name});

    push @lines, sprintf('remote = "%s"', url_without_credentials($step->{remote}));

    for my $mr ($step->{merge_requests}->@*) {
      my $title = $mr->{title};
      # The obvious way to write a backslash in TOML is as two backslashes,
      # but TOML::Parser misreads that when what follows looks like another
      # escape sequence, or is a quote.  It does fine with the Unicode escape
      # for a backslash, which means just the same thing.
      $title =~ s/\\/\\u005C/g;
      $title =~ s/"/\\"/g;  # bad escaping is bad

      push @lines, '';
      push @lines, sprintf('  [[build_steps.merge_requests]]');
      push @lines, sprintf('  number = "%s"',     $mr->{number});
      push @lines, sprintf('  title = "%s"',      $title);
      push @lines, sprintf('  sha = "%s"',        $mr->{sha});
      push @lines, sprintf('  merge_base = "%s"', $mr->{merge_base});
      push @lines, sprintf('  patch_id = "%s"',   $mr->{patch_id});
      push @lines, sprintf('  original_sha = "%s"', $mr->{original_sha});
      push @lines, sprintf('  original_merge_base = "%s"', $mr->{original_merge_base});
    }

    push @lines, '';
  }

  return join "\n", @lines;
}

sub from_toml ($class, $config, $toml_str) {
  my $data = try {
    TOML::Parser->new->parse($toml_str);
  } catch {
    my $e = $_;
    $Logger->log("error reading artifact from TOML");
  };

  return unless $data;

  return $class->new({
    config => $config,
    base => $data->{meta}{base},
    tag_name => $data->{meta}{tag_name},
    annotation_version => $data->{meta}{annotation_version},
    step_data => $data->{build_steps},
  });
}

# This is step_data, but in a different shape. Keyed on $cloneurl!$number,
# where the clone URL never has credentials in it, whether or not the step data
# did.  (Tags made by older versions of mint-tag do have them.)
has merge_requests => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my %mrs;

    for my $step ($self->step_data->@*) {
      my $url = url_without_credentials($step->{remote});
      for my $mr ($step->{merge_requests}->@*) {
        my $key = sprintf("%s!%d", $url, $mr->{number});

        # maybe: rethink if we want to include merge-base?
        # If the step rebased the MR, its sha and merge_base are the ones from
        # after the rebase.  The original_ ones are from before, and are what
        # to use for comparing with what a forge has now.  Tags made by older
        # versions of mint-tag don't have them.  Then, the best we can do is
        # to act like there was no rebase.
        $mrs{$key} = {
          original_sha        => $mr->{sha},
          original_merge_base => $mr->{merge_base},
          %$mr,
          key       => $key,
          step_name => $step->{name},
          remote    => scalar $self->config->remote_for_url($url),
        },
      }
    }

    return \%mrs;
  },
);

sub _key_for_mr ($class, $mr) {
  return sprintf("%s!%d", url_without_credentials($mr->remote->clone_url), $mr->number);
}

# $mr is a blessed merge request object
sub contains_mr ($self, $mr) {
  return !! $self->data_for_mr($mr);
}

# return the data we have matching a blessed merge request object
sub data_for_mr ($self, $mr) {
  return $self->merge_requests->{ $self->_key_for_mr($mr) };
}

# Given all the steps of a build, return the MRs that we have, but that aren't
# in any of those steps.  This returns a list of pairs, like:
#
#   [ $step, $mr_data ]
#
# ...where the step is the one the MR has gone missing from.  That's the step
# with the same name as the step we have the MR in.  If there's no such step,
# maybe because it's been renamed, it's the first step that uses the MR's
# remote.  If there's no such step either, there's no step in the pair.
#
# The pairs are sorted by the MR's remote, and then by its number.
sub missing_mrs ($self, @steps) {
  my %have = map {; $self->_key_for_mr($_) => 1 }
             map {; $_->merge_requests } @steps;

  my (%step_named, %step_using);
  for my $step (@steps) {
    $step_named{ $step->name } //= $step;
    $step_using{ url_without_credentials($step->remote->clone_url) } //= $step;
  }

  my @missing;

  # The keys are "$url!$number".  Sort them by URL, and then by number.
  my @keys = map  {; $_->[0] }
             sort {; $a->[1] cmp $b->[1] || $a->[2] <=> $b->[2] }
             map  {; [ $_, /\A(.*)!([0-9]+)\z/ ] }
             keys $self->merge_requests->%*;

  for my $mr (map {; $self->merge_requests->{$_} } @keys) {
    next if $have{ $mr->{key} };

    my $remote_url = $mr->{key} =~ s/![0-9]+\z//r;

    push @missing, [
      $step_named{ $mr->{step_name} } // $step_using{$remote_url},
      $mr,
    ];
  }

  return @missing;
}

1;
