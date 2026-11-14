# @deckyard/gitlab

[![test](https://github.com/deckyard/deck-gitlab/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-gitlab/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-gitlab/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-gitlab)](https://github.com/deckyard/deck-gitlab/releases/latest)

A client for the GitLab REST (v4) and GraphQL API, for
[Jennifer](https://jennifer-lang.dev/) programs: gitlab.com or a
self-managed instance. Projects, groups and subgroups, members and hooks;
issues, notes, labels and milestones; merge requests, approvals and
merging; releases with their links and the generic package registry;
branches, tags, files and the repository tree; commits, commit statuses,
pipelines and CI/CD variables. `call` and `getAll` reach every other
endpoint, `graphql` the GraphQL API.

**[Documentation](https://deckyard.github.io/deck-gitlab/)**

## Install

```sh
jvc add @deckyard/gitlab
```

This vendors the deck to `vendor/<scope>/gitlab/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-gitlab-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/gitlab/" as gitlab;

def c as gitlab.Client init gitlab.client("gitlab.com");
$c = gitlab.withToken($c, fs.readString("/run/secrets/gitlab"));

for (def i in gitlab.issues($c, "my-group/app", "opened")) {
    io.printf("#%d %s\n", $i.iid, $i.title);
}
gitlab.createRelease($c, "my-group/app", "v1.2.0", "main", "", "Notes");
gitlab.uploadAsset($c, "my-group/app", "v1.2.0", "app", "app.tar.gz", fs.readBytes("dist/app.tar.gz"));
```

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (not
`jennifer-tiny`), and the `net` capability.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/gitlab_test.j      # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
