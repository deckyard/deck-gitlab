<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/gitlab

A client for the [GitLab™](https://about.gitlab.com/) REST API (`/api/v4`),
for gitlab.com or a self-managed instance. `call` reaches any endpoint,
`getAll` follows the pages of a list and `graphql` runs a GraphQL™ query.
Typed verbs cover the daily work: projects, groups and subgroups, members
and hooks; issues, notes, labels and milestones; merge requests, approvals
and merging; releases with their links and the generic package registry;
branches, tags, files and the repository tree; commits, commit statuses,
pipelines and CI/CD variables.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/gitlab/" as gitlab;

def c as gitlab.Client init gitlab.client("gitlab.com");
$c = gitlab.withToken($c, fs.readString("/run/secrets/gitlab"));
io.printf("%s\n", gitlab.currentUser($c).username);
```

A `Client` is a value. `withToken` and the other `with*` functions return a
changed copy, so assign the result back to `$c`.

A project is its numeric id (`"278964"`) or its full path
(`"group/subgroup/name"`, as many levels as it has); the deck checks a path
and encodes it, so pass it as it appears in the project's URL. Issues and
merge requests are addressed by their `iid`, the number shown in the web
interface (`#12`, `!15`). States use GitLab's words: `opened`, `closed`,
`merged`. Times are the RFC 3339 strings GitLab sends.

## Errors

Every failure is a `gitlab.GitlabError` (kind `"gitlab"`). The message names
the request, the HTTP status and GitLab's reason; the status is the `status`
field, so a handler branches on it rather than on the text:

```text
gitlab: GET /projects/me%2Fmissing: HTTP 404: Project Not Found
gitlab: POST /projects: HTTP 400: name has already been taken; path has already been taken
```

```jennifer
try {
    def p as gitlab.Project init gitlab.project($c, "me/missing");
} catch (e) {
    if ($e.kind == "gitlab" and $e.status == 404) {
        io.printf("no such project, or not visible to this token\n");
    } else {
        throw $e;
    }
}
```

A refused value (a malformed project path, an empty title, an id or `iid`
below 1) is a `GitlabError`
with status 0, thrown before anything is sent. A list past `MAX_PAGES` pages,
or a reply over its size cap, is kind `"limit"`; a deadline is `"timeout"`;
a cancelled task stays `"cancelled"`. These are plain `Error`s. A network
failure (refused, reset, unreachable, DNS, TLS) is the `net.NetError` the
interpreter raised, kind `"net"`, passed on unchanged: its `reason` says what
failed, and `sent` false means GitLab never got the request.

## Requirements

Jennifer 0.27.0 or newer, the default `jennifer` binary, and the `net`
capability.

## Trademarks

GitLab™ is a trademark of GitLab Inc. GraphQL™ is a trademark of LF
Projects, LLC. Other product and company names may be trademarks of their
respective owners. They are used only to identify the products this deck
works with. This deck is an independent project, not affiliated with,
sponsored or endorsed by GitLab Inc.
