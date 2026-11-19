<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Connecting

## The address

`client` takes a host name or a URL. A bare host gets `https://`; an
instance below a path keeps it:

```jennifer
def c as gitlab.Client init gitlab.client("gitlab.com");
$c = gitlab.client("https://example.com/gitlab");   # GitLab at /gitlab
$c = gitlab.client("http://localhost:8929");        # a local test instance
```

Use the address the instance calls itself (its `external_url`): GitLab
writes it into the `Link` headers of keyset-paged lists, and `getAll` only
follows a next page on the client's own address.

A self-managed instance with its own CA is trusted with `withCaCert`;
`withInsecure` turns certificate checking off.

A token goes over plain `http://` only to this machine (`127.0.0.1`, `::1`,
`localhost`). An instance elsewhere without TLS needs `withPlainHttp`, and
the token then crosses the network in clear:

```jennifer
$c = gitlab.withPlainHttp(gitlab.client("http://gitlab.lan"));
```

Without it every request with a token fails before anything is sent (kind
`"gitlab"`, status 0); an anonymous client is not refused.

## Tokens

`withToken` sends a personal, project or group access token as
`PRIVATE-TOKEN`. Give it only the scopes the program needs: `read_api` to
read, `api` to write.

```jennifer
$c = gitlab.withToken($c, fs.readString("/run/secrets/gitlab"));
io.printf("%s\n", gitlab.currentUser($c).username);
```

`withBearer` sends an OAuth 2 access token as `Authorization: Bearer`.
`withJobToken` sends `CI_JOB_TOKEN` inside a pipeline job, which reaches the
endpoints GitLab opens to job tokens (releases, packages).

Without a token the client reads what is public, within gitlab.com's
lower anonymous rate limit; some reads, such as notes and commit statuses,
need a token even on a public project. The token is only sent to the
instance: a redirect or a next-page link elsewhere is refused, and
`downloadAsset` refuses a link that points elsewhere.

## Any endpoint

`call` takes the path under `/api/v4` with its query string, and the body as
JSON text. A project path in it is encoded by hand (`/` as `%2F`):

```jennifer
def labels as json.Value init gitlab.call($c, "GET", "/projects/me%2Fapp/labels", "");
gitlab.call($c, "POST", "/projects/me%2Fapp/labels", '{"name":"bug","color":"#ee0701"}');
```

`getAll` reads every page of a list, 100 entries a page. It follows
`X-Next-Page`, or for keyset pagination (`pagination=keyset` in the path)
the `Link` header. It refuses to go past `MAX_PAGES` pages (an error of kind
`"limit"`).

```jennifer
for (def hook in gitlab.getAll($c, "/projects/me%2Fapp/hooks")) {
    io.printf("%s\n", json.asString($hook, "/url"));
}
```

## GraphQL

`graphql` posts a query to `/api/graphql` with the same token, certificates
and timeout, and returns the whole reply; the result is under `/data`.
GraphQL errors become a `GitlabError` with the server's messages.

```jennifer
def r as json.Value init gitlab.graphql($c, '{ currentUser { username } }', json.map());
io.printf("%s\n", json.asString($r, "/data/currentUser/username"));
```

## Timeouts and retries

`withTimeout` sets each request's idle timeout, 30 s by default.
`withRetries` retries GETs answered 429 or 5xx, waiting as `Retry-After`
asks, up to 30 s at a time; writes are never retried. `graphql` retries
queries only, never mutations.
