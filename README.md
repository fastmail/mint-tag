# mint-tag

This is a pretty generic way of building branches/tags from a config file. Its
main job is to fetch a series of merge/pull requests with some label and build
a branch from them. It's still a work in progress.

## Config

This is all driven by a config file. There's a sample in the config/
directory.

```toml
[meta]
committer_name = "Mergebot 9000"
committer_email = "git@example.com"

[local]
path = "/some/local/path"
target_branch = "deploy"
upstream_base = "upstream/master"
clone = true

[remote.github]
interface_class = "App::MintTag::Remote::GitHub"
api_url = "https://api.github.com"
api_key = "your-api-key"
repo = "cyrusimap/cyrus-imapd"

[remote.fastmail]
interface_class = "App::MintTag::Remote::GitLab"
api_url = "https://gitlab.fm/api/v4"
api_key = "ENV:GITLAB_API_KEY"
repo = "fastmail/cyrus-imapd"

[[build_steps]]
name = "upstream"
remote = "github"
label = "include-in-deploy"
trusted_org = "fastmail"
tag_prefix = "cyrus"

[[build_steps]]
name = "capstone"
remote = "fastmail"
label = "include-in-deploy"
tag_prefix = "cyrus-fm"
rebase = true
```

`[meta]` defines the committer who will be the author of these commits.
`committer_name` is optional (it defaults to "MintTag"), but
`committer_email` is required. We require this, rather than use whatever git
config you have set up in your environment, so that the SHAs produced by the
builder are guaranteed to be the same, provided they have the same parent and
constituent merge requests.

`[local]` defines the local repository set up (i.e., on the machine this
program is running). We assume that there is already a clone in `path`; if
there isn't, and you want to clone anew, set `clone = true` (this has no
effect if the directory already exists). The target branch is the name of the
branch we will build, and the upstream base is where we'll reset before
starting work.

You can have one or more remotes. Each remote must have an `interface_class`,
which tells the builder how to fetch the MRs. You also need to provide
instructions as to how to fetch the things it needs. You can provide your
`api_key` directly, but if it begins with the magic string `ENV:`, we'll fetch
it from the named environment variable instead. That means you can commit the
configs without worrying about leaking secrets.

`build_steps` is an array of steps.  Each must include a label, a pointer to a
remote config, a name, and an optional tag prefix. If you specify it, you'll
get a tag in the form `PREFIX-yyyymmdd.nnn-gSHA`, where `yyyymmdd` is the
current date in UTC, and `nnn` is a serial number (starting at 001, reset every
day, incremented on each of a day's builds). If you don't, specify a tag
prefix, the step will be untagged.

If `rebase` is present and true, each merge request in this step will be
rebased on top of HEAD before merging. This has some knock-on effects:
notably, if you build twice in a row you'll get different shas (without
rebase, builds give repeatable shas).

If a build step has a `trusted_org` key, it means only merge requests authored
by members of that organization will be included in the build.

## Perly bits

The perl interface is meant to be dead simple:

```perl
my $minter = App::MintTag->from_config_file('config/sample.toml');
minter->mint_tag();
```

If you want more control over the build process, you can just call individual
methods yourself. You might do this if, say, you want a human to confirm that
those MRs are in fact the ones you want, and insert `$self->confirm_mrs($mrs)`
between the fetch and merge steps. Or, maybe you want to merge all the MRs at
once in a big octopus, in which case you could fetch the MRs from every
step, combine them, then call `->merge_mrs(\@all_mrs)`. You do you, buddy.

## Guts

When you call `->from_config_file`, we build an App::MintTag::Config object.
That sets up objects for each remote based on their `interface_class`, either
GitHub or GitLab. Those each consume the App::MintTag::Remote role, which I've
been meaning to write _forever_ and this finally gave me an excuse. That role
requires the method `get_mrs_for_label`, which returns a list of
App::MintTag::MergeRequest objects. Those are very straightforward objects, but
it means that later you don't have to be concerned about the guts of the
GitHub/GitLab APIs and the different ways in which they are each terrible.

The merging process is straightforward:

1. fetch all the remotes
2. try to do an octopus merge
3. if that fails, try merging one-by-one to find the conflict

This is mostly stolen from the branch rebuilder we have in hm, but with better
diagnostics (I hope).

If you've defined a `tag_prefix` for a step, we'll tag the resulting commit.
That's straightforward, if a little silly.

This uses only CPAN modules. If you have a normal rjbs-influenced environment,
you probably have these kicking around already, but you can install them with
the cpanfile (or Makefile.PL).
