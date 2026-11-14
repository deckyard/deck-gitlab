# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A client for the GitLab REST API (`/api/v4`), for gitlab.com or a
 * self-managed instance.
 *
 * A thin client: `call` reaches any endpoint, `getAll` follows the pages of
 * a list and `graphql` runs a GraphQL query. Typed verbs cover the daily
 * work: projects and groups, issues and notes, labels and milestones, merge
 * requests and approvals, releases and their links, branches, tags, files,
 * commits, commit statuses, pipelines, CI/CD variables, hooks and members.
 *
 * A project is its numeric id (`"278964"`) or its full path
 * (`"group/sub/name"`); the deck encodes the path. Issues and merge requests
 * are addressed by their `iid` within the project.
 *
 * Every failure is a `GitlabError` (kind `"gitlab"`) carrying the HTTP
 * `status` the instance answered, except that a listing past `MAX_PAGES`
 * pages or a reply over its size cap is kind `"limit"`, a deadline is kind
 * `"timeout"` and a cancelled task stays `"cancelled"`.
 *
 * @module gitlab
 * @see https://docs.gitlab.com/api/rest/
 * @example
 *   def c as gitlab.Client init gitlab.withToken(gitlab.client("gitlab.com"), $token);
 *   for (def i in gitlab.issues($c, "gitlab-org/cli", "opened")) {
 *       io.printf("#%d %s\n", $i.iid, $i.title);
 *   }
 */
use convert;
use encoding;
use json;
use lists;
use maps;
use regex;
use strings;
import "graphql.j" as gql;
import "http.j" as http;
import "uri.j" as uri;

/** The `kind` of every error of the deck's own. */
export def const ERROR_KIND as string init "gitlab";

/** The entries `getAll` and the list verbs ask for per page, GitLab's most. */
export def const PAGE_SIZE as int init 100;

/** The most pages a list follows before it refuses: 100000 entries. */
export def const MAX_PAGES as int init 1000;

/** Access level of a guest. */
export def const ACCESS_GUEST as int init 10;

/** Access level of a planner. */
export def const ACCESS_PLANNER as int init 15;

/** Access level of a reporter. */
export def const ACCESS_REPORTER as int init 20;

/** Access level of a developer. */
export def const ACCESS_DEVELOPER as int init 30;

/** Access level of a maintainer. */
export def const ACCESS_MAINTAINER as int init 40;

/** Access level of an owner. */
export def const ACCESS_OWNER as int init 50;

/** The events a project hook can fire on, as `createHook` takes them. */
export def const HOOK_EVENTS as list of string init [
    "push",
    "tag_push",
    "issues",
    "confidential_issues",
    "note",
    "confidential_note",
    "merge_requests",
    "job",
    "pipeline",
    "wiki_page",
    "deployment",
    "releases"
];

/** The states `setCommitStatus` can set. */
export def const STATUS_STATES as list of string init [
    "pending",
    "running",
    "success",
    "failed",
    "canceled",
    "skipped"
];

/**
 * A connection to one GitLab instance.
 *
 * @field url {string} `https://host` or `https://host/path`, without `/api/v4`
 * @field token {string} the token; "" for anonymous reads
 * @field authHeader {string} the header that carries it: `PRIVATE-TOKEN`,
 *   `Authorization` (OAuth, as `Bearer`) or `JOB-TOKEN`
 * @field tls {http.TlsOptions} certificate checking
 * @field timeoutMs {int} the idle timeout of each request; 0 for 30 s
 * @field retries {int} retries of a GET answered 429 or 5xx
 */
export def struct Client {
    url as string,
    token as string,
    authHeader as string,
    tls as http.TlsOptions,
    timeoutMs as int,
    retries as int
};

/**
 * A failed request or a refused value. Every error of kind `"gitlab"` is one,
 * so its fields are safe to read once the kind matches.
 *
 * @field kind {string} always `"gitlab"` (`ERROR_KIND`)
 * @field message {string} `gitlab: ` and what failed; for a refused request
 *   `gitlab: <verb> <path>: HTTP <status>: <reason>`
 * @field status {int} the HTTP status the instance answered (400, 401, 403,
 *   404, 409, 422, ...); 0 when no answer was read or for a local check
 */
export def struct GitlabError {
    kind as string,
    message as string,
    status as int
};

/**
 * An account.
 *
 * @field id {int} the user id
 * @field username {string} the user name
 * @field name {string} the display name
 * @field email {string} the e-mail address, as far as the token may see it
 * @field isAdmin {bool} whether it administers the instance, as far as the
 *   token may see it
 * @field state {string} e.g. `active` or `blocked`
 * @field webUrl {string} its page
 */
export def struct User {
    id as int,
    username as string,
    name as string,
    email as string,
    isAdmin as bool,
    state as string,
    webUrl as string
};

/**
 * A project.
 *
 * @field id {int} the project id
 * @field name {string} the name
 * @field path {string} the last segment of its path
 * @field fullPath {string} `group/sub/name`
 * @field namespace {string} the full path of its group or user
 * @field description {string} the description
 * @field visibility {string} `private`, `internal` or `public`
 * @field isArchived {bool} whether it is archived
 * @field defaultBranch {string} e.g. `main`, also in an empty repository
 *   (the branch a first push creates); "" when GitLab reports none
 * @field webUrl {string} its page
 * @field httpUrl {string} the HTTPS clone URL
 * @field sshUrl {string} the SSH clone URL
 * @field stars {int} the star count
 * @field forks {int} the fork count
 * @field openIssues {int} open issues; 0 when issues are off
 * @field lastActivity {string} RFC 3339
 * @field forkedFrom {string} the full path of the project it is a fork of;
 *   "" otherwise
 */
export def struct Project {
    id as int,
    name as string,
    path as string,
    fullPath as string,
    namespace as string,
    description as string,
    visibility as string,
    isArchived as bool,
    defaultBranch as string,
    webUrl as string,
    httpUrl as string,
    sshUrl as string,
    stars as int,
    forks as int,
    openIssues as int,
    lastActivity as string,
    forkedFrom as string
};

/**
 * A group or subgroup.
 *
 * @field id {int} the group id
 * @field name {string} the name
 * @field path {string} the last segment of its path
 * @field fullPath {string} `group/sub`
 * @field description {string} the description
 * @field visibility {string} `private`, `internal` or `public`
 * @field parentId {int} the parent group's id; 0 for a top-level group
 * @field webUrl {string} its page
 */
export def struct Group {
    id as int,
    name as string,
    path as string,
    fullPath as string,
    description as string,
    visibility as string,
    parentId as int,
    webUrl as string
};

/**
 * An issue.
 *
 * @field iid {int} the number within the project
 * @field id {int} the instance-wide id
 * @field title {string} the title
 * @field description {string} the text, Markdown
 * @field state {string} `opened` or `closed`
 * @field author {string} who opened it
 * @field labels {list of string} label names
 * @field assignees {list of string} assigned user names
 * @field milestone {string} the milestone's title; "" for none
 * @field notes {int} the count of notes by users
 * @field isConfidential {bool} whether it is confidential
 * @field created {string} RFC 3339
 * @field updated {string} RFC 3339
 * @field closed {string} RFC 3339; "" while open
 * @field webUrl {string} its page
 */
export def struct Issue {
    iid as int,
    id as int,
    title as string,
    description as string,
    state as string,
    author as string,
    labels as list of string,
    assignees as list of string,
    milestone as string,
    notes as int,
    isConfidential as bool,
    created as string,
    updated as string,
    closed as string,
    webUrl as string
};

/**
 * A note (comment) on an issue or merge request.
 *
 * @field id {int} the note id
 * @field author {string} who wrote it
 * @field body {string} the text, Markdown
 * @field isSystem {bool} whether GitLab wrote it for an event, such as a
 *   label change
 * @field created {string} RFC 3339
 * @field updated {string} RFC 3339
 */
export def struct Note {
    id as int,
    author as string,
    body as string,
    isSystem as bool,
    created as string,
    updated as string
};

/**
 * A merge request.
 *
 * @field iid {int} the number within the project
 * @field id {int} the instance-wide id
 * @field title {string} the title
 * @field description {string} the text, Markdown
 * @field state {string} `opened`, `closed`, `locked` or `merged`
 * @field author {string} who opened it
 * @field sourceBranch {string} the branch with the changes
 * @field targetBranch {string} the branch it merges into
 * @field sha {string} the commit at the head of the source branch
 * @field isDraft {bool} whether it is a draft
 * @field mergeStatus {string} GitLab's `detailed_merge_status`, e.g.
 *   `mergeable`, `checking`, `conflict`, `not_approved`, `not_open`
 * @field mergeable {bool} whether `mergeStatus` is `mergeable`
 * @field merged {bool} whether it is merged
 * @field mergeSha {string} the merge commit; "" until merged or for a
 *   fast-forward merge
 * @field squashSha {string} the squash commit; "" without one
 * @field webUrl {string} its page
 * @field created {string} RFC 3339
 * @field mergedAt {string} RFC 3339; "" until merged
 */
export def struct MergeRequest {
    iid as int,
    id as int,
    title as string,
    description as string,
    state as string,
    author as string,
    sourceBranch as string,
    targetBranch as string,
    sha as string,
    isDraft as bool,
    mergeStatus as string,
    mergeable as bool,
    merged as bool,
    mergeSha as string,
    squashSha as string,
    webUrl as string,
    created as string,
    mergedAt as string
};

/**
 * The approval state of a merge request.
 *
 * @field approved {bool} whether it counts as approved
 * @field approvedBy {list of string} the user names that approved it
 * @field required {int} approvals its rules require; 0 on GitLab Free
 * @field left {int} approvals still missing; 0 on GitLab Free
 */
export def struct Approvals {
    approved as bool,
    approvedBy as list of string,
    required as int,
    left as int
};

/**
 * A file a merge request changes.
 *
 * @field oldPath {string} the path before
 * @field newPath {string} the path after
 * @field isNew {bool} whether it adds the file
 * @field isRenamed {bool} whether it renames the file
 * @field isDeleted {bool} whether it deletes the file
 * @field diff {string} the unified diff of the file; "" when GitLab left it
 *   out as too large
 */
export def struct ChangedFile {
    oldPath as string,
    newPath as string,
    isNew as bool,
    isRenamed as bool,
    isDeleted as bool,
    diff as string
};

/**
 * A link attached to a release, GitLab's release asset.
 *
 * @field id {int} the link id
 * @field name {string} the name
 * @field url {string} where it points
 * @field directAssetUrl {string} its permanent URL under the release page
 * @field linkType {string} `other`, `runbook`, `image` or `package`
 */
export def struct ReleaseLink {
    id as int,
    name as string,
    url as string,
    directAssetUrl as string,
    linkType as string
};

/**
 * A release.
 *
 * @field tag {string} the tag it is for; also its key
 * @field name {string} the title
 * @field description {string} the notes, Markdown
 * @field author {string} who created it
 * @field commitSha {string} the tagged commit
 * @field created {string} RFC 3339
 * @field released {string} RFC 3339; may lie in the future
 * @field isUpcoming {bool} whether `released` is in the future
 * @field webUrl {string} its page
 * @field links {list of ReleaseLink} the attached links
 * @field sources {list of string} the URLs of the source archives
 */
export def struct Release {
    tag as string,
    name as string,
    description as string,
    author as string,
    commitSha as string,
    created as string,
    released as string,
    isUpcoming as bool,
    webUrl as string,
    links as list of ReleaseLink,
    sources as list of string
};

/**
 * A branch.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field isProtected {bool} whether a protection rule covers it
 * @field isDefault {bool} whether it is the default branch
 * @field isMerged {bool} whether it is merged into the default branch
 */
export def struct Branch {
    name as string,
    sha as string,
    isProtected as bool,
    isDefault as bool,
    isMerged as bool
};

/**
 * A tag.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field message {string} the annotation; "" for a lightweight tag
 * @field isProtected {bool} whether a protection rule covers it
 */
export def struct Tag {
    name as string,
    sha as string,
    message as string,
    isProtected as bool
};

/**
 * A status set on a commit, by a pipeline job or an outside CI system.
 *
 * @field id {int} the status id
 * @field name {string} which check it is, e.g. `ci/build`
 * @field status {string} `pending`, `running`, `success`, `failed`,
 *   `canceled`, `skipped`, or another state a pipeline job has
 * @field description {string} a short text
 * @field targetUrl {string} where the details are
 * @field author {string} who set it
 * @field ref {string} the branch or tag it was set for
 * @field created {string} RFC 3339
 */
export def struct CommitStatus {
    id as int,
    name as string,
    status as string,
    description as string,
    targetUrl as string,
    author as string,
    ref as string,
    created as string
};

/**
 * The statuses of a commit, combined.
 *
 * @field status {string} the worst state of the latest status per name;
 *   "" when there is none
 * @field statuses {list of CommitStatus} the latest status per name
 */
export def struct CombinedStatus {
    status as string,
    statuses as list of CommitStatus
};

/**
 * A commit.
 *
 * @field sha {string} the commit SHA
 * @field title {string} the first line of the message
 * @field message {string} the commit message
 * @field author {string} the author's name, as Git records it
 * @field authorEmail {string} the author's e-mail address
 * @field date {string} the author date, RFC 3339
 * @field parents {list of string} the parent SHAs
 * @field webUrl {string} its page
 */
export def struct Commit {
    sha as string,
    title as string,
    message as string,
    author as string,
    authorEmail as string,
    date as string,
    parents as list of string,
    webUrl as string
};

/**
 * A label of a project.
 *
 * @field id {int} the label id
 * @field name {string} the name, e.g. `bug` or `scope::ui`
 * @field color {string} the colour, e.g. `#ee0701`
 * @field description {string} the description
 */
export def struct Label {
    id as int,
    name as string,
    color as string,
    description as string
};

/**
 * A milestone of a project.
 *
 * @field id {int} the milestone id, which `setMilestone` takes
 * @field iid {int} the number within the project
 * @field title {string} the title
 * @field description {string} the description
 * @field state {string} `active` or `closed`
 * @field dueDate {string} `YYYY-MM-DD`; "" without one
 * @field startDate {string} `YYYY-MM-DD`; "" without one
 * @field webUrl {string} its page
 */
export def struct Milestone {
    id as int,
    iid as int,
    title as string,
    description as string,
    state as string,
    dueDate as string,
    startDate as string,
    webUrl as string
};

/**
 * A hook of a project.
 *
 * @field id {int} the hook id
 * @field url {string} where it posts to
 * @field events {list of string} the events it fires on, from `HOOK_EVENTS`
 * @field sslVerification {bool} whether it checks the receiver's certificate
 */
export def struct Hook {
    id as int,
    url as string,
    events as list of string,
    sslVerification as bool
};

/**
 * An entry of a directory in a repository.
 *
 * @field name {string} the name
 * @field path {string} the path from the repository root
 * @field type {string} `blob` (a file), `tree` (a directory) or `commit`
 *   (a submodule)
 * @field mode {string} the Git file mode, e.g. `100644`
 * @field sha {string} the blob or tree SHA
 */
export def struct Entry {
    name as string,
    path as string,
    type as string,
    mode as string,
    sha as string
};

/**
 * A CI/CD pipeline.
 *
 * @field id {int} the pipeline id
 * @field iid {int} the number within the project
 * @field ref {string} the branch or tag it ran for
 * @field sha {string} the commit
 * @field status {string} e.g. `created`, `pending`, `running`, `success`,
 *   `failed`, `canceled`, `skipped`, `manual`
 * @field source {string} what started it, e.g. `push`, `web`, `api`,
 *   `trigger`, `schedule`
 * @field webUrl {string} its page
 * @field created {string} RFC 3339
 * @field updated {string} RFC 3339
 */
export def struct Pipeline {
    id as int,
    iid as int,
    ref as string,
    sha as string,
    status as string,
    source as string,
    webUrl as string,
    created as string,
    updated as string
};

/**
 * A member of a project.
 *
 * @field id {int} the user id
 * @field username {string} the user name
 * @field name {string} the display name
 * @field accessLevel {int} one of the `ACCESS_*` levels
 * @field expiresAt {string} `YYYY-MM-DD`; "" when it does not expire
 */
export def struct Member {
    id as int,
    username as string,
    name as string,
    accessLevel as int,
    expiresAt as string
};

# A path segment of a group, user or project as GitLab allows it.
def const NAME_PATTERN as string init '^[A-Za-z0-9_][A-Za-z0-9_.-]*$';

# A numeric id.
def const ID_PATTERN as string init '^[1-9][0-9]*$';

# How much of a string an error message repeats.
def const SHOWN as int init 60;

# How much of the server's reason for a refusal an error message repeats.
def const REASON as int init 200;

# The idle timeout a `timeoutMs` of 0 stands for, as `http.send` has it.
def const DEFAULT_TIMEOUT_MS as int init 30000;

# The redirects a byte download follows.
def const MAX_REDIRECTS as int init 5;

# The kinds an `http` failure keeps: the generic ones of the error table.
def const GENERIC_KINDS as list of string init ["limit", "timeout", "closed"];

/**
 * Throw the GitlabError of a local check.
 *
 * @param message {string} what is wrong, without the `gitlab: ` prefix
 */
func fail(message as string) {
    failStatus($message, 0);
}

/**
 * Throw the GitlabError of a refused request, with its status.
 *
 * @param message {string} what failed, without the `gitlab: ` prefix
 * @param status {int} the HTTP status; 0 for none
 */
func failStatus(message as string, status as int) {
    throw GitlabError{kind: ERROR_KIND, message: "gitlab: " + $message, status: $status};
}

/**
 * Throw the error of a request that got no usable answer. A cancelled task
 * stays as it is; a reached cap, a deadline or a closed connection keeps its
 * kind (`"limit"`, `"timeout"`, `"closed"`) with the request named; anything
 * else is a GitlabError.
 *
 * @param what {string} the request, `<verb> <path>`
 * @param e {Error} the caught error
 */
func failTransport(what as string, e as Error) {
    if ($e.kind == "cancelled") {
        throw $e;
    }
    if (lists.contains(GENERIC_KINDS, $e.kind)) {
        throw Error{kind: $e.kind, message: "gitlab: " + $what + ": " + $e.message};
    }
    fail($what + ": " + plain($e.message, REASON));
}

/**
 * A string fit for an error message: cut to `most` characters, with
 * anything but printable ASCII as `?`, so a message stays one line and
 * carries no terminal escape into a log.
 *
 * @param text {string} a caller's or the server's string
 * @param most {int} the characters kept
 * @return {string} the text
 */
func plain(text as string, most as int) {
    def cut as string init $text;
    def more as string init "";
    if (len($text) > $most) {
        $cut = strings.substring($text, 0, $most);
        $more = "...";
    }
    return regex.replace("[^ -~]", $cut, "?") + $more;
}

/**
 * A string as an error message quotes it: `plain`, cut to `SHOWN`.
 *
 * @param text {string} a caller's or the server's string
 * @return {string} the text in double quotes
 */
func shown(text as string) {
    return "\"" + plain($text, SHOWN) + "\"";
}

/**
 * The base URL for a host name or URL. A bare host gets `https://`; a
 * trailing slash and a trailing `/api/v4` are dropped.
 *
 * @param address {string} `gitlab.com`, `git.example.com:8443` or a full URL
 * @return {string} `https://host[:port][/path]`
 */
func baseUrl(address as string) {
    def url as string init strings.trim($address);
    if ($url == "") {
        fail("the host is empty");
    }
    if (regex.matches('[\s\x00-\x1f\x7f?#@]', $url)) {
        fail("an address holds no spaces, ?, # or @, got " + shown($address));
    }
    while (strings.endsWith($url, "/")) {
        $url = strings.substring($url, 0, len($url) - 1);
    }
    if (strings.endsWith($url, "/api/v4")) {
        $url = strings.substring($url, 0, len($url) - len("/api/v4"));
    }
    if (not strings.contains($url, "://")) {
        $url = "https://" + $url;
    }
    if (not regex.matches('^https?://[^/]+(/[^/]+)*$', $url)) {
        fail("an address is a host or an http(s) URL, got " + shown($address));
    }
    return $url;
}

/**
 * A client for an instance, without a token.
 *
 * @param address {string} host name, `host:port` or a full URL; an instance
 *   below a path, such as `https://example.com/gitlab`, keeps the path
 * @return {Client} the client; full certificate checking
 * @throws {GitlabError} kind `"gitlab"` when the address is empty or not a
 *   host or http(s) URL
 * @example
 *   def c as gitlab.Client init gitlab.client("gitlab.com");
 */
export func client(address as string) {
    def c as Client;
    $c.url = baseUrl($address);
    $c.authHeader = "PRIVATE-TOKEN";
    return $c;
}

/**
 * Refuse a token that would break a header.
 *
 * @param token {string} the token
 * @return {string} the token
 */
func checkToken(token as string) {
    if ($token == "" or regex.matches('[\s\x00-\x1f\x7f]', $token)) {
        fail("a token is not empty and holds no spaces or control characters");
    }
    return $token;
}

/**
 * Authenticate with a personal, project or group access token, sent as
 * `PRIVATE-TOKEN`. Give it only the scopes the program needs.
 *
 * @param c {Client} the client
 * @param token {string} the token
 * @return {Client} the changed copy
 * @throws {GitlabError} kind `"gitlab"` when the token is empty or holds
 *   spaces or control characters
 */
export func withToken(c as Client, token as string) {
    $c.token = checkToken($token);
    $c.authHeader = "PRIVATE-TOKEN";
    return $c;
}

/**
 * Authenticate with an OAuth 2 access token, sent as
 * `Authorization: Bearer`.
 *
 * @param c {Client} the client
 * @param token {string} the access token
 * @return {Client} the changed copy
 * @throws {GitlabError} kind `"gitlab"` as `withToken`
 */
export func withBearer(c as Client, token as string) {
    $c.token = checkToken($token);
    $c.authHeader = "Authorization";
    return $c;
}

/**
 * Authenticate with a CI/CD job token (`CI_JOB_TOKEN`), sent as `JOB-TOKEN`.
 * It reaches only the endpoints GitLab opens to job tokens, such as
 * releases and the package registry.
 *
 * @param c {Client} the client
 * @param token {string} the job token
 * @return {Client} the changed copy
 * @throws {GitlabError} kind `"gitlab"` as `withToken`
 */
export func withJobToken(c as Client, token as string) {
    $c.token = checkToken($token);
    $c.authHeader = "JOB-TOKEN";
    return $c;
}

/**
 * Trust a certificate (PEM) in addition to the system's, for an instance
 * with a private CA or a self-signed certificate.
 *
 * @param c {Client} the client
 * @param pem {bytes} the certificate
 * @return {Client} the changed copy
 */
export func withCaCert(c as Client, pem as bytes) {
    $c.tls.caCert = $pem;
    $c.tls.skipVerify = false;
    return $c;
}

/**
 * Accept any certificate. The connection is still encrypted but no longer
 * authenticated; prefer `withCaCert`.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withInsecure(c as Client) {
    $c.tls.skipVerify = true;
    return $c;
}

/**
 * Set the idle timeout of each request.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the default, 30 s
 * @return {Client} the changed copy
 * @throws {GitlabError} kind `"gitlab"` for a negative value
 */
export func withTimeout(c as Client, ms as int) {
    if ($ms < 0) {
        fail("a timeout is 0 or more milliseconds");
    }
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * Retry a GET answered 429 or 5xx, waiting as `Retry-After` asks (at most
 * 30 s a time). Writes are never retried: they need not be idempotent.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 for none
 * @return {Client} the changed copy
 * @throws {GitlabError} kind `"gitlab"` for a negative count
 */
export func withRetries(c as Client, n as int) {
    if ($n < 0) {
        fail("a retry count is 0 or more");
    }
    $c.retries = $n;
    return $c;
}

/**
 * Refuse an API path that would not address what it says.
 *
 * @param path {string} the path under `/api/v4`, query string allowed
 */
func ensurePath(path as string) {
    if (not strings.startsWith($path, "/")) {
        fail("an API path starts with /, got " + shown($path));
    }
    def route as string init $path;
    if (strings.contains($route, "?")) {
        $route = strings.substring($route, 0, strings.indexOf($route, "?"));
    }
    if (strings.contains($route, "//") or strings.contains($path, "#") or
        regex.matches('[\x00-\x20\x7f]', $path)) {
        fail("an API path holds no //, # or spaces: " + shown($path));
    }
    for (def segment in strings.split($route, "/")) {
        if ($segment == "." or $segment == "..") {
            fail("an API path has no . or .. segments: " + shown($path));
        }
    }
}

/**
 * Check a `/`-separated path of names: a group, or a project's full path.
 *
 * @param text {string} the path
 * @param least {int} the fewest segments it has
 * @return {bool} whether it is one
 */
func isNamePath(text as string, least as int) {
    def parts as list of string init strings.split($text, "/");
    if (len($parts) < $least) {
        return false;
    }
    for (def part in $parts) {
        if (not regex.matches(NAME_PATTERN, $part)) {
            return false;
        }
    }
    return true;
}

/**
 * A project for a URL: its id as given, or its full path checked and
 * encoded as one segment (`group%2Fsub%2Fname`).
 *
 * @param project {string} `"42"` or `group/sub/name`
 * @return {string} the segment
 */
func projectId(project as string) {
    if (regex.matches(ID_PATTERN, $project)) {
        return $project;
    }
    if (not isNamePath($project, 2)) {
        fail("a project is a numeric id or namespace/name, got " + shown($project));
    }
    return strings.replace($project, "/", "%2F");
}

/**
 * The API path of a project.
 *
 * @param project {string} `"42"` or `group/sub/name`
 * @return {string} `/projects/<id>`
 */
func projectPath(project as string) {
    return "/projects/" + projectId($project);
}

/**
 * The API path of a group.
 *
 * @param group {string} `"42"` or `group/sub`
 * @return {string} `/groups/<id>`
 */
func groupPath(group as string) {
    if (regex.matches(ID_PATTERN, $group)) {
        return "/groups/" + $group;
    }
    if (not isNamePath($group, 1)) {
        fail("a group is a numeric id or a path such as group/sub, got " + shown($group));
    }
    return "/groups/" + strings.replace($group, "/", "%2F");
}

/**
 * A user name, checked.
 *
 * @param name {string} the user name
 * @return {string} the name
 */
func checkUser(name as string) {
    if (not regex.matches(NAME_PATTERN, $name)) {
        fail("a user name is letters, digits, _, . and -, got " + shown($name));
    }
    return $name;
}

/**
 * A ref, tag or file path checked and encoded as one URL segment or query
 * value: every `/` becomes `%2F`, as GitLab wants it.
 *
 * @param text {string} e.g. `docs/a b.md` or `release/1.0`
 * @param what {string} what it is, for the error message
 * @return {string} the encoded text
 */
func encoded(text as string, what as string) {
    if ($text == "" or regex.matches('[\x00-\x1f\x7f]', $text)) {
        fail("a " + $what + " is not empty and holds no control characters, got " + shown($text));
    }
    for (def part in strings.split($text, "/")) {
        if ($part == "" or $part == "." or $part == "..") {
            fail("a " + $what + " has no empty, . or .. segments, got " + shown($text));
        }
    }
    return uri.encode($text);
}

/**
 * The headers that carry the credential.
 *
 * @param c {Client} the client
 * @return {map of string to string} the headers
 */
func authHeaders(c as Client) {
    def headers as map of string to string init {"Accept": "application/json"};
    if ($c.token != "") {
        if ($c.authHeader == "Authorization") {
            $headers["Authorization"] = "Bearer " + $c.token;
        } else {
            $headers[$c.authHeader] = $c.token;
        }
    }
    return $headers;
}

/**
 * The idle timeout for the `http` calls that take it directly, where 0
 * would mean no timeout at all.
 *
 * @param c {Client} the client
 * @return {int} milliseconds
 */
func idleMs(c as Client) {
    if ($c.timeoutMs == 0) {
        return DEFAULT_TIMEOUT_MS;
    }
    return $c.timeoutMs;
}

/**
 * Send a request and return the response, a non-2xx refused. A GET or HEAD
 * follows a redirect that stays under the client's own API (GitLab answers
 * `releases/permalink/latest` with one); any other redirect is refused, so
 * the token never leaves the instance.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param path {string} the path under `/api/v4`
 * @param body {string} JSON, or "" for none
 * @return {http.Response} the response
 */
func exchange(c as Client, method as string, path as string, body as string) {
    def verb as string init strings.upper($method);
    if (not lists.contains(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"], $verb)) {
        fail("unsupported method " + shown($method));
    }
    ensurePath($path);
    def headers as map of string to string init authHeaders($c);
    if ($body != "") {
        $headers["Content-Type"] = "application/json";
    }
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    def reads as bool init $verb == "GET" or $verb == "HEAD";
    if ($reads) {
        $o.maxRetries = $c.retries;
        $o.backoffMs = 500;
    }
    def current as string init $path;
    def hops as int init 0;
    while (true) {
        def r as http.Response;
        try {
            $r = http.send($verb, $c.url + "/api/v4" + $current, $headers, $body, $o);
        } catch (e) {
            failTransport($verb + " " + $path, $e);
        }
        def location as string init strings.trim(http.header($r, "Location"));
        if ($reads and lists.contains([301, 302, 303, 307, 308], $r.status) and $location != "") {
            if ($hops >= MAX_REDIRECTS) {
                throw Error{
                    kind: "limit",
                    message: "gitlab: " + $verb + " " + $path + ": more than " +
                        convert.toString(MAX_REDIRECTS) + " redirects"
                };
            }
            $current = apiPathOf($c, $c.url + "/api/v4" + $current, $location, $verb + " " + $path);
            $hops = $hops + 1;
            continue;
        }
        if ($r.status < 200 or $r.status >= 300) {
            failStatus(
                $verb + " " + $path + ": " + failureText($r.status, $r.statusText, $r.body),
                $r.status);
        }
        return $r;
    }
    return http.Response{status: 0, statusText: "", headers: {}, body: ""};
}

/**
 * The path under `/api/v4` a redirect or next-page link points to, refused
 * unless it lies under the client's own API.
 *
 * @param c {Client} the client
 * @param from {string} the absolute URL that answered
 * @param target {string} the `Location` or link, absolute or from the root
 * @param what {string} the request, for the error message
 * @return {string} the path, starting with `/`
 */
func apiPathOf(c as Client, from as string, target as string, what as string) {
    def url as string init resolved($from, $target);
    def api as string init $c.url + "/api/v4/";
    if (originOf($url) != originOf($c.url) or
        not strings.startsWith(strings.lower($url), strings.lower($api))) {
        fail($what + ": refused to follow " + shown($target) + " off " + $c.url + "/api/v4");
    }
    def rest as string init strings.substring($url, len($api) - 1);
    ensurePath($rest);
    return $rest;
}

/**
 * The text of an error document's `message`: a string, a list of strings,
 * or a map of field to its messages (`{"name": ["is taken"]}`).
 *
 * @param doc {json.Value} the error document
 * @param ptr {string} the pointer of the value
 * @return {string} the text; "" when there is none
 */
func messageText(doc as json.Value, ptr as string) {
    def kind as string init kindAt($doc, $ptr);
    if ($kind == "string") {
        return strings.trim(json.asString($doc, $ptr));
    }
    def parts as list of string init [];
    if ($kind == "list") {
        for (def p in items($doc, $ptr)) {
            def item as string init messageText($doc, $p);
            if ($item != "") {
                $parts[] = $item;
            }
        }
        return strings.join($parts, ", ");
    }
    if ($kind == "map") {
        for (def key in json.keys($doc, $ptr)) {
            def item as string init messageText($doc, $ptr + "/" + pointerKey($key));
            if ($item == "") {
                continue;
            }
            if ($key == "base" or $key == "error") {
                $parts[] = $item;
            } else {
                $parts[] = $key + " " + $item;
            }
        }
        return strings.join($parts, "; ");
    }
    return "";
}

/**
 * A map key as a JSON pointer token.
 *
 * @param key {string} the key
 * @return {string} the key with `~` and `/` escaped
 */
func pointerKey(key as string) {
    return strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
}

/**
 * Explain a refused request: GitLab's `message` (a string, or the messages
 * per field of a validation failure), or an OAuth `error` with its
 * `error_description`, cut to `REASON` characters of printable ASCII.
 *
 * @param status {int} the HTTP status
 * @param statusText {string} the reason phrase
 * @param body {string} the body
 * @return {string} `HTTP <status>: <reason>`
 */
func failureText(status as int, statusText as string, body as string) {
    def code as string init convert.toString($status);
    def text as string init "HTTP " + $code;
    def reason as string init strings.trim($statusText);
    def doc as json.Value init json.decode("null");
    try {
        $doc = json.decode($body);
    } catch (e) {
        $doc = json.decode("null");
    }
    if (json.typeOf($doc) == "map") {
        def said as string init messageText($doc, "/message");
        if ($said == "") {
            $said = messageText($doc, "/error");
            def more as string init messageText($doc, "/error_description");
            if ($said != "" and $more != "") {
                $said = $said + ": " + $more;
            }
        }
        # GitLab repeats the status in front: "404 Project Not Found".
        if (strings.startsWith($said, $code + " ")) {
            $said = strings.trim(strings.substring($said, len($code) + 1));
        }
        if ($said != "") {
            $reason = $said;
        }
    }
    if ($reason != "") {
        $text = $text + ": " + plain($reason, REASON);
    }
    return $text;
}

/**
 * Decode a reply body.
 *
 * @param body {string} the body
 * @param what {string} the request, for the error message
 * @return {json.Value} the document; JSON `null` for an empty body
 */
func decoded(body as string, what as string) {
    if (strings.trim($body) == "") {
        return json.decode("null");
    }
    try {
        return json.decode($body);
    } catch (e) {
        fail($what + ": the reply is not JSON");
    }
    return json.decode("null");
}

/**
 * Call any endpoint.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PUT`, `PATCH` or `DELETE`
 * @param path {string} the path under `/api/v4`, query string included, e.g.
 *   `/projects/gitlab-org%2Fcli/labels?per_page=10`; a project path in it
 *   is encoded by the caller
 * @param body {string} the JSON body; "" for none
 * @return {json.Value} the reply; JSON `null` when it is empty
 * @throws {GitlabError} kind `"gitlab"` on a bad path, a network failure or a
 *   reply that is not 2xx; the message names the status and GitLab's reason
 * @example
 *   def labels as json.Value init gitlab.call($c, "GET", "/projects/42/labels", "");
 */
export func call(c as Client, method as string, path as string, body as string) {
    # HEAD stays internal (writeFile's existence check): it has no JSON reply
    if (not lists.contains(["GET", "POST", "PUT", "PATCH", "DELETE"], strings.upper($method))) {
        fail("unsupported method " + shown($method));
    }
    def r as http.Response init exchange($c, $method, $path, $body);
    return decoded($r.body, strings.upper($method) + " " + $path);
}

/**
 * The origin of an absolute URL, `scheme://host[:port]`, lower case.
 *
 * @param url {string} the URL
 * @return {string} the origin; "" when it is not an absolute URL
 */
func originOf(url as string) {
    def m as list of regex.Match init regex.findAll('^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*', $url);
    if (len($m) == 0) {
        return "";
    }
    return strings.lower($m[0].text);
}

/**
 * The `rel="next"` target of a `Link` header.
 *
 * @param link {string} the header
 * @return {string} the URL; "" when there is none
 */
func nextLink(link as string) {
    for (def part in strings.split($link, ",")) {
        def m as list of regex.Match init regex.findAll('^\s*<([^>]*)>\s*;(.*)$', $part);
        if (len($m) == 1 and regex.matches('(^|;)\s*rel="?next"?\s*(;|$)', $m[0].groups[1])) {
            return $m[0].groups[0];
        }
    }
    return "";
}

/**
 * The request of the next page: `X-Next-Page` for offset pagination, or the
 * `rel="next"` link of keyset pagination, which must lie under the
 * client's own API.
 *
 * @param c {Client} the client
 * @param r {http.Response} the page
 * @param path {string} the first page's path, without `page`
 * @param sep {string} `?` or `&`, whatever joins a parameter to `path`
 * @return {string} the next path under `/api/v4`; "" after the last page
 */
func nextPage(c as Client, r as http.Response, path as string, sep as string) {
    if (maps.has($r.headers, "x-next-page")) {
        def next as string init strings.trim($r.headers["x-next-page"]);
        if ($next == "") {
            return "";
        }
        if (not regex.matches(ID_PATTERN, $next)) {
            fail("GET " + $path + ": X-Next-Page is not a page number: " + shown($next));
        }
        return $path + $sep + "per_page=" + convert.toString(PAGE_SIZE) + "&page=" + $next;
    }
    def link as string init nextLink(http.header($r, "Link"));
    if ($link == "") {
        return "";
    }
    return apiPathOf($c, $c.url + "/api/v4" + $path, $link, "GET " + $path);
}

/**
 * GET every page of a list endpoint, `PAGE_SIZE` entries a page. Follows
 * `X-Next-Page`, or for keyset pagination (`pagination=keyset` in the path)
 * the `Link` header's next page, which must be on the client's instance.
 *
 * @param c {Client} the client
 * @param path {string} the path under `/api/v4`, query string allowed;
 *   `per_page` and `page` are added
 * @return {list of json.Value} the entries
 * @throws {GitlabError} kind `"gitlab"` as `call`, when an answer is not a
 *   list, or when the next page lies elsewhere
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func getAll(c as Client, path as string) {
    def out as list of json.Value init [];
    def sep as string init "?";
    if (strings.contains($path, "?")) {
        $sep = "&";
    }
    def url as string init $path + $sep + "per_page=" + convert.toString(PAGE_SIZE);
    def pages as int init 0;
    while ($url != "") {
        if ($pages >= MAX_PAGES) {
            throw Error{
                kind: "limit",
                message: "gitlab: GET " + $path + ": more than " + convert.toString(MAX_PAGES) +
                    " pages"
            };
        }
        def r as http.Response init exchange($c, "GET", $url, "");
        def doc as json.Value init decoded($r.body, "GET " + $path);
        if (json.typeOf($doc) != "list") {
            fail("GET " + $path + ": the reply is not a list");
        }
        def n as int init json.length($doc);
        def i as int init 0;
        while ($i < $n) {
            $out[] = json.get($doc, "/" + convert.toString($i));
            $i = $i + 1;
        }
        $pages = $pages + 1;
        $url = "";
        if ($n > 0) {
            $url = nextPage($c, $r, $path, $sep);
        }
    }
    return $out;
}

/**
 * Run a GraphQL query or mutation against `/api/graphql`, with the
 * client's token, certificates, timeout and retries (queries only).
 *
 * @param c {Client} the client
 * @param query {string} the GraphQL document
 * @param variables {json.Value} the variables, an object; `json.map()` for
 *   none
 * @return {json.Value} the whole reply; the result is under `/data`
 * @throws {GitlabError} kind `"gitlab"` when GitLab reports GraphQL errors or
 *   refuses the request; `status` is the HTTP status
 * @example
 *   def r as json.Value init gitlab.graphql($c, '{ currentUser { username } }', json.map());
 *   io.printf("%s\n", json.asString($r, "/data/currentUser/username"));
 */
export func graphql(c as Client, query as string, variables as json.Value) {
    if (strings.trim($query) == "") {
        fail("a GraphQL query is not empty");
    }
    def g as gql.Client init gql.client($c.url + "/api/graphql");
    def headers as map of string to string init authHeaders($c);
    for (def name in lists.sort(maps.keys($headers))) {
        if ($name != "Accept") {
            $g = gql.header($g, $name, $headers[$name]);
        }
    }
    if ($c.tls.skipVerify) {
        $g = gql.insecure($g);
    } elseif (len($c.tls.caCert) > 0) {
        $g = gql.withCA($g, $c.tls.caCert);
    }
    $g = gql.withTimeout($g, $c.timeoutMs);
    $g = gql.withBackoff(gql.withRetries($g, $c.retries), 500);
    try {
        return gql.query($g, $query, $variables);
    } catch (e) {
        if ($e.kind == "graphql") {
            def said as string init $e.message;
            if (strings.startsWith($said, "graphql: ")) {
                $said = strings.substring($said, len("graphql: "));
            }
            failStatus("POST /api/graphql: " + plain($said, REASON), $e.status);
        }
        def err as Error init $e;
        failTransport("POST /api/graphql", $err);
    }
    return json.decode("null");
}

/**
 * Build a JSON object from text fields and flags.
 *
 * @param fields {map of string to string} string members; "" values left out
 * @param flags {map of string to bool} boolean members
 * @return {json.Value} the object
 */
func objectOf(fields as map of string to string, flags as map of string to bool) {
    def doc as json.Value init json.map();
    for (def key in lists.sort(maps.keys($fields))) {
        if ($fields[$key] != "") {
            $doc = json.set($doc, "/" + $key, $fields[$key]);
        }
    }
    for (def key in lists.sort(maps.keys($flags))) {
        $doc = json.set($doc, "/" + $key, $flags[$key]);
    }
    return $doc;
}

/**
 * Build a JSON object from text fields and flags, as text.
 *
 * @param fields {map of string to string} string members; "" values left out
 * @param flags {map of string to bool} boolean members
 * @return {string} the JSON
 */
func bodyOf(fields as map of string to string, flags as map of string to bool) {
    return json.encode(objectOf($fields, $flags));
}

/**
 * The version of the instance. GitLab answers it only with a token.
 *
 * @param c {Client} the client
 * @return {string} e.g. `19.5.5`
 * @throws {GitlabError} kind `"gitlab"` without a token (HTTP 401), or as `call`
 */
export func version(c as Client) {
    return field(call($c, "GET", "/version", ""), "/version");
}

/**
 * An account from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the account's pointer; "" for the root
 * @return {User} the account
 */
func userFrom(d as json.Value, p as string) {
    return User{
        id: numberAt($d, $p + "/id"),
        username: field($d, $p + "/username"),
        name: field($d, $p + "/name"),
        email: field($d, $p + "/email"),
        isAdmin: flag($d, $p + "/is_admin"),
        state: field($d, $p + "/state"),
        webUrl: field($d, $p + "/web_url")
    };
}

/**
 * The account the token belongs to.
 *
 * @param c {Client} the client
 * @return {User} the account
 * @throws {GitlabError} kind `"gitlab"` without a valid token (HTTP 401), or as
 *   `call`
 */
export func currentUser(c as Client) {
    return userFrom(call($c, "GET", "/user", ""), "");
}

/**
 * An account by its user name.
 *
 * @param c {Client} the client
 * @param username {string} the user name
 * @return {User} the account
 * @throws {GitlabError} kind `"gitlab"` on a bad name, when there is no such
 *   user (status 0), or as `call`
 */
export func user(c as Client, username as string) {
    def d as json.Value init call(
        $c,
        "GET",
        "/users?username=" + uri.encode(checkUser($username)),
        "");
    if (kindAt($d, "") != "list" or json.length($d) == 0) {
        fail("there is no user " + shown($username));
    }
    return userFrom($d, "/0");
}

/**
 * The ids of user names, for the fields that take ids.
 *
 * @param c {Client} the client
 * @param names {list of string} the user names
 * @return {json.Value} a JSON list of the ids
 */
func userIds(c as Client, names as list of string) {
    def ids as json.Value init json.list();
    for (def name in $names) {
        $ids = json.append($ids, "", user($c, $name).id);
    }
    return $ids;
}

/**
 * A project from a reply.
 *
 * @param d {json.Value} the document
 * @return {Project} the project
 */
func projectFrom(d as json.Value) {
    return Project{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        path: field($d, "/path"),
        fullPath: field($d, "/path_with_namespace"),
        namespace: field($d, "/namespace/full_path"),
        description: field($d, "/description"),
        visibility: field($d, "/visibility"),
        isArchived: flag($d, "/archived"),
        defaultBranch: field($d, "/default_branch"),
        webUrl: field($d, "/web_url"),
        httpUrl: field($d, "/http_url_to_repo"),
        sshUrl: field($d, "/ssh_url_to_repo"),
        stars: numberAt($d, "/star_count"),
        forks: numberAt($d, "/forks_count"),
        openIssues: numberAt($d, "/open_issues_count"),
        lastActivity: field($d, "/last_activity_at"),
        forkedFrom: field($d, "/forked_from_project/path_with_namespace")
    };
}

/**
 * The projects of a list endpoint.
 *
 * @param c {Client} the client
 * @param path {string} the endpoint
 * @return {list of Project} the projects
 */
func projectsAt(c as Client, path as string) {
    def out as list of Project init [];
    for (def d in getAll($c, $path)) {
        $out[] = projectFrom($d);
    }
    return $out;
}

/**
 * One project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path, e.g. `group/sub/name`
 * @return {Project} the project
 * @throws {GitlabError} kind `"gitlab"` when it does not exist or is hidden from
 *   the token (HTTP 404), or as `call`
 */
export func project(c as Client, project as string) {
    return projectFrom(call($c, "GET", projectPath($project), ""));
}

/**
 * The projects a user owns, as far as the token may see them.
 *
 * @param c {Client} the client
 * @param username {string} the user name
 * @return {list of Project} the projects
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func userProjects(c as Client, username as string) {
    return projectsAt($c, "/users/" + checkUser($username) + "/projects");
}

/**
 * The projects of a group, as far as the token may see them.
 *
 * @param c {Client} the client
 * @param group {string} the id or full path, e.g. `group/sub`
 * @param includeSubgroups {bool} also the projects of its subgroups
 * @return {list of Project} the projects
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func groupProjects(c as Client, group as string, includeSubgroups as bool) {
    def path as string init groupPath($group) + "/projects?include_subgroups=false";
    if ($includeSubgroups) {
        $path = groupPath($group) + "/projects?include_subgroups=true";
    }
    return projectsAt($c, $path);
}

/**
 * The projects the token's account is a member of.
 *
 * @param c {Client} the client
 * @return {list of Project} the projects
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func myProjects(c as Client) {
    return projectsAt($c, "/projects?membership=true");
}

/**
 * Search the projects the token may see by name, path and description.
 *
 * @param c {Client} the client
 * @param query {string} the words to look for
 * @return {list of Project} the matches
 * @throws {GitlabError} kind `"gitlab"` on an empty query, or as `getAll`
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func searchProjects(c as Client, query as string) {
    if (strings.trim($query) == "") {
        fail("a search needs a query");
    }
    return projectsAt($c, "/projects?search=" + uri.encode($query));
}

/**
 * Search with GitLab's search API, in one project or the whole instance.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path; "" for the whole instance
 * @param scope {string} what to search, e.g. `issues`, `merge_requests`,
 *   `milestones`, `projects` (instance only), `blobs`, `commits`, `notes`
 *   (project only), `users`
 * @param query {string} the words to look for
 * @return {list of json.Value} the matches, as GitLab describes them
 * @throws {GitlabError} kind `"gitlab"` on an empty query or a bad scope, or as
 *   `getAll`
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func search(c as Client, project as string, scope as string, query as string) {
    if (strings.trim($query) == "") {
        fail("a search needs a query");
    }
    if (not regex.matches('^[a-z_]+$', $scope)) {
        fail("a search scope is a word such as issues, got " + shown($scope));
    }
    def path as string init "/search";
    if ($project != "") {
        $path = projectPath($project) + "/search";
    }
    return getAll($c, $path + "?scope=" + $scope + "&search=" + uri.encode($query));
}

/**
 * Check a visibility.
 *
 * @param visibility {string} the visibility
 * @return {string} the visibility
 */
func checkVisibility(visibility as string) {
    if (not lists.contains(["private", "internal", "public"], $visibility)) {
        fail("a visibility is private, internal or public, got " + shown($visibility));
    }
    return $visibility;
}

/**
 * The id of a group or user namespace.
 *
 * @param c {Client} the client
 * @param namespace {string} the full path, e.g. `group/sub`
 * @return {int} the id
 */
func namespaceId(c as Client, namespace as string) {
    if (not isNamePath($namespace, 1)) {
        fail("a namespace is a path such as group/sub, got " + shown($namespace));
    }
    def d as json.Value init call(
        $c,
        "GET",
        "/namespaces/" + strings.replace($namespace, "/", "%2F"),
        "");
    return numberAt($d, "/id");
}

/**
 * Create an empty project.
 *
 * @param c {Client} the client
 * @param namespace {string} the group to create it in, e.g. `group/sub`; ""
 *   for the token's own account
 * @param name {string} the name, which is also its path
 * @param description {string} the description; "" for none
 * @param visibility {string} `private`, `internal` or `public`
 * @return {Project} the new project
 * @throws {GitlabError} kind `"gitlab"` when the name is taken or not allowed
 *   (HTTP 400), or as `call`
 */
export func createProject(
    c as Client,
    namespace as string,
    name as string,
    description as string,
    visibility as string) {
    if (not regex.matches(NAME_PATTERN, $name)) {
        fail("a project name is letters, digits, _, . and -, got " + shown($name));
    }
    def doc as json.Value init objectOf(
        {
            "name": $name,
            "path": $name,
            "description": $description,
            "visibility": checkVisibility($visibility)
        },
        {});
    if ($namespace != "") {
        $doc = json.set($doc, "/namespace_id", namespaceId($c, $namespace));
    }
    return projectFrom(call($c, "POST", "/projects", json.encode($doc)));
}

/**
 * Delete a project, with its issues, merge requests and releases. An
 * instance with delayed deletion keeps it for some days first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @throws {GitlabError} kind `"gitlab"` when the token may not, or as `call`
 */
export func deleteProject(c as Client, project as string) {
    call($c, "DELETE", projectPath($project), "");
}

/**
 * Change a project's name or description.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the new display name; "" to keep it. The path stays.
 * @param description {string} the new description; "" to keep it
 * @return {Project} the project
 * @throws {GitlabError} kind `"gitlab"` when both are "", or as `call`
 */
export func editProject(c as Client, project as string, name as string, description as string) {
    if ($name == "" and $description == "") {
        fail("an edit changes the name or the description");
    }
    def doc as string init bodyOf({"name": $name, "description": $description}, {});
    return projectFrom(call($c, "PUT", projectPath($project), $doc));
}

/**
 * Archive a project, or bring it back. An archived one is read-only.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param archived {bool} whether it is archived
 * @return {Project} the project
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func setArchived(c as Client, project as string, archived as bool) {
    def action as string init "/unarchive";
    if ($archived) {
        $action = "/archive";
    }
    return projectFrom(call($c, "POST", projectPath($project) + $action, ""));
}

/**
 * Change a project's default branch.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param branch {string} an existing branch
 * @return {Project} the project
 * @throws {GitlabError} kind `"gitlab"` on an empty name, or as `call`
 */
export func setDefaultBranch(c as Client, project as string, branch as string) {
    encoded($branch, "branch");
    def doc as string init bodyOf({"default_branch": $branch}, {});
    return projectFrom(call($c, "PUT", projectPath($project), $doc));
}

/**
 * Fork a project. GitLab copies the repository in the background; the fork
 * may be empty for a moment.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path to fork
 * @param namespace {string} the group to fork into, e.g. `group/sub`; "" for
 *   the token's account
 * @param name {string} the fork's name and path; "" for the same name
 * @return {Project} the fork
 * @throws {GitlabError} kind `"gitlab"` on a bad name, or as `call`
 */
export func forkProject(c as Client, project as string, namespace as string, name as string) {
    if ($namespace != "" and not isNamePath($namespace, 1)) {
        fail("a namespace is a path such as group/sub, got " + shown($namespace));
    }
    if ($name != "" and not regex.matches(NAME_PATTERN, $name)) {
        fail("a project name is letters, digits, _, . and -, got " + shown($name));
    }
    def doc as string init bodyOf({"namespace_path": $namespace, "name": $name, "path": $name}, {});
    return projectFrom(call($c, "POST", projectPath($project) + "/fork", $doc));
}

/**
 * The forks of a project the token may see.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Project} the forks
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func forks(c as Client, project as string) {
    return projectsAt($c, projectPath($project) + "/forks");
}

/**
 * A group from a reply.
 *
 * @param d {json.Value} the document
 * @return {Group} the group
 */
func groupFrom(d as json.Value) {
    return Group{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        path: field($d, "/path"),
        fullPath: field($d, "/full_path"),
        description: field($d, "/description"),
        visibility: field($d, "/visibility"),
        parentId: numberAt($d, "/parent_id"),
        webUrl: field($d, "/web_url")
    };
}

/**
 * The groups of a list endpoint.
 *
 * @param c {Client} the client
 * @param path {string} the endpoint
 * @return {list of Group} the groups
 */
func groupsAt(c as Client, path as string) {
    def out as list of Group init [];
    for (def d in getAll($c, $path)) {
        $out[] = groupFrom($d);
    }
    return $out;
}

/**
 * One group or subgroup.
 *
 * @param c {Client} the client
 * @param group {string} the id or full path, e.g. `group/sub`
 * @return {Group} the group
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or as
 *   `call`
 */
export func group(c as Client, group as string) {
    return groupFrom(call($c, "GET", groupPath($group) + "?with_projects=false", ""));
}

/**
 * The direct subgroups of a group.
 *
 * @param c {Client} the client
 * @param group {string} the id or full path
 * @return {list of Group} the subgroups
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func subgroups(c as Client, group as string) {
    return groupsAt($c, groupPath($group) + "/subgroups");
}

/**
 * The groups the token's account is a member of.
 *
 * @param c {Client} the client
 * @return {list of Group} the groups
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func myGroups(c as Client) {
    return groupsAt($c, "/groups?min_access_level=" + convert.toString(ACCESS_GUEST));
}

/**
 * A member from a reply.
 *
 * @param d {json.Value} the document
 * @return {Member} the member
 */
func memberFrom(d as json.Value) {
    return Member{
        id: numberAt($d, "/id"),
        username: field($d, "/username"),
        name: field($d, "/name"),
        accessLevel: numberAt($d, "/access_level"),
        expiresAt: field($d, "/expires_at")
    };
}

/**
 * The direct members of a project, without those it inherits from groups.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Member} the members
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func members(c as Client, project as string) {
    def out as list of Member init [];
    for (def d in getAll($c, projectPath($project) + "/members")) {
        $out[] = memberFrom($d);
    }
    return $out;
}

/**
 * Add a member to a project, or change the access level of one.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param username {string} the user
 * @param accessLevel {int} one of the `ACCESS_*` levels
 * @return {Member} the member
 * @throws {GitlabError} kind `"gitlab"` on another level, an unknown user, or as
 *   `call`
 */
export func addMember(c as Client, project as string, username as string, accessLevel as int) {
    if (not lists.contains([10, 15, 20, 30, 40, 50], $accessLevel)) {
        fail("an access level is 10, 15, 20, 30, 40 or 50, got " + convert.toString($accessLevel));
    }
    def id as int init user($c, $username).id;
    def doc as json.Value init json.set(json.map(), "/user_id", $id);
    $doc = json.set($doc, "/access_level", $accessLevel);
    def path as string init projectPath($project) + "/members";
    try {
        return memberFrom(call($c, "POST", $path, json.encode($doc)));
    } catch (e) {
        # an existing member is a 409 for this POST; anything else is a failure
        if ($e.kind != ERROR_KIND or $e.status != 409) {
            throw $e;
        }
    }
    def change as json.Value init json.set(json.map(), "/access_level", $accessLevel);
    return memberFrom(call($c, "PUT", $path + "/" + convert.toString($id), json.encode($change)));
}

/**
 * Remove a member from a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param username {string} the user
 * @throws {GitlabError} kind `"gitlab"` on an unknown user, or as `call`
 */
export func removeMember(c as Client, project as string, username as string) {
    def id as int init user($c, $username).id;
    call($c, "DELETE", projectPath($project) + "/members/" + convert.toString($id), "");
}

/**
 * A hook from a reply.
 *
 * @param d {json.Value} the document
 * @return {Hook} the hook
 */
func hookFrom(d as json.Value) {
    def events as list of string init [];
    for (def name in HOOK_EVENTS) {
        if (flag($d, "/" + $name + "_events")) {
            $events[] = $name;
        }
    }
    return Hook{
        id: numberAt($d, "/id"),
        url: field($d, "/url"),
        events: $events,
        sslVerification: flag($d, "/enable_ssl_verification")
    };
}

/**
 * The hooks of a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Hook} the hooks
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func hooks(c as Client, project as string) {
    def out as list of Hook init [];
    for (def d in getAll($c, projectPath($project) + "/hooks")) {
        $out[] = hookFrom($d);
    }
    return $out;
}

/**
 * Add a hook that posts JSON to a URL, with certificate checking on.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param url {string} where to post, `https://...`
 * @param secret {string} the token GitLab sends in `X-Gitlab-Token`; "" for
 *   none
 * @param events {list of string} the events, from `HOOK_EVENTS`, e.g.
 *   `["push", "merge_requests"]`
 * @return {Hook} the new hook
 * @throws {GitlabError} kind `"gitlab"` on a URL that is not http(s), no or an
 *   unknown event, or as `call`
 */
export func createHook(
    c as Client,
    project as string,
    url as string,
    secret as string,
    events as list of string) {
    if (not regex.matches('^https?://[^\s]+$', $url)) {
        fail("a hook URL is http:// or https://, got " + shown($url));
    }
    if (len($events) == 0) {
        fail("a hook fires on at least one event");
    }
    def flags as map of string to bool init {"enable_ssl_verification": true};
    for (def name in HOOK_EVENTS) {
        $flags[$name + "_events"] = false;
    }
    for (def name in $events) {
        if (not lists.contains(HOOK_EVENTS, $name)) {
            fail("a hook event is one of " + strings.join(HOOK_EVENTS, ", ") + ", got " +
                shown($name));
        }
        $flags[$name + "_events"] = true;
    }
    def doc as string init bodyOf({"url": $url, "token": $secret}, $flags);
    return hookFrom(call($c, "POST", projectPath($project) + "/hooks", $doc));
}

/**
 * Delete a hook.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the hook id
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteHook(c as Client, project as string, id as int) {
    call($c, "DELETE", projectPath($project) + "/hooks/" + idText($id, "a hook id"), "");
}

/**
 * Check a state filter.
 *
 * @param state {string} the filter
 * @param allowed {list of string} the states the endpoint knows
 * @return {string} the filter
 */
func checkState(state as string, allowed as list of string) {
    if (not lists.contains($allowed, $state)) {
        fail("a state is one of " + strings.join($allowed, ", ") + ", got " + shown($state));
    }
    return $state;
}

/**
 * The strings of a list member.
 *
 * @param d {json.Value} the document
 * @param ptr {string} the list's pointer
 * @param key {string} the member of each entry; "" for the entries themselves
 * @return {list of string} the values
 */
func namesAt(d as json.Value, ptr as string, key as string) {
    def out as list of string init [];
    for (def p in items($d, $ptr)) {
        if ($key == "") {
            $out[] = field($d, $p);
        } else {
            $out[] = field($d, $p + "/" + $key);
        }
    }
    return $out;
}

/**
 * An issue from a reply.
 *
 * @param d {json.Value} the document
 * @return {Issue} the issue
 */
func issueFrom(d as json.Value) {
    return Issue{
        iid: numberAt($d, "/iid"),
        id: numberAt($d, "/id"),
        title: field($d, "/title"),
        description: field($d, "/description"),
        state: field($d, "/state"),
        author: field($d, "/author/username"),
        labels: labelNames($d),
        assignees: namesAt($d, "/assignees", "username"),
        milestone: field($d, "/milestone/title"),
        notes: numberAt($d, "/user_notes_count"),
        isConfidential: flag($d, "/confidential"),
        created: field($d, "/created_at"),
        updated: field($d, "/updated_at"),
        closed: field($d, "/closed_at"),
        webUrl: field($d, "/web_url")
    };
}

/**
 * The label names of an issue or merge request: plain names, or label
 * objects when GitLab was asked for their details.
 *
 * @param d {json.Value} the document
 * @return {list of string} the names
 */
func labelNames(d as json.Value) {
    def out as list of string init [];
    for (def p in items($d, "/labels")) {
        if (kindAt($d, $p) == "map") {
            $out[] = field($d, $p + "/name");
        } else {
            $out[] = field($d, $p);
        }
    }
    return $out;
}

/**
 * An id or number as it goes into a path; GitLab's start at 1.
 *
 * @param id {int} the id
 * @param what {string} what it numbers, for the message
 * @return {string} the id as text
 */
func idText(id as int, what as string) {
    if ($id < 1) {
        fail($what + " is 1 or more, got " + convert.toString($id));
    }
    return convert.toString($id);
}

/**
 * The API path of an issue.
 *
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @return {string} `/projects/<id>/issues/<iid>`
 */
func issuePath(project as string, iid as int) {
    return projectPath($project) + "/issues/" + idText($iid, "an issue number");
}

/**
 * The issues of a project, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param state {string} `opened`, `closed` or `all`
 * @return {list of Issue} the issues
 * @throws {GitlabError} kind `"gitlab"` as `getAll`; HTTP 403 or 404 when the
 *   project has issues turned off
 */
export func issues(c as Client, project as string, state as string) {
    def out as list of Issue init [];
    def path as string init projectPath($project) + "/issues?state=" +
        checkState($state, ["opened", "closed", "all"]);
    for (def d in getAll($c, $path)) {
        $out[] = issueFrom($d);
    }
    return $out;
}

/**
 * One issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or as
 *   `call`
 */
export func issue(c as Client, project as string, iid as int) {
    return issueFrom(call($c, "GET", issuePath($project, $iid), ""));
}

/**
 * Open an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param title {string} the title
 * @param description {string} the text, Markdown; "" for none
 * @return {Issue} the new issue
 * @throws {GitlabError} kind `"gitlab"` on an empty title, or as `call`
 */
export func createIssue(c as Client, project as string, title as string, description as string) {
    if (strings.trim($title) == "") {
        fail("an issue needs a title");
    }
    def doc as string init bodyOf({"title": $title, "description": $description}, {});
    return issueFrom(call($c, "POST", projectPath($project) + "/issues", $doc));
}

/**
 * Change an issue's title or text.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param title {string} the new title; "" to keep it
 * @param description {string} the new text; "" to keep it
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` when both are "", or as `call`
 */
export func editIssue(
    c as Client,
    project as string,
    iid as int,
    title as string,
    description as string) {
    if ($title == "" and $description == "") {
        fail("an edit changes the title or the text");
    }
    def doc as string init bodyOf({"title": $title, "description": $description}, {});
    return issueFrom(call($c, "PUT", issuePath($project, $iid), $doc));
}

/**
 * Close an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @return {Issue} the closed issue
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func closeIssue(c as Client, project as string, iid as int) {
    def doc as string init bodyOf({"state_event": "close"}, {});
    return issueFrom(call($c, "PUT", issuePath($project, $iid), $doc));
}

/**
 * Reopen an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @return {Issue} the reopened issue
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func reopenIssue(c as Client, project as string, iid as int) {
    def doc as string init bodyOf({"state_event": "reopen"}, {});
    return issueFrom(call($c, "PUT", issuePath($project, $iid), $doc));
}

/**
 * Set who is assigned to an issue. GitLab Free takes one assignee.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param names {list of string} the user names; `[]` for nobody
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` on an unknown user, or as `call`
 */
export func setAssignees(c as Client, project as string, iid as int, names as list of string) {
    def doc as json.Value init json.set(json.map(), "/assignee_ids", userIds($c, $names));
    return issueFrom(call($c, "PUT", issuePath($project, $iid), json.encode($doc)));
}

/**
 * Put an issue in a milestone.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param milestoneId {int} the milestone's `id` (not its `iid`); 0 for none
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func setMilestone(c as Client, project as string, iid as int, milestoneId as int) {
    if ($milestoneId < 0) {
        fail("a milestone id is 0 (none) or more, got " + convert.toString($milestoneId));
    }
    def doc as json.Value init json.set(json.map(), "/milestone_id", $milestoneId);
    return issueFrom(call($c, "PUT", issuePath($project, $iid), json.encode($doc)));
}

/**
 * Label names as GitLab's comma-separated parameter.
 *
 * @param names {list of string} the names
 * @return {string} the names joined with `,`
 */
func labelList(names as list of string) {
    for (def name in $names) {
        if (strings.trim($name) == "" or strings.contains($name, ",")) {
            fail("a label name is not empty and holds no comma, got " + shown($name));
        }
    }
    return strings.join($names, ",");
}

/**
 * Replace the labels of an issue. Labels that do not exist yet are created.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param names {list of string} label names; `[]` for none
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` on an empty name or one with a comma, or
 *   as `call`
 */
export func setIssueLabels(c as Client, project as string, iid as int, names as list of string) {
    def doc as json.Value init json.set(json.map(), "/labels", labelList($names));
    return issueFrom(call($c, "PUT", issuePath($project, $iid), json.encode($doc)));
}

/**
 * Add labels to an issue. Labels that do not exist yet are created.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param names {list of string} label names
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` on no, an empty or a comma name, or as
 *   `call`
 */
export func addIssueLabels(c as Client, project as string, iid as int, names as list of string) {
    if (len($names) == 0) {
        fail("adding labels names at least one");
    }
    def doc as string init bodyOf({"add_labels": labelList($names)}, {});
    return issueFrom(call($c, "PUT", issuePath($project, $iid), $doc));
}

/**
 * Take a label off an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param name {string} the label name
 * @return {Issue} the issue
 * @throws {GitlabError} kind `"gitlab"` on an empty name, or as `call`
 */
export func removeIssueLabel(c as Client, project as string, iid as int, name as string) {
    def doc as string init bodyOf({"remove_labels": labelList([$name])}, {});
    return issueFrom(call($c, "PUT", issuePath($project, $iid), $doc));
}

/**
 * A note from a reply.
 *
 * @param d {json.Value} the document
 * @return {Note} the note
 */
func noteFrom(d as json.Value) {
    return Note{
        id: numberAt($d, "/id"),
        author: field($d, "/author/username"),
        body: field($d, "/body"),
        isSystem: flag($d, "/system"),
        created: field($d, "/created_at"),
        updated: field($d, "/updated_at")
    };
}

/**
 * The notes of an issue or merge request, oldest first.
 *
 * @param c {Client} the client
 * @param path {string} the issue's or merge request's path
 * @return {list of Note} the notes
 */
func notesAt(c as Client, path as string) {
    def out as list of Note init [];
    for (def d in getAll($c, $path + "/notes?sort=asc&order_by=created_at")) {
        $out[] = noteFrom($d);
    }
    return $out;
}

/**
 * Add a note to an issue or merge request.
 *
 * @param c {Client} the client
 * @param path {string} the issue's or merge request's path
 * @param body {string} the text
 * @return {Note} the new note
 */
func addNoteAt(c as Client, path as string, body as string) {
    if (strings.trim($body) == "") {
        fail("a note needs a text");
    }
    return noteFrom(call($c, "POST", $path + "/notes", bodyOf({"body": $body}, {})));
}

/**
 * The notes on an issue, oldest first, system notes included.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @return {list of Note} the notes
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func notes(c as Client, project as string, iid as int) {
    return notesAt($c, issuePath($project, $iid));
}

/**
 * Comment on an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param body {string} the text, Markdown
 * @return {Note} the new note
 * @throws {GitlabError} kind `"gitlab"` on an empty text, or as `call`
 */
export func addNote(c as Client, project as string, iid as int, body as string) {
    return addNoteAt($c, issuePath($project, $iid), $body);
}

/**
 * Change the text of a note on an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param noteId {int} the note id
 * @param body {string} the new text
 * @return {Note} the note
 * @throws {GitlabError} kind `"gitlab"` on an empty text, or as `call`
 */
export func editNote(c as Client, project as string, iid as int, noteId as int, body as string) {
    if (strings.trim($body) == "") {
        fail("a note needs a text");
    }
    def path as string init issuePath($project, $iid) + "/notes/" + idText($noteId, "a note id");
    return noteFrom(call($c, "PUT", $path, bodyOf({"body": $body}, {})));
}

/**
 * Delete a note on an issue.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the issue's number
 * @param noteId {int} the note id
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteNote(c as Client, project as string, iid as int, noteId as int) {
    call($c, "DELETE", issuePath($project, $iid) + "/notes/" + idText($noteId, "a note id"), "");
}

/**
 * A label from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Label} the label
 */
func labelFrom(d as json.Value) {
    return Label{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        color: field($d, "/color"),
        description: field($d, "/description")
    };
}

/**
 * The labels of a project, those of its groups included.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Label} the labels
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func labels(c as Client, project as string) {
    def out as list of Label init [];
    for (def d in getAll($c, projectPath($project) + "/labels")) {
        $out[] = labelFrom($d);
    }
    return $out;
}

/**
 * Create a label.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the name; `scope::name` makes a scoped label
 * @param color {string} the colour, `#rrggbb`
 * @param description {string} the description; "" for none
 * @return {Label} the new label
 * @throws {GitlabError} kind `"gitlab"` on an empty name, a comma in it or a
 *   colour that is not `#rrggbb`, when it exists (HTTP 409), or as `call`
 */
export func createLabel(
    c as Client,
    project as string,
    name as string,
    color as string,
    description as string) {
    labelList([$name]);
    if (not regex.matches('^#[0-9A-Fa-f]{6}$', $color)) {
        fail("a label colour is #rrggbb, got " + shown($color));
    }
    def doc as string init bodyOf(
        {"name": $name, "color": $color, "description": $description},
        {});
    return labelFrom(call($c, "POST", projectPath($project) + "/labels", $doc));
}

/**
 * Delete a label, from the project and every issue and merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the label id
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteLabel(c as Client, project as string, id as int) {
    call($c, "DELETE", projectPath($project) + "/labels/" + idText($id, "a label id"), "");
}

/**
 * A milestone from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Milestone} the milestone
 */
func milestoneFrom(d as json.Value) {
    return Milestone{
        id: numberAt($d, "/id"),
        iid: numberAt($d, "/iid"),
        title: field($d, "/title"),
        description: field($d, "/description"),
        state: field($d, "/state"),
        dueDate: field($d, "/due_date"),
        startDate: field($d, "/start_date"),
        webUrl: field($d, "/web_url")
    };
}

/**
 * The milestones of a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param state {string} `active`, `closed` or `all`
 * @return {list of Milestone} the milestones
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func milestones(c as Client, project as string, state as string) {
    def path as string init projectPath($project) + "/milestones";
    if (checkState($state, ["active", "closed", "all"]) != "all") {
        $path = $path + "?state=" + $state;
    }
    def out as list of Milestone init [];
    for (def d in getAll($c, $path)) {
        $out[] = milestoneFrom($d);
    }
    return $out;
}

/**
 * Create a milestone.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param title {string} the title
 * @param description {string} the description; "" for none
 * @param dueDate {string} the due date, `YYYY-MM-DD`; "" for none
 * @return {Milestone} the new milestone
 * @throws {GitlabError} kind `"gitlab"` on an empty title or a date not
 *   `YYYY-MM-DD`, or as `call`
 */
export func createMilestone(
    c as Client,
    project as string,
    title as string,
    description as string,
    dueDate as string) {
    if (strings.trim($title) == "") {
        fail("a milestone needs a title");
    }
    if ($dueDate != "" and not regex.matches('^[0-9]{4}-[0-9]{2}-[0-9]{2}$', $dueDate)) {
        fail("a due date is YYYY-MM-DD, got " + shown($dueDate));
    }
    def doc as string init bodyOf(
        {
            "title": $title,
            "description": $description,
            "due_date": $dueDate
        },
        {});
    return milestoneFrom(call($c, "POST", projectPath($project) + "/milestones", $doc));
}

/**
 * Close a milestone, or make it active again.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the milestone id
 * @param closed {bool} whether it is closed
 * @return {Milestone} the milestone
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func setMilestoneClosed(c as Client, project as string, id as int, closed as bool) {
    def event as string init "activate";
    if ($closed) {
        $event = "close";
    }
    def path as string init projectPath($project) + "/milestones/" + idText($id, "a milestone id");
    return milestoneFrom(call($c, "PUT", $path, bodyOf({"state_event": $event}, {})));
}

/**
 * Delete a milestone. Its issues stay, without a milestone.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the milestone id
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteMilestone(c as Client, project as string, id as int) {
    call($c, "DELETE", projectPath($project) + "/milestones/" + idText($id, "a milestone id"), "");
}

/**
 * A merge request from a reply.
 *
 * @param d {json.Value} the document
 * @return {MergeRequest} the merge request
 */
func mergeRequestFrom(d as json.Value) {
    def status as string init field($d, "/detailed_merge_status");
    return MergeRequest{
        iid: numberAt($d, "/iid"),
        id: numberAt($d, "/id"),
        title: field($d, "/title"),
        description: field($d, "/description"),
        state: field($d, "/state"),
        author: field($d, "/author/username"),
        sourceBranch: field($d, "/source_branch"),
        targetBranch: field($d, "/target_branch"),
        sha: field($d, "/sha"),
        isDraft: flag($d, "/draft"),
        mergeStatus: $status,
        mergeable: $status == "mergeable",
        merged: field($d, "/state") == "merged",
        mergeSha: field($d, "/merge_commit_sha"),
        squashSha: field($d, "/squash_commit_sha"),
        webUrl: field($d, "/web_url"),
        created: field($d, "/created_at"),
        mergedAt: field($d, "/merged_at")
    };
}

/**
 * The API path of a merge request.
 *
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {string} `/projects/<id>/merge_requests/<iid>`
 */
func mergeRequestPath(project as string, iid as int) {
    return projectPath($project) + "/merge_requests/" + idText($iid, "a merge request number");
}

/**
 * The merge requests of a project, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param state {string} `opened`, `closed`, `locked`, `merged` or `all`
 * @return {list of MergeRequest} the merge requests
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func mergeRequests(c as Client, project as string, state as string) {
    def path as string init projectPath($project) + "/merge_requests?state=" +
        checkState($state, ["opened", "closed", "locked", "merged", "all"]);
    def out as list of MergeRequest init [];
    for (def d in getAll($c, $path)) {
        $out[] = mergeRequestFrom($d);
    }
    return $out;
}

/**
 * One merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {MergeRequest} the merge request
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or as
 *   `call`
 */
export func mergeRequest(c as Client, project as string, iid as int) {
    return mergeRequestFrom(call($c, "GET", mergeRequestPath($project, $iid), ""));
}

/**
 * Open a merge request within a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param sourceBranch {string} the branch with the changes
 * @param targetBranch {string} the branch to merge into
 * @param title {string} the title; a `Draft:` prefix makes it a draft
 * @param description {string} the text, Markdown; "" for none
 * @return {MergeRequest} the new merge request
 * @throws {GitlabError} kind `"gitlab"` on an empty title or branch, when one
 *   for the branches is open already (HTTP 409), or as `call`
 */
export func createMergeRequest(
    c as Client,
    project as string,
    sourceBranch as string,
    targetBranch as string,
    title as string,
    description as string) {
    if (strings.trim($title) == "") {
        fail("a merge request needs a title");
    }
    encoded($sourceBranch, "branch");
    encoded($targetBranch, "branch");
    def doc as string init bodyOf(
        {
            "source_branch": $sourceBranch,
            "target_branch": $targetBranch,
            "title": $title,
            "description": $description
        },
        {});
    return mergeRequestFrom(call($c, "POST", projectPath($project) + "/merge_requests", $doc));
}

/**
 * Change a merge request's title or text.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @param title {string} the new title; "" to keep it
 * @param description {string} the new text; "" to keep it
 * @return {MergeRequest} the merge request
 * @throws {GitlabError} kind `"gitlab"` when both are "", or as `call`
 */
export func editMergeRequest(
    c as Client,
    project as string,
    iid as int,
    title as string,
    description as string) {
    if ($title == "" and $description == "") {
        fail("an edit changes the title or the text");
    }
    def doc as string init bodyOf({"title": $title, "description": $description}, {});
    return mergeRequestFrom(call($c, "PUT", mergeRequestPath($project, $iid), $doc));
}

/**
 * Close a merge request without merging it.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {MergeRequest} the merge request
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func closeMergeRequest(c as Client, project as string, iid as int) {
    def doc as string init bodyOf({"state_event": "close"}, {});
    return mergeRequestFrom(call($c, "PUT", mergeRequestPath($project, $iid), $doc));
}

/**
 * Reopen a closed merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {MergeRequest} the merge request
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func reopenMergeRequest(c as Client, project as string, iid as int) {
    def doc as string init bodyOf({"state_event": "reopen"}, {});
    return mergeRequestFrom(call($c, "PUT", mergeRequestPath($project, $iid), $doc));
}

/**
 * Merge a merge request now, with the project's merge method.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @param sha {string} the head commit it must still have; "" to merge
 *   whatever it has
 * @param squash {bool} squash its commits into one
 * @param removeSourceBranch {bool} delete the source branch afterwards
 * @return {MergeRequest} the merged merge request
 * @throws {GitlabError} kind `"gitlab"`: HTTP 405 when it cannot be merged
 *   (a draft, closed, conflicts, missing approvals), 409 when the head moved
 *   past `sha`, 422 when the merge failed, or as `call`
 */
export func mergeMergeRequest(
    c as Client,
    project as string,
    iid as int,
    sha as string,
    squash as bool,
    removeSourceBranch as bool) {
    if ($sha != "" and not regex.matches('^[0-9a-f]{7,64}$', $sha)) {
        fail("a commit SHA is hexadecimal, got " + shown($sha));
    }
    def doc as string init bodyOf(
        {"sha": $sha},
        {"squash": $squash, "should_remove_source_branch": $removeSourceBranch});
    return mergeRequestFrom(call($c, "PUT", mergeRequestPath($project, $iid) + "/merge", $doc));
}

/**
 * Set who reviews a merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @param names {list of string} the user names; `[]` for nobody
 * @return {MergeRequest} the merge request
 * @throws {GitlabError} kind `"gitlab"` on an unknown user, or as `call`
 */
export func setReviewers(c as Client, project as string, iid as int, names as list of string) {
    def doc as json.Value init json.set(json.map(), "/reviewer_ids", userIds($c, $names));
    return mergeRequestFrom(call($c, "PUT", mergeRequestPath($project, $iid), json.encode($doc)));
}

/**
 * An approval state from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Approvals} the state
 */
func approvalsFrom(d as json.Value) {
    return Approvals{
        approved: flag($d, "/approved"),
        approvedBy: namesAt($d, "/approved_by", "user/username"),
        required: numberAt($d, "/approvals_required"),
        left: numberAt($d, "/approvals_left")
    };
}

/**
 * The approval state of a merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {Approvals} the state
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func approvals(c as Client, project as string, iid as int) {
    return approvalsFrom(call($c, "GET", mergeRequestPath($project, $iid) + "/approvals", ""));
}

/**
 * Approve a merge request as the token's account.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @param sha {string} the head commit the approval is for; "" for any
 * @return {Approvals} the state afterwards
 * @throws {GitlabError} kind `"gitlab"`: HTTP 401 when the account may not
 *   approve or already did, 409 when the head moved past `sha`, or as `call`
 */
export func approveMergeRequest(c as Client, project as string, iid as int, sha as string) {
    if ($sha != "" and not regex.matches('^[0-9a-f]{7,64}$', $sha)) {
        fail("a commit SHA is hexadecimal, got " + shown($sha));
    }
    def path as string init mergeRequestPath($project, $iid) + "/approve";
    return approvalsFrom(call($c, "POST", $path, bodyOf({"sha": $sha}, {})));
}

/**
 * Take back the token account's approval of a merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @throws {GitlabError} kind `"gitlab"` when it had not approved (HTTP 404), or
 *   as `call`
 */
export func unapproveMergeRequest(c as Client, project as string, iid as int) {
    call($c, "POST", mergeRequestPath($project, $iid) + "/unapprove", "");
}

/**
 * The files a merge request changes, with their diffs.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {list of ChangedFile} the files
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func mergeRequestChanges(c as Client, project as string, iid as int) {
    def out as list of ChangedFile init [];
    for (def d in getAll($c, mergeRequestPath($project, $iid) + "/diffs")) {
        $out[] = ChangedFile{
            oldPath: field($d, "/old_path"),
            newPath: field($d, "/new_path"),
            isNew: flag($d, "/new_file"),
            isRenamed: flag($d, "/renamed_file"),
            isDeleted: flag($d, "/deleted_file"),
            diff: field($d, "/diff")
        };
    }
    return $out;
}

/**
 * The commits of a merge request, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {list of Commit} the commits
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func mergeRequestCommits(c as Client, project as string, iid as int) {
    def out as list of Commit init [];
    for (def d in getAll($c, mergeRequestPath($project, $iid) + "/commits")) {
        $out[] = commitFrom($d);
    }
    return $out;
}

/**
 * The notes on a merge request, oldest first, system notes included.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @return {list of Note} the notes
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func mergeRequestNotes(c as Client, project as string, iid as int) {
    return notesAt($c, mergeRequestPath($project, $iid));
}

/**
 * Comment on a merge request.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param iid {int} the merge request's number
 * @param body {string} the text, Markdown
 * @return {Note} the new note
 * @throws {GitlabError} kind `"gitlab"` on an empty text, or as `call`
 */
export func addMergeRequestNote(c as Client, project as string, iid as int, body as string) {
    return addNoteAt($c, mergeRequestPath($project, $iid), $body);
}

/**
 * A release link from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the link's pointer; "" for the root
 * @return {ReleaseLink} the link
 */
func linkFrom(d as json.Value, p as string) {
    return ReleaseLink{
        id: numberAt($d, $p + "/id"),
        name: field($d, $p + "/name"),
        url: field($d, $p + "/url"),
        directAssetUrl: field($d, $p + "/direct_asset_url"),
        linkType: field($d, $p + "/link_type")
    };
}

/**
 * A release from a reply.
 *
 * @param d {json.Value} the document
 * @return {Release} the release
 */
func releaseFrom(d as json.Value) {
    def links as list of ReleaseLink init [];
    for (def p in items($d, "/assets/links")) {
        $links[] = linkFrom($d, $p);
    }
    return Release{
        tag: field($d, "/tag_name"),
        name: field($d, "/name"),
        description: field($d, "/description"),
        author: field($d, "/author/username"),
        commitSha: field($d, "/commit/id"),
        created: field($d, "/created_at"),
        released: field($d, "/released_at"),
        isUpcoming: flag($d, "/upcoming_release"),
        webUrl: field($d, "/_links/self"),
        links: $links,
        sources: namesAt($d, "/assets/sources", "url")
    };
}

/**
 * The API path of a tag's release. The tag is one segment: a `/` in it is
 * sent as `%2F`.
 *
 * @param project {string} the id or full path
 * @param tag {string} the tag
 * @return {string} the path
 */
func releasePath(project as string, tag as string) {
    return projectPath($project) + "/releases/" + encoded($tag, "tag");
}

/**
 * The releases of a project, newest release date first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Release} the releases
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func releases(c as Client, project as string) {
    def out as list of Release init [];
    for (def d in getAll($c, projectPath($project) + "/releases")) {
        $out[] = releaseFrom($d);
    }
    return $out;
}

/**
 * The release of a tag.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the tag, e.g. `v1.2.0`
 * @return {Release} the release
 * @throws {GitlabError} kind `"gitlab"` when there is none (HTTP 404), or as
 *   `call`
 */
export func release(c as Client, project as string, tag as string) {
    return releaseFrom(call($c, "GET", releasePath($project, $tag), ""));
}

/**
 * The release with the latest release date that is not upcoming.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {Release} the release
 * @throws {GitlabError} kind `"gitlab"` when there is none (HTTP 404), or as
 *   `call`
 */
export func latestRelease(c as Client, project as string) {
    return releaseFrom(call($c, "GET", projectPath($project) + "/releases/permalink/latest", ""));
}

/**
 * Publish a release, creating the tag at `ref` when it does not exist.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the tag, e.g. `v1.2.0`
 * @param ref {string} the branch or commit to tag; "" when the tag exists
 * @param name {string} the title; "" for the tag
 * @param description {string} the notes, Markdown; "" for none
 * @return {Release} the new release
 * @throws {GitlabError} kind `"gitlab"` on a bad tag, when the tag is missing
 *   and `ref` is "" or the release exists (HTTP 409), or as `call`
 */
export func createRelease(
    c as Client,
    project as string,
    tag as string,
    ref as string,
    name as string,
    description as string) {
    encoded($tag, "tag");
    def doc as string init bodyOf(
        {
            "tag_name": $tag,
            "ref": $ref,
            "name": $name,
            "description": $description
        },
        {});
    return releaseFrom(call($c, "POST", projectPath($project) + "/releases", $doc));
}

/**
 * Change a release's title or notes.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the release's tag
 * @param name {string} the new title; "" to keep it
 * @param description {string} the new notes; "" to keep them
 * @return {Release} the release
 * @throws {GitlabError} kind `"gitlab"` when both are "", or as `call`
 */
export func editRelease(
    c as Client,
    project as string,
    tag as string,
    name as string,
    description as string) {
    if ($name == "" and $description == "") {
        fail("an edit changes the title or the notes");
    }
    def doc as string init bodyOf({"name": $name, "description": $description}, {});
    return releaseFrom(call($c, "PUT", releasePath($project, $tag), $doc));
}

/**
 * Delete a release. The tag stays.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the release's tag
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteRelease(c as Client, project as string, tag as string) {
    call($c, "DELETE", releasePath($project, $tag), "");
}

# The kinds of a release link.
def const LINK_TYPES as list of string init ["other", "runbook", "image", "package"];

/**
 * Attach a link to a release: GitLab's release asset.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the release's tag
 * @param name {string} the name, unique in the release
 * @param url {string} where it points, `https://...`
 * @param linkType {string} `other`, `runbook`, `image` or `package`
 * @return {ReleaseLink} the new link
 * @throws {GitlabError} kind `"gitlab"` on an empty name, a URL that is not
 *   http(s), another type, a taken name or URL (HTTP 400), or as `call`
 */
export func addReleaseLink(
    c as Client,
    project as string,
    tag as string,
    name as string,
    url as string,
    linkType as string) {
    if (strings.trim($name) == "") {
        fail("a release link needs a name");
    }
    if (not regex.matches('^https?://[^\s]+$', $url)) {
        fail("a release link is http:// or https://, got " + shown($url));
    }
    if (not lists.contains(LINK_TYPES, $linkType)) {
        fail("a link type is other, runbook, image or package, got " + shown($linkType));
    }
    def doc as string init bodyOf({"name": $name, "url": $url, "link_type": $linkType}, {});
    return linkFrom(call($c, "POST", releasePath($project, $tag) + "/assets/links", $doc), "");
}

/**
 * Delete a link of a release.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the release's tag
 * @param linkId {int} the link id
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func deleteReleaseLink(c as Client, project as string, tag as string, linkId as int) {
    def path as string init releasePath($project, $tag) + "/assets/links/" +
        idText($linkId, "a link id");
    call($c, "DELETE", $path, "");
}

/**
 * Check a name of the generic package registry.
 *
 * @param text {string} the name
 * @param marks {string} the characters it may hold besides letters and
 *   digits, e.g. `._+-`
 * @param what {string} what it is, for the error message
 * @return {string} the name
 */
func checkPackagePart(text as string, marks as string, what as string) {
    def ok as bool init $text != "" and $text != "." and not strings.contains($text, "..");
    for (def ch in strings.chars($text)) {
        if (not regex.matches('^[A-Za-z0-9]$', $ch) and not strings.contains($marks, $ch)) {
            $ok = false;
        }
    }
    if (not $ok) {
        fail("a " + $what + " is letters, digits and " + $marks + " without .., got " +
            shown($text));
    }
    return $text;
}

/**
 * Upload a file to the project's generic package registry, as
 * `<packageName>/<version>/<fileName>`. Publishing a name and version again
 * adds the file to that package.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param packageName {string} the package, letters, digits and `._+-`
 * @param version {string} the version, letters, digits and `._+-`
 * @param fileName {string} the file name, letters, digits and `._+~@-`
 * @param data {bytes} the content
 * @return {string} the file's download URL under `/api/v4`
 * @throws {GitlabError} kind `"gitlab"` on a bad name, a network failure or a
 *   refusal
 */
export func uploadPackageFile(
    c as Client,
    project as string,
    packageName as string,
    version as string,
    fileName as string,
    data as bytes) {
    def tail as string init "/packages/generic/" +
        checkPackagePart($packageName, "._+-", "package name") + "/" +
        checkPackagePart($version, "._+-", "package version") + "/" +
        checkPackagePart($fileName, "._+~@-", "package file name");
    if (regex.matches('^[~@]|[~@]$', $fileName)) {
        fail("a package file name does not start or end with ~ or @, got " + shown($fileName));
    }
    def path as string init projectPath($project) + $tail;
    def headers as map of string to string init authHeaders($c);
    $headers["Content-Type"] = "application/octet-stream";
    def r as http.Response;
    try {
        $r = http.requestRawBodyTls(
            "PUT",
            $c.url + "/api/v4" + $path,
            $headers,
            $data,
            idleMs($c),
            0,
            $c.tls);
    } catch (e) {
        failTransport("PUT " + $path, $e);
    }
    if ($r.status < 200 or $r.status >= 300) {
        failStatus(
            "PUT " + $path + ": " + failureText($r.status, $r.statusText, $r.body),
            $r.status);
    }
    return $c.url + "/api/v4" + $path;
}

/**
 * Upload a file to the generic package registry and attach it to a release
 * as a `package` link: the file goes to `<packageName>/<tag>/<fileName>`.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param tag {string} the release's tag, also the package version
 * @param packageName {string} the package, letters, digits and `._+-`
 * @param fileName {string} the file name, also the link's name
 * @param data {bytes} the content
 * @return {ReleaseLink} the new link
 * @throws {GitlabError} kind `"gitlab"` as `uploadPackageFile` and
 *   `addReleaseLink`
 */
export func uploadAsset(
    c as Client,
    project as string,
    tag as string,
    packageName as string,
    fileName as string,
    data as bytes) {
    encoded($tag, "tag");
    def url as string init uploadPackageFile($c, $project, $packageName, $tag, $fileName, $data);
    return addReleaseLink($c, $project, $tag, $fileName, $url, "package");
}

/**
 * Where a redirect points, as an absolute URL.
 *
 * @param from {string} the URL that answered
 * @param location {string} its `Location` header
 * @return {string} the absolute URL
 */
func resolved(from as string, location as string) {
    if (regex.matches('^https?://', $location)) {
        return $location;
    }
    if (strings.startsWith($location, "//")) {
        return strings.substring($from, 0, strings.indexOf($from, "//")) + $location;
    }
    if (strings.startsWith($location, "/")) {
        return originOf($from) + $location;
    }
    fail("GET " + $from + ": a redirect to " + shown($location) + " is not absolute");
    return "";
}

/**
 * GET bytes from a URL. The token goes only to the instance's own origin;
 * a redirect elsewhere (object storage) is followed without it, a redirect
 * from `https` to `http` is refused.
 *
 * @param c {Client} the client
 * @param url {string} the absolute URL, on the instance
 * @param maxBytes {int} the largest reply accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the body
 */
func fetchBytes(c as Client, url as string, maxBytes as int) {
    def current as string init $url;
    def hops as int init 0;
    while (true) {
        def headers as map of string to string init {"Accept": "*/*"};
        if (originOf($current) == originOf($c.url)) {
            $headers = authHeaders($c);
            $headers["Accept"] = "*/*";
        }
        def r as http.BytesResponse;
        try {
            $r = http.requestWithBytes(
                "GET",
                $current,
                $headers,
                "",
                idleMs($c),
                $maxBytes,
                $c.tls);
        } catch (e) {
            failTransport("GET " + $url, $e);
        }
        if (lists.contains([301, 302, 303, 307, 308], $r.status) and
            maps.has($r.headers, "location")) {
            if ($hops >= MAX_REDIRECTS) {
                throw Error{
                    kind: "limit",
                    message: "gitlab: GET " + $url + ": more than " +
                        convert.toString(MAX_REDIRECTS) + " redirects"
                };
            }
            def next as string init resolved($current, strings.trim($r.headers["location"]));
            def downgrade as bool init strings.startsWith($current, "https:") and
                not strings.startsWith($next, "https:");
            if ($downgrade) {
                fail("GET " + $url + ": refused a redirect from https to " + shown($next));
            }
            $current = $next;
            $hops = $hops + 1;
            continue;
        }
        if ($r.status < 200 or $r.status >= 300) {
            failStatus(
                "GET " + $url + ": " +
                    failureText(
                    $r.status,
                    $r.statusText,
                    convert.stringFromBytes("utf-8", $r.body)),
                $r.status);
        }
        return $r.body;
    }
    return convert.bytesFromString("utf-8", "");
}

/**
 * Download what a release link points at, when it lies on the instance
 * (a generic package file, an upload). The token is only sent to the
 * instance itself: a link elsewhere is refused.
 *
 * @param c {Client} the client
 * @param link {ReleaseLink} the link, from a `Release`
 * @param maxBytes {int} the largest file accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {GitlabError} kind `"gitlab"` on a link elsewhere, a network failure
 *   or a refusal
 * @throws {Error} kind `"limit"` for a file over `maxBytes`
 */
export func downloadAsset(c as Client, link as ReleaseLink, maxBytes as int) {
    if (not strings.startsWith($link.url, $c.url + "/")) {
        fail("the link " + shown($link.name) + " is not on " + $c.url + ": " + shown($link.url));
    }
    return fetchBytes($c, $link.url, $maxBytes);
}

/**
 * A branch from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Branch} the branch
 */
func branchFrom(d as json.Value) {
    return Branch{
        name: field($d, "/name"),
        sha: field($d, "/commit/id"),
        isProtected: flag($d, "/protected"),
        isDefault: flag($d, "/default"),
        isMerged: flag($d, "/merged")
    };
}

/**
 * A tag from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Tag} the tag
 */
func tagFrom(d as json.Value) {
    return Tag{
        name: field($d, "/name"),
        sha: field($d, "/commit/id"),
        message: field($d, "/message"),
        isProtected: flag($d, "/protected")
    };
}

/**
 * The branches of a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Branch} the branches
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func branches(c as Client, project as string) {
    def out as list of Branch init [];
    for (def d in getAll($c, projectPath($project) + "/repository/branches")) {
        $out[] = branchFrom($d);
    }
    return $out;
}

/**
 * Create a branch.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the new branch
 * @param from {string} the branch, tag or commit it starts at
 * @return {Branch} the new branch
 * @throws {GitlabError} kind `"gitlab"` on a bad name, when it exists or `from`
 *   does not (HTTP 400), or as `call`
 */
export func createBranch(c as Client, project as string, name as string, from as string) {
    encoded($name, "branch");
    encoded($from, "ref");
    def doc as string init bodyOf({"branch": $name, "ref": $from}, {});
    return branchFrom(call($c, "POST", projectPath($project) + "/repository/branches", $doc));
}

/**
 * Delete a branch.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the branch
 * @throws {GitlabError} kind `"gitlab"` when it is protected or the default
 *   branch, or as `call`
 */
export func deleteBranch(c as Client, project as string, name as string) {
    def path as string init projectPath($project) + "/repository/branches/" +
        encoded($name, "branch");
    call($c, "DELETE", $path, "");
}

/**
 * The tags of a project, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {list of Tag} the tags
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func tags(c as Client, project as string) {
    def out as list of Tag init [];
    for (def d in getAll($c, projectPath($project) + "/repository/tags")) {
        $out[] = tagFrom($d);
    }
    return $out;
}

/**
 * Create a tag.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the tag, e.g. `v1.2.0`
 * @param target {string} the branch, tag or commit to tag
 * @param message {string} the annotation; "" for a lightweight tag
 * @return {Tag} the new tag
 * @throws {GitlabError} kind `"gitlab"` on a bad name, when it exists (HTTP 400),
 *   or as `call`
 */
export func createTag(
    c as Client,
    project as string,
    name as string,
    target as string,
    message as string) {
    encoded($name, "tag");
    encoded($target, "ref");
    def doc as string init bodyOf({"tag_name": $name, "ref": $target, "message": $message}, {});
    return tagFrom(call($c, "POST", projectPath($project) + "/repository/tags", $doc));
}

/**
 * Delete a tag. A release of it stays.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the tag
 * @throws {GitlabError} kind `"gitlab"` when it is protected, or as `call`
 */
export func deleteTag(c as Client, project as string, name as string) {
    call($c, "DELETE", projectPath($project) + "/repository/tags/" + encoded($name, "tag"), "");
}

/**
 * Read a file from a repository. A file kept in Git LFS comes as its
 * content, not as the pointer.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the file, e.g. `docs/index.md`
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param maxBytes {int} the largest file accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or on
 *   a network failure
 * @throws {Error} kind `"limit"` for a file over `maxBytes`
 */
export func readFile(
    c as Client,
    project as string,
    path as string,
    ref as string,
    maxBytes as int) {
    def url as string init $c.url + "/api/v4" + projectPath($project) + "/repository/files/" +
        encoded($path, "file path") +
        "/raw?lfs=true";
    if ($ref != "") {
        $url = $url + "&ref=" + encoded($ref, "ref");
    }
    return fetchBytes($c, $url, $maxBytes);
}

/**
 * The branch a commit goes to: the one given, or the default branch.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param branch {string} the branch; "" for the default branch
 * @return {string} the branch
 */
func branchOf(c as Client, project as string, branch as string) {
    if ($branch != "") {
        encoded($branch, "branch");
        return $branch;
    }
    def name as string init field(call($c, "GET", projectPath($project), ""), "/default_branch");
    if ($name == "") {
        fail("the project " + shown($project) + " has no default branch; name one");
    }
    return $name;
}

/**
 * Whether a file exists on a branch, from its metadata.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the file
 * @param branch {string} the branch
 * @return {bool} whether it exists
 */
func fileExists(c as Client, project as string, path as string, branch as string) {
    def url as string init projectPath($project) + "/repository/files/" +
        encoded($path, "file path") +
        "?ref=" + encoded($branch, "branch");
    try {
        exchange($c, "HEAD", $url, "");
    } catch (e) {
        # a missing file is a 404 for this HEAD; anything else is a failure
        if ($e.kind != ERROR_KIND or $e.status != 404) {
            throw $e;
        }
        return false;
    }
    return true;
}

/**
 * Commit one file action through the commits API.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param branch {string} the branch
 * @param message {string} the commit message
 * @param action {json.Value} the action
 * @return {string} the new commit's SHA
 */
func commitAction(
    c as Client,
    project as string,
    branch as string,
    message as string,
    action as json.Value) {
    def doc as json.Value init objectOf({"branch": $branch, "commit_message": $message}, {});
    $doc = json.set($doc, "/actions", json.append(json.list(), "", $action));
    def path as string init projectPath($project) + "/repository/commits";
    return field(call($c, "POST", $path, json.encode($doc)), "/id");
}

/**
 * Create or replace a file with a commit of its own.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the file, e.g. `data/version.txt`
 * @param data {bytes} the new content
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {GitlabError} kind `"gitlab"` on an empty message or a bad path, or
 *   as `call`; an unchanged file is no error (GitLab commits it anyway)
 */
export func writeFile(
    c as Client,
    project as string,
    path as string,
    data as bytes,
    message as string,
    branch as string) {
    if (strings.trim($message) == "") {
        fail("a commit needs a message");
    }
    encoded($path, "file path");
    def onto as string init branchOf($c, $project, $branch);
    def verb as string init "create";
    if (fileExists($c, $project, $path, $onto)) {
        $verb = "update";
    }
    def action as json.Value init objectOf(
        {
            "action": $verb,
            "file_path": $path,
            "content": encoding.toText("base64", $data),
            "encoding": "base64"
        },
        {});
    return commitAction($c, $project, $onto, $message, $action);
}

/**
 * Delete a file with a commit of its own.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the file
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {GitlabError} kind `"gitlab"` on an empty message, when the file does
 *   not exist (HTTP 400), or as `call`
 */
export func deleteFile(
    c as Client,
    project as string,
    path as string,
    message as string,
    branch as string) {
    if (strings.trim($message) == "") {
        fail("a commit needs a message");
    }
    encoded($path, "file path");
    def onto as string init branchOf($c, $project, $branch);
    def action as json.Value init objectOf({"action": "delete", "file_path": $path}, {});
    return commitAction($c, $project, $onto, $message, $action);
}

/**
 * The entries of the repository tree under a path.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the directory; "" for the root
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param recursive {bool} also the entries of every subdirectory
 * @return {list of Entry} the entries
 */
func treeOf(c as Client, project as string, path as string, ref as string, recursive as bool) {
    def url as string init projectPath($project) + "/repository/tree?pagination=keyset";
    if ($recursive) {
        $url = $url + "&recursive=true";
    }
    if ($path != "") {
        $url = $url + "&path=" + encoded($path, "directory");
    }
    if ($ref != "") {
        $url = $url + "&ref=" + encoded($ref, "ref");
    }
    def out as list of Entry init [];
    for (def d in getAll($c, $url)) {
        $out[] = Entry{
            name: field($d, "/name"),
            path: field($d, "/path"),
            type: field($d, "/type"),
            mode: field($d, "/mode"),
            sha: field($d, "/id")
        };
    }
    return $out;
}

/**
 * The entries of a directory in a repository.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the directory; "" for the root
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @return {list of Entry} the entries
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or as
 *   `getAll`
 */
export func listDirectory(c as Client, project as string, path as string, ref as string) {
    return treeOf($c, $project, $path, $ref, false);
}

/**
 * Every file and directory below a path, at any depth.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param path {string} the directory; "" for the root
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @return {list of Entry} the entries
 * @throws {GitlabError} kind `"gitlab"` when it does not exist (HTTP 404), or as
 *   `getAll`
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func listTree(c as Client, project as string, path as string, ref as string) {
    return treeOf($c, $project, $path, $ref, true);
}

/**
 * A commit from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Commit} the commit
 */
func commitFrom(d as json.Value) {
    return Commit{
        sha: field($d, "/id"),
        title: field($d, "/title"),
        message: field($d, "/message"),
        author: field($d, "/author_name"),
        authorEmail: field($d, "/author_email"),
        date: field($d, "/authored_date"),
        parents: namesAt($d, "/parent_ids", ""),
        webUrl: field($d, "/web_url")
    };
}

/**
 * The commits reachable from a ref, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param path {string} only commits that touch this file or directory; ""
 *   for all
 * @return {list of Commit} the commits
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func commits(c as Client, project as string, ref as string, path as string) {
    def url as string init projectPath($project) + "/repository/commits?with_stats=false";
    if ($ref != "") {
        $url = $url + "&ref_name=" + encoded($ref, "ref");
    }
    if ($path != "") {
        $url = $url + "&path=" + encoded($path, "file path");
    }
    def out as list of Commit init [];
    for (def d in getAll($c, $url)) {
        $out[] = commitFrom($d);
    }
    return $out;
}

/**
 * One commit.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param sha {string} the commit SHA, or a branch or tag
 * @return {Commit} the commit
 * @throws {GitlabError} kind `"gitlab"` when there is none (HTTP 404), or as
 *   `call`
 */
export func commit(c as Client, project as string, sha as string) {
    def path as string init projectPath($project) + "/repository/commits/" +
        encoded($sha, "commit") +
        "?stats=false";
    return commitFrom(call($c, "GET", $path, ""));
}

/**
 * A commit status from a reply.
 *
 * @param d {json.Value} the reply
 * @return {CommitStatus} the status
 */
func statusFrom(d as json.Value) {
    return CommitStatus{
        id: numberAt($d, "/id"),
        name: field($d, "/name"),
        status: field($d, "/status"),
        description: field($d, "/description"),
        targetUrl: field($d, "/target_url"),
        author: field($d, "/author/username"),
        ref: field($d, "/ref"),
        created: field($d, "/created_at")
    };
}

/**
 * Check a commit SHA.
 *
 * @param sha {string} the SHA
 * @return {string} the SHA
 */
func checkSha(sha as string) {
    if (not regex.matches('^[0-9a-f]{7,64}$', $sha)) {
        fail("a commit SHA is hexadecimal, got " + shown($sha));
    }
    return $sha;
}

/**
 * Set a status on a commit, as an outside CI system reports a check. A new
 * status for the same name and ref replaces the old one.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param sha {string} the commit SHA
 * @param state {string} one of `STATUS_STATES`
 * @param name {string} which check it is, e.g. `ci/build`; "" for `default`
 * @param description {string} a short text; "" for none
 * @param targetUrl {string} where the details are; "" for none
 * @return {CommitStatus} the status
 * @throws {GitlabError} kind `"gitlab"` on another state, a bad SHA, a move
 *   GitLab does not allow, such as `success` to `pending` (HTTP 400), or as
 *   `call`
 * @example
 *   gitlab.setCommitStatus($c, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);
 */
export func setCommitStatus(
    c as Client,
    project as string,
    sha as string,
    state as string,
    name as string,
    description as string,
    targetUrl as string) {
    if (not lists.contains(STATUS_STATES, $state)) {
        fail("a commit status is one of " + strings.join(STATUS_STATES, ", ") + ", got " +
            shown($state));
    }
    def doc as string init bodyOf(
        {
            "state": $state,
            "name": $name,
            "description": $description,
            "target_url": $targetUrl
        },
        {});
    def path as string init projectPath($project) + "/statuses/" + checkSha($sha);
    return statusFrom(call($c, "POST", $path, $doc));
}

/**
 * Every status set on a commit, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param sha {string} the commit SHA
 * @return {list of CommitStatus} the statuses
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func commitStatuses(c as Client, project as string, sha as string) {
    def path as string init projectPath($project) + "/repository/commits/" + checkSha($sha) +
        "/statuses?all=true";
    def out as list of CommitStatus init [];
    for (def d in getAll($c, $path)) {
        $out[] = statusFrom($d);
    }
    return $out;
}

# The states from worst to best, for `combinedStatus`; one not listed counts
# as `pending`.
def const STATUS_ORDER as list of string init [
    "failed",
    "canceled",
    "running",
    "pending",
    "created",
    "manual",
    "success",
    "skipped"
];

/**
 * The rank of a state in `STATUS_ORDER`, 0 the worst.
 *
 * @param state {string} the state
 * @return {int} the rank
 */
func statusRank(state as string) {
    def i as int init 0;
    for (def s in STATUS_ORDER) {
        if ($s == $state) {
            return $i;
        }
        $i = $i + 1;
    }
    return statusRank("pending");
}

/**
 * The combined status of a commit: the latest status per name, and the
 * worst of them (`failed`, `canceled`, `running`, `pending`, `created`,
 * `manual`, `success`, `skipped`, worst first).
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param sha {string} the commit SHA
 * @return {CombinedStatus} the combined status
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func combinedStatus(c as Client, project as string, sha as string) {
    def path as string init projectPath($project) + "/repository/commits/" + checkSha($sha) +
        "/statuses";
    def out as list of CommitStatus init [];
    def worst as string init "";
    for (def d in getAll($c, $path)) {
        def s as CommitStatus init statusFrom($d);
        $out[] = $s;
        if ($worst == "" or statusRank($s.status) < statusRank($worst)) {
            $worst = $s.status;
        }
    }
    return CombinedStatus{status: $worst, statuses: $out};
}

/**
 * A pipeline from a reply.
 *
 * @param d {json.Value} the reply
 * @return {Pipeline} the pipeline
 */
func pipelineFrom(d as json.Value) {
    return Pipeline{
        id: numberAt($d, "/id"),
        iid: numberAt($d, "/iid"),
        ref: field($d, "/ref"),
        sha: field($d, "/sha"),
        status: field($d, "/status"),
        source: field($d, "/source"),
        webUrl: field($d, "/web_url"),
        created: field($d, "/created_at"),
        updated: field($d, "/updated_at")
    };
}

/**
 * The API path of a pipeline.
 *
 * @param project {string} the id or full path
 * @param id {int} the pipeline id
 * @return {string} `/projects/<id>/pipelines/<id>`
 */
func pipelinePath(project as string, id as int) {
    return projectPath($project) + "/pipelines/" + idText($id, "a pipeline id");
}

/**
 * The pipelines of a project, newest first.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param ref {string} only those for this branch or tag; "" for all
 * @return {list of Pipeline} the pipelines
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 * @throws {Error} kind `"limit"` past `MAX_PAGES` pages
 */
export func pipelines(c as Client, project as string, ref as string) {
    def path as string init projectPath($project) + "/pipelines";
    if ($ref != "") {
        $path = $path + "?ref=" + encoded($ref, "ref");
    }
    def out as list of Pipeline init [];
    for (def d in getAll($c, $path)) {
        $out[] = pipelineFrom($d);
    }
    return $out;
}

/**
 * One pipeline, with its current status.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the pipeline id
 * @return {Pipeline} the pipeline
 * @throws {GitlabError} kind `"gitlab"` when there is none (HTTP 404), or as
 *   `call`
 */
export func pipeline(c as Client, project as string, id as int) {
    return pipelineFrom(call($c, "GET", pipelinePath($project, $id), ""));
}

/**
 * The newest pipeline of a branch or tag.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param ref {string} the branch or tag; "" for the default branch
 * @return {Pipeline} the pipeline
 * @throws {GitlabError} kind `"gitlab"` when the ref's latest commit has none
 *   (HTTP 403 or 404), or as `call`
 */
export func latestPipeline(c as Client, project as string, ref as string) {
    def path as string init projectPath($project) + "/pipelines/latest";
    if ($ref != "") {
        $path = $path + "?ref=" + encoded($ref, "ref");
    }
    return pipelineFrom(call($c, "GET", $path, ""));
}

/**
 * Check a CI/CD variable name.
 *
 * @param name {string} the name
 * @return {string} the name
 */
func checkVariable(name as string) {
    if (not regex.matches('^[A-Za-z0-9_]{1,255}$', $name)) {
        fail("a variable name is 1 to 255 letters, digits and _, got " + shown($name));
    }
    return $name;
}

/**
 * Run a pipeline for a branch or tag, as the token's account.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param ref {string} the branch or tag
 * @param variables {map of string to string} variables for this run; `{}`
 *   for none
 * @return {Pipeline} the new pipeline
 * @throws {GitlabError} kind `"gitlab"` on a bad variable name, when the
 *   configuration creates no jobs or is invalid (HTTP 400), or as `call`
 */
export func runPipeline(
    c as Client,
    project as string,
    ref as string,
    variables as map of string to string) {
    encoded($ref, "ref");
    def entries as json.Value init json.list();
    for (def name in lists.sort(maps.keys($variables))) {
        def v as json.Value init json.set(json.map(), "/key", checkVariable($name));
        $entries = json.append($entries, "", json.set($v, "/value", $variables[$name]));
    }
    def doc as json.Value init json.set(json.map(), "/ref", $ref);
    $doc = json.set($doc, "/variables", $entries);
    return pipelineFrom(call($c, "POST", projectPath($project) + "/pipeline", json.encode($doc)));
}

/**
 * Run a pipeline with a pipeline trigger token, the way another project's
 * CI starts one. The token goes in the body; the client's own token is sent
 * too when it has one.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param triggerToken {string} the trigger token, made under Settings > CI/CD
 * @param ref {string} the branch or tag
 * @param variables {map of string to string} variables for this run; `{}`
 *   for none
 * @return {Pipeline} the new pipeline
 * @throws {GitlabError} kind `"gitlab"` on a bad token or variable name, a
 *   refused token (HTTP 404), or as `call`
 */
export func triggerPipeline(
    c as Client,
    project as string,
    triggerToken as string,
    ref as string,
    variables as map of string to string) {
    checkToken($triggerToken);
    encoded($ref, "ref");
    def vars as json.Value init json.map();
    for (def name in lists.sort(maps.keys($variables))) {
        $vars = json.set($vars, "/" + checkVariable($name), $variables[$name]);
    }
    def doc as json.Value init objectOf({"token": $triggerToken, "ref": $ref}, {});
    $doc = json.set($doc, "/variables", $vars);
    def path as string init projectPath($project) + "/trigger/pipeline";
    return pipelineFrom(call($c, "POST", $path, json.encode($doc)));
}

/**
 * Cancel the running jobs of a pipeline.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the pipeline id
 * @return {Pipeline} the pipeline
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func cancelPipeline(c as Client, project as string, id as int) {
    return pipelineFrom(call($c, "POST", pipelinePath($project, $id) + "/cancel", ""));
}

/**
 * Retry the failed and canceled jobs of a pipeline.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param id {int} the pipeline id
 * @return {Pipeline} the pipeline
 * @throws {GitlabError} kind `"gitlab"` as `call`
 */
export func retryPipeline(c as Client, project as string, id as int) {
    return pipelineFrom(call($c, "POST", pipelinePath($project, $id) + "/retry", ""));
}

/**
 * The CI/CD variables of a project.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @return {map of string to string} each variable's value by its name; a
 *   hidden variable's value is ""; a name set for several environments
 *   appears once, with one of its values
 * @throws {GitlabError} kind `"gitlab"` as `getAll`
 */
export func variables(c as Client, project as string) {
    def out as map of string to string init {};
    for (def d in getAll($c, projectPath($project) + "/variables")) {
        $out[field($d, "/key")] = field($d, "/value");
    }
    return $out;
}

# The query that picks a variable's every-environment (`*`) copy, so a
# variable of the same name scoped to one environment is left alone.
def const ALL_ENVIRONMENTS as string init "?filter%5Benvironment_scope%5D=%2A";

/**
 * Create or replace a CI/CD variable of a project, for every environment
 * (`environment_scope` `*`); a variable of the same name scoped to one
 * environment is left as it is. GitLab stores the value as given: there is
 * no client-side encryption.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the variable's name, e.g. `DEPLOY_REGION`
 * @param value {string} the value
 * @param masked {bool} hide it in job logs; GitLab then wants 8 or more
 *   characters without spaces
 * @throws {GitlabError} kind `"gitlab"` on a bad name, a value GitLab cannot
 *   mask (HTTP 400), or as `call`
 */
export func setVariable(
    c as Client,
    project as string,
    name as string,
    value as string,
    masked as bool) {
    def path as string init projectPath($project) + "/variables";
    def doc as json.Value init objectOf(
        {"key": checkVariable($name), "environment_scope": "*"},
        {"masked": $masked});
    $doc = json.set($doc, "/value", $value);
    try {
        call($c, "PUT", $path + "/" + $name + ALL_ENVIRONMENTS, json.encode($doc));
    } catch (e) {
        # a missing variable is a 404 for this PUT; anything else is a failure
        if ($e.kind != ERROR_KIND or $e.status != 404) {
            throw $e;
        }
        call($c, "POST", $path, json.encode($doc));
    }
}

/**
 * Delete the every-environment (`*`) CI/CD variable of a project, as
 * `setVariable` sets it; one of the same name scoped to one environment
 * stays.
 *
 * @param c {Client} the client
 * @param project {string} the id or full path
 * @param name {string} the variable's name
 * @throws {GitlabError} kind `"gitlab"` when there is none (HTTP 404), or as
 *   `call`
 */
export func deleteVariable(c as Client, project as string, name as string) {
    def path as string init projectPath($project) + "/variables/" + checkVariable($name) +
        ALL_ENVIRONMENTS;
    call($c, "DELETE", $path, "");
}

/**
 * The type of a node, `missing` when the pointer does not resolve. Jennifer
 * 0.25.0's `json.typeOf` throws for a missing member instead.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer; "" for the root
 * @return {string} `null`, `bool`, `int`, `float`, `string`, `list`, `map` or `missing`
 */
func kindAt(v as json.Value, ptr as string) {
    if ($ptr == "") {
        return json.typeOf($v);
    }
    if (not json.has($v, $ptr)) {
        return "missing";
    }
    return json.typeOf($v, $ptr);
}

/**
 * Read a node as text, whatever its type.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the text; "" for absent or `null`
 */
func field(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "string") {
        return json.asString($v, $ptr);
    } elseif ($kind == "int") {
        return convert.toString(json.asInt($v, $ptr));
    } elseif ($kind == "float") {
        return convert.toString(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return "true";
        }
        return "false";
    }
    return "";
}

/**
 * Read a node as an int: a number (truncated) or a numeric string.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 for absent, `null` or not numeric
 */
func numberAt(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "int") {
        return json.asInt($v, $ptr);
    } elseif ($kind == "float") {
        return convert.toInt(json.asFloat($v, $ptr));
    } elseif ($kind == "string") {
        try {
            return convert.toInt(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0;
        }
    }
    return 0;
}

/**
 * Read a flag: `true` or `"true"`.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the flag; false for absent or `null`
 */
func flag(v as json.Value, ptr as string) {
    return field($v, $ptr) == "true";
}

/**
 * The pointers of a list's elements.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the list's pointer
 * @return {list of string} `<ptr>/0`, `<ptr>/1`, ...; empty when it is no list
 */
func items(v as json.Value, ptr as string) {
    def out as list of string init [];
    if (kindAt($v, $ptr) != "list") {
        return $out;
    }
    def n as int init json.length($v, $ptr);
    def i as int init 0;
    while ($i < $n) {
        $out[] = $ptr + "/" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}
