<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

A client for the GitLab REST API (`/api/v4`) and GraphQL, for gitlab.com or a
self-managed instance: projects, groups and subgroups, members, hooks and
forks; issues, notes, labels and milestones; merge requests, reviewers,
approvals and merging; releases with their links and uploads to the generic
package registry; branches, tags, files and the repository tree; commits and
commit statuses; pipelines (run, retry, cancel, trigger) and CI/CD
variables. `call` and `getAll` reach any other REST endpoint, `graphql` the
GraphQL API.

Deliberately left out, reachable through `call` and `getAll`: jobs, job logs
and artifacts, environments and deployments, protected branches and tags,
merge request discussions, wikis, snippets, group-level labels, variables and
hooks, pipeline schedules and the container registry. The deck does not run
git (no `exec`); one API over several forges is `@deckyard/codehost`.

## Decisions

- **The forgejo deck's design.** Transport, errors, tests and, where GitLab
  has the concept, function names and argument order follow
  `@deckyard/forgejo`, so `codehost` maps the forges one to one. Where GitLab
  differs the deck says so: issue label verbs return the `Issue` GitLab
  answers with, and there is no `setSecret`.
- **Three ways to authenticate.** `withToken` sends `PRIVATE-TOKEN`,
  `withBearer` an OAuth bearer token, `withJobToken` a CI `JOB-TOKEN`.
  Configuration is copy-returning (`withCaCert`, `withInsecure`,
  `withTimeout`, `withRetries`, `withPlainHttp`).
- **Addresses.** `client` takes a host, `host:port` or a URL; a bare host
  gets `https://`, a trailing `/api/v4` is dropped and an instance below a
  sub-path keeps it. `?`, `#`, `@` and spaces are refused.
- **Project and group addressing.** A project is a numeric id or a full path
  of two or more segments (subgroups included); the deck encodes `/` as
  `%2F` itself. Refs, tags and file paths are checked (no empty, `.` or `..`
  segments, no control characters) and encoded whole, as GitLab expects.
  Ids below 1 are refused locally rather than sent for a 404.
- **Retries only for reads.** `http.send` retries GET and HEAD (backoff
  500 ms, `Retry-After` honoured up to 30 s); writes are never retried.
- **Redirects followed by the deck.** `http.send`'s own redirect handling is
  never turned on: the deck follows a 3xx for GET and HEAD only, and only to
  a target under the client's `/api/v4/`. This is needed for
  `releases/permalink/latest`, which answers 302. Byte downloads follow up to
  5 redirects, send the token only to the client's origin and refuse a hop
  from https to http.
- **Two paging styles.** `getAll` asks for `PAGE_SIZE` (100), follows
  `X-Next-Page` (offset paging) or else a `Link` `rel="next"` (keyset
  paging), which must stay under the client's API path, and stops at
  `MAX_PAGES` (1000). The repository tree uses keyset paging, since GitLab's
  offset paging of the tree is legacy.
- **Files through the commits API.** `writeFile` and `deleteFile` post a
  one-action commit, which returns the commit SHA the files API does not.
  `writeFile` decides create or update with a `HEAD` on the file; an empty
  branch means the project's default branch.
- **Release assets are package files plus links.** `uploadAsset` uploads to
  the generic package registry and adds a `package` link to the release:
  versioned, downloadable with the token through the API, and what `glab`
  uses. Project uploads were rejected because their URLs are web routes that
  do not take `PRIVATE-TOKEN`. `downloadAsset` fetches only links under the
  client's address; links to other hosts are the caller's, without the
  token.
- **Variables for every environment.** `setVariable` sets the `*` scope
  (with a `masked` flag; GitLab has no write-only secrets), and every PUT and
  DELETE carries the scope filter: without it GitLab overwrote a
  production-only copy and answered 409 for a name set in two scopes (found
  in live validation). `variables` lists only the `*` entries, the ones the
  deck changes. Scoped variables need `call`.
- **Client-side combined status.** GitLab has no combined status endpoint:
  `combinedStatus` reads the latest status per name and takes the worst,
  ranking an unknown state as pending.
- **User names, not ids.** `setAssignees`, `setReviewers`, `addMember` and
  `removeMember` take user names and resolve them (one request per name).
- **Tolerant readers, strict inputs.** Replies are read with accessors that
  turn an absent or `null` field into the zero value and accept numbers sent
  as strings. A request with nothing to change is refused locally, and a
  label name holding a comma (GitLab's list separator) is refused.

## Errors

Every failure of the deck's own is a `GitlabError{kind: "gitlab", message,
status}`, with the HTTP status, or 0 for a local check or a failure with no
answer. The message names the request and GitLab's reason, read from its
three error shapes (a `message` string, a `message` map of field to errors,
and OAuth's `error` with `error_description`), cut to 200 printable ASCII
characters; caller and server strings are cut to 60. A GraphQL `errors`
answer is a `GitlabError` with status 200. Create-or-update decisions read
`status` (404, or 409 for `addMember`), never the message.

Passed on: `MAX_PAGES`, too many redirects and a transport size cap are kind
`"limit"`, a deadline `"timeout"`, a closed peer `"closed"` (each with the
request in the message), and a cancelled task unchanged. A network failure
(refused, reset, unreachable, DNS, TLS, a close before any reply) is the
interpreter's `net.NetError` of kind `"net"`, passed on unchanged so its
`reason`, `sent` and `replied` fields survive. Other transport failures are
a `GitlabError` with status 0. A helper that takes a caught
deck error is typed `GitlabError`.

## Security and limits

- **A token over plain http only to loopback.** A client for `http://`
  sends its token (whichever header carries it) to `127.0.0.1`, `localhost`
  or `[::1]` only, unless `withPlainHttp` allows another host, as in the
  github deck. The check runs where the auth headers are built, before every
  REST, GraphQL, upload and download request, so a refused client sends
  nothing. An anonymous client carries no secret and is not refused.
- **The token never leaves the instance.** The deck follows redirects
  itself and only within the API, and byte downloads send the token to the
  client's origin only. GitLab's tokens travel in `PRIVATE-TOKEN` and
  `JOB-TOKEN`, which `http.send` once forwarded across origins; that was
  found while writing this deck and fixed in the interpreter (M28.59).
- **Size caps.** `readFile` and `downloadAsset` take a cap, 0 meaning
  64 MiB; past it the call is kind `"limit"`.
- **Deadlines.** Every request has a timeout, 30 s by default.
- **Input validation** before anything reaches a URL, as described above;
  hook and release link URLs must be http or https.

## Testing and validation

- 32 tests against a loopback fake built on `httpd` that answers scripted
  replies in order and records every request (method, decoded path, raw
  query, the three auth headers, content type, body); assertions cover what
  was sent as much as what was parsed. One test calls every export the
  others leave out, for the coverage check. No network beyond loopback and
  lookups of a `.invalid` name, no credentials.
- Checked live on 2026-11-14:
  - gitlab.com, anonymous and read-only: a four-segment subgroup project,
    releases over three pages, the latest-release permalink, the root tree
    with keyset paging, a raw file, a group, open merge requests and issues,
    and a package link download.
  - GitLab CE 19.5.5 in a local container with an admin token: every write
    verb (projects, files, branches, tags, merge requests with approvals and
    squash merges, issues, labels, milestones, notes, releases with package
    uploads and links, statuses, variables, hooks, members, pipelines,
    GraphQL, bad tokens).
- Only against the fake: retries on 429 and 5xx, foreign redirects and next
  links, the generic-kind pass-through and `withJobToken`.
- The example reads gitlab.com; CI only parses it.

## Known limitations and open questions

- The client's address must be the instance's configured external URL:
  keyset `Link` headers carry that host, and a next page elsewhere is
  refused.
- GitLab computes merge status and merge request commits in the background,
  so they may lag right after `createMergeRequest`; pipeline cancel and retry
  return before the jobs change state.
- The `edit*` functions leave out empty string fields, so they cannot clear
  a field to `""`.

## Dependencies on the interpreter

- Floor `>=0.27.0`, for the UTF-8 codecs of `encoding.encode` / `decode`
  and `strings.replicate`; the default binary and the `net` capability (not
  `jennifer-tiny`).
- The bundled `http`, `graphql` and `uri` modules; `http.send`'s cross-origin
  header allowlist (`jennifer`'s M28.59).
- A reached cap as kind `"limit"` (M28.54), error structs accepted by
  lint's L104 (M28.50), and transport failures as `net.NetError` (M28.65).
- `graphql.j` from 0.27.0 refuses an `Authorization` header over plain http
  to another machine unless its `Client.allowInsecureHttp` is set, which
  `withPlainHttp` does.
