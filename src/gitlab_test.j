# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for gitlab: jennifer test src/gitlab_test.j
 *
 * The checking and parsing helpers are tested directly. The requests go to an
 * `httpd` server on a loopback port that answers with canned GitLab replies
 * and hands back what it received.
 */
use httpd;
use task;
use testing;

/** A canned reply. */
def struct Reply {
    status as int,
    headers as map of string to string,
    body as string
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as string,
    token as string,
    authorization as string,
    jobToken as string,
    contentType as string,
    body as bytes
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: httpd.rawQuery($req),
            token: httpd.header($req, "PRIVATE-TOKEN"),
            authorization: httpd.header($req, "Authorization"),
            jobToken: httpd.header($req, "JOB-TOKEN"),
            contentType: httpd.header($req, "Content-Type"),
            body: httpd.body($req)
        };
        httpd.setHeader($req, "Content-Type", "application/json");
        for (def name in lists.sort(maps.keys($r.headers))) {
            httpd.setHeader($req, $name, $r.headers[$name]);
        }
        if (httpd.method($req) == "HEAD") {
            httpd.respond($req, $r.status, "");
        } else {
            httpd.respond($req, $r.status, $r.body);
        }
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of Seen init spawn {
        return serve($srv, $replies);
    };
    return Fake{srv: $srv, url: "http://" + httpd.address($srv), t: $t};
}

/**
 * Stop a fake server.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A 200 reply.
 *
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func ok(body as string) {
    return Reply{status: 200, headers: {}, body: $body};
}

/**
 * A reply with a status.
 *
 * @param status {int} the status
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func answer(status as int, body as string) {
    return Reply{status: $status, headers: {}, body: $body};
}

/**
 * A page of a list with its `X-Next-Page`.
 *
 * @param body {string} the JSON list
 * @param next {string} the next page; "" on the last
 * @return {Reply} the reply
 */
func pageOf(body as string, next as string) {
    return Reply{status: 200, headers: {"X-Next-Page": $next}, body: $body};
}

/**
 * A JSON list of `n` numbered objects.
 *
 * @param n {int} how many
 * @return {string} the JSON
 */
func entries(n as int) {
    def parts as list of string init [];
    def i as int init 0;
    while ($i < $n) {
        $parts[] = '{"id":' + convert.toString($i) + '}';
        $i = $i + 1;
    }
    return "[" + strings.join($parts, ",") + "]";
}

/**
 * A client for a fake server with a token.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func tokenClient(f as Fake) {
    return withToken(client($f.url), "t0k3n");
}

/**
 * A request body as JSON.
 *
 * @param s {Seen} the request
 * @return {json.Value} the body
 */
func bodyJson(s as Seen) {
    return json.decode(convert.stringFromBytes("utf-8", $s.body));
}

/**
 * The message of the deck's error.
 *
 * @param e {GitlabError} the error
 * @return {string} its message
 */
func messageOf(e as GitlabError) {
    testing.assertEqual($e.kind, ERROR_KIND);
    return $e.message;
}

/**
 * Fail a test whose call was meant to throw.
 */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

def const PROJECT as string init '{"id":7,"name":"App","path":"app","path_with_namespace":' +
    '"grp/sub/app","namespace":{"full_path":"grp/sub"},"description":"An app",' +
    '"visibility":"private","archived":false,"default_branch":"main",' +
    '"web_url":"https://gl.example.com/grp/sub/app",' +
    '"http_url_to_repo":"https://gl.example.com/grp/sub/app.git",' +
    '"ssh_url_to_repo":"git@gl.example.com:grp/sub/app.git","star_count":3,"forks_count":1,' +
    '"open_issues_count":2,"last_activity_at":"2026-11-03T10:00:00Z"}';

def const ISSUE as string init '{"id":900,"iid":12,"title":"Crash on start",' +
    '"description":"It crashes.","state":"opened","author":{"username":"ada"},' +
    '"labels":["bug","p1"],"assignees":[{"username":"bob"}],"milestone":{"title":"1.0"},' +
    '"user_notes_count":4,"confidential":false,"created_at":"2026-11-01T09:00:00Z",' +
    '"updated_at":"2026-11-02T09:00:00Z","closed_at":null,' +
    '"web_url":"https://gl.example.com/grp/sub/app/-/issues/12"}';

def const MR as string init '{"id":501,"iid":15,"title":"Fix crash","description":"Fixes #12",' +
    '"state":"opened","author":{"username":"bob"},"source_branch":"fix/crash",' +
    '"target_branch":"main","sha":"abc1234","draft":false,' +
    '"detailed_merge_status":"mergeable","merge_commit_sha":null,"squash_commit_sha":null,' +
    '"web_url":"https://gl.example.com/grp/sub/app/-/merge_requests/15",' +
    '"created_at":"2026-11-01T09:00:00Z","merged_at":null}';

def const RELEASE as string init '{"tag_name":"v1.2.0","name":"1.2.0","description":"Notes",' +
    '"author":{"username":"ada"},"commit":{"id":"abc1234"},' +
    '"created_at":"2026-11-01T09:00:00Z","released_at":"2026-11-01T09:00:00Z",' +
    '"upcoming_release":false,' +
    '"_links":{"self":"https://gl.example.com/grp/sub/app/-/releases/v1.2.0"},' +
    '"assets":{"count":5,"sources":[{"format":"zip","url":"https://gl.example.com/a.zip"}],' +
    '"links":[{"id":3,"name":"app.tar.gz","url":"https://gl.example.com/x/app.tar.gz",' +
    '"direct_asset_url":' +
    '"https://gl.example.com/grp/sub/app/-/releases/v1.2.0/downloads/app.tar.gz",' +
    '"link_type":"package"}]}}';

func testBaseUrl() {
    testing.assertEqual(client("gitlab.com").url, "https://gitlab.com");
    testing.assertEqual(client("git.example.com:8443/").url, "https://git.example.com:8443");
    testing.assertEqual(
        client("https://example.com/gitlab/api/v4/").url,
        "https://example.com/gitlab");
    testing.assertEqual(client("http://localhost:8929").url, "http://localhost:8929");
    testing.assertEqual(client("gitlab.com").authHeader, "PRIVATE-TOKEN");
    try {
        client(" ");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: the host is empty");
    }
    for (def bad in ["ftp://x", "https://x//y", "x?y", "user@x", "https://a b"]) {
        try {
            client($bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.status, 0);
            testing.assertContains(messageOf($e), "an address");
        }
    }
}

func testClientSettings() {
    def c as Client init withRetries(withTimeout(withInsecure(client("gitlab.com")), 5000), 2);
    testing.assertTrue($c.tls.skipVerify);
    testing.assertEqual($c.timeoutMs, 5000);
    testing.assertEqual($c.retries, 2);
    $c = withCaCert($c, convert.bytesFromString("utf-8", "PEM"));
    testing.assertFalse($c.tls.skipVerify);
    testing.assertEqual(authHeaders(withToken($c, "abc"))["PRIVATE-TOKEN"], "abc");
    testing.assertEqual(authHeaders(withBearer($c, "abc"))["Authorization"], "Bearer abc");
    testing.assertEqual(authHeaders(withJobToken($c, "abc"))["JOB-TOKEN"], "abc");
    testing.assertFalse(maps.has(authHeaders($c), "PRIVATE-TOKEN"));
    for (def bad in ["", "abc\r\nX-Evil: 1", "a b"]) {
        try {
            withToken($c, $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a token is not empty");
        }
    }
    try {
        withRetries($c, -1);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "retry count");
    }
    try {
        withTimeout($c, -1);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "timeout");
    }
}

func testProjectsAndGroupsAreEncodedOnce() {
    testing.assertEqual(projectPath("42"), "/projects/42");
    testing.assertEqual(projectPath("grp/sub/deep/app.js"), "/projects/grp%2Fsub%2Fdeep%2Fapp.js");
    testing.assertEqual(groupPath("grp"), "/groups/grp");
    testing.assertEqual(groupPath("grp/sub"), "/groups/grp%2Fsub");
    def badProjects as list of string init ["app", "grp/app/", "../app", "grp/..", "grp/a b"];
    for (def bad in lists.concat($badProjects, ["grp//app", "-x/app", "042"])) {
        try {
            projectPath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a project is a numeric id");
        }
    }
    for (def bad in ["", "grp/", "a%2Fb"]) {
        try {
            groupPath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a group is");
        }
    }
    testing.assertEqual(encoded("docs/a b.md", "file path"), "docs%2Fa%20b.md");
    testing.assertEqual(encoded("release/1.0", "tag"), "release%2F1.0");
    testing.assertEqual(encoded("v1.0+build", "tag"), "v1.0%2Bbuild");
    for (def bad in ["", "a/../b", "/a", "a//b", "a\nb", "a/"]) {
        try {
            encoded($bad, "file path");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a file path");
        }
    }
    for (def bad in ["version", "/a//b", "/a/../b", "/a b", "/a#x"]) {
        try {
            ensurePath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "an API path");
        }
    }
    def long as string init strings.repeat("x", 100) + convert.fromCodepoint(10);
    try {
        projectPath($long);
        missed();
    } catch (e) {
        testing.assertFalse(strings.contains(messageOf($e), convert.fromCodepoint(10)));
        testing.assertContains(messageOf($e), "...");
    }
}

func testFailureText() {
    testing.assertEqual(
        failureText(404, "Not Found", '{"message":"404 Project Not Found"}'),
        "HTTP 404: Project Not Found");
    testing.assertEqual(
        failureText(
            400,
            "Bad Request",
            '{"message":{"name":["has already been taken"],"path":["is too short","is bad"]}}'),
        "HTTP 400: name has already been taken; path is too short, is bad");
    testing.assertEqual(
        failureText(400, "Bad Request", '{"message":{"base":["Cannot move"]}}'),
        "HTTP 400: Cannot move");
    testing.assertEqual(
        failureText(400, "", '{"message":{"error":"recognized as spam"}}'),
        "HTTP 400: recognized as spam");
    testing.assertEqual(
        failureText(400, "", '{"error":"title is missing"}'),
        "HTTP 400: title is missing");
    testing.assertEqual(
        failureText(401, "", '{"error":"invalid_token","error_description":"Token was revoked"}'),
        "HTTP 401: invalid_token: Token was revoked");
    testing.assertEqual(failureText(502, "Bad Gateway", "<html>"), "HTTP 502: Bad Gateway");
    testing.assertEqual(failureText(500, "", ""), "HTTP 500");
    # The server's text stays one bounded line.
    def said as string init failureText(
        500,
        "",
        '{"message":"line one\nforged: line two ' + strings.repeat("x", 500) + '"}');
    testing.assertFalse(strings.contains($said, convert.fromCodepoint(10)));
    testing.assertContains($said, "line one?forged");
    testing.assertTrue(len($said) < 250);
}

func testIdleTimeout() {
    # http's raw and bytes requests take 0 as no timeout at all.
    testing.assertEqual(idleMs(client("x")), 30000);
    testing.assertEqual(idleMs(withTimeout(client("x"), 500)), 500);
}

func testLinks() {
    testing.assertEqual(
        nextLink('<https://x/api/v4/a?page=1>; rel="first", ' +
            '<https://x/api/v4/a?page_token=Z>; rel="next"'),
        "https://x/api/v4/a?page_token=Z");
    testing.assertEqual(nextLink('<https://x/a>; rel="last"'), "");
    testing.assertEqual(nextLink(""), "");
    testing.assertEqual(originOf("HTTPS://Gitlab.com:443/api/v4"), "https://gitlab.com:443");
    testing.assertEqual(originOf("/api/v4"), "");
    testing.assertEqual(resolved("https://a.example/x/y?z", "/b"), "https://a.example/b");
    testing.assertEqual(resolved("https://a.example/x", "//b.example/c"), "https://b.example/c");
    testing.assertEqual(resolved("https://a.example/x", "http://c/d"), "http://c/d");
    try {
        resolved("https://a.example/x", "relative");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is not absolute");
    }
}

func testCallSendsTheToken() {
    def f as Fake init fake([
        ok('{"version":"19.5.5","revision":"342e9f9"}'),
        ok('{"id":1,"username":"root","is_admin":true,"state":"active"}'),
        ok('{"id":1,"username":"root"}'),
        ok('{"id":1,"username":"root"}')
    ]);
    def c as Client init tokenClient($f);
    testing.assertEqual(version($c), "19.5.5");
    def u as User init currentUser($c);
    currentUser(withBearer(client($f.url), "oauth"));
    currentUser(withJobToken(client($f.url), "job"));
    def seen as list of Seen init finish($f);
    testing.assertEqual($u.username, "root");
    testing.assertTrue($u.isAdmin);
    testing.assertEqual($seen[0].method, "GET");
    testing.assertEqual($seen[0].path, "/api/v4/version");
    testing.assertEqual($seen[0].token, "t0k3n");
    testing.assertEqual($seen[0].authorization, "");
    testing.assertEqual($seen[1].path, "/api/v4/user");
    testing.assertEqual($seen[2].authorization, "Bearer oauth");
    testing.assertEqual($seen[2].token, "");
    testing.assertEqual($seen[3].jobToken, "job");
}

func testRefusalsNameTheRequest() {
    def f as Fake init fake([answer(404, '{"message":"404 Project Not Found"}')]);
    try {
        project(tokenClient($f), "grp/sub/missing");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "gitlab: GET /projects/grp%2Fsub%2Fmissing: HTTP 404: Project Not Found");
        # the status is a field: no need to read it out of the message
        testing.assertEqual($e.status, 404);
    }
    def seen as list of Seen init finish($f);
    # httpd decodes the path once: an encoding done twice would show as %2F
    testing.assertEqual($seen[0].path, "/api/v4/projects/grp/sub/missing");
    for (def verb in ["TRACE", "HEAD", "head"]) {
        try {
            call(client("x"), $verb, "/version", "");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "unsupported method");
        }
    }
}

func testGetAllFollowsTheNextPage() {
    def f as Fake init fake([pageOf(entries(100), "2"), pageOf(entries(2), "")]);
    def got as list of json.Value init getAll(tokenClient($f), "/projects/7/issues?state=opened");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($got), 102);
    testing.assertEqual(len($seen), 2);
    testing.assertEqual($seen[0].query, "state=opened&per_page=100");
    testing.assertEqual($seen[1].query, "state=opened&per_page=100&page=2");
    # an empty page ends the list whatever the headers say
    def g as Fake init fake([pageOf("[]", "2")]);
    testing.assertEqual(len(getAll(tokenClient($g), "/user/projects")), 0);
    finish($g);
    def h as Fake init fake([ok('{"not":"a list"}')]);
    try {
        getAll(tokenClient($h), "/user/projects");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: GET /user/projects: the reply is not a list");
    }
    finish($h);
    def k as Fake init fake([pageOf(entries(1), "two")]);
    try {
        getAll(tokenClient($k), "/user/projects");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "X-Next-Page is not a page number");
    }
    finish($k);
}

func testGetAllFollowsAKeysetLink() {
    # the link names the server's own URL, so the fake needs its address first
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def url as string init "http://" + httpd.address($srv);
    def next as string init "<" + $url +
        '/api/v4/projects/7/repository/tree?page_token=abc%3D&pagination=keyset&per_page=100>; ' +
        'rel="next"';
    def t as task of list of Seen init spawn {
        return serve(
            $srv,
            [Reply{status: 200, headers: {"Link": $next}, body: entries(100)}, ok(entries(3))]);
    };
    def got as list of json.Value init getAll(
        withToken(client($url), "t0k3n"),
        "/projects/7/repository/tree?pagination=keyset");
    def seen as list of Seen init finish(Fake{srv: $srv, url: $url, t: $t});
    testing.assertEqual(len($got), 103);
    testing.assertEqual($seen[1].query, "page_token=abc%3D&pagination=keyset&per_page=100");
    testing.assertEqual($seen[1].token, "t0k3n");
    # a next link off the instance is refused, not followed
    def g as Fake init fake([
        Reply{
            status: 200,
            headers: {"Link": '<https://elsewhere.example/api/v4/x?page_token=z>; rel="next"'},
            body: entries(1)
        }
    ]);
    try {
        getAll(tokenClient($g), "/projects/7/repository/tree?pagination=keyset");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "refused to follow");
        testing.assertEqual($e.status, 0);
    }
    finish($g);
}

func testRedirectsStayOnTheApi() {
    def f as Fake init fake([
        Reply{status: 302, headers: {"Location": "/api/v4/projects/7/releases/v1.2.0"}, body: ""},
        ok(RELEASE)
    ]);
    def r as Release init latestRelease(tokenClient($f), "grp/sub/app");
    def seen as list of Seen init finish($f);
    testing.assertEqual($r.tag, "v1.2.0");
    testing.assertEqual($seen[0].path, "/api/v4/projects/grp/sub/app/releases/permalink/latest");
    testing.assertEqual($seen[1].path, "/api/v4/projects/7/releases/v1.2.0");
    testing.assertEqual($seen[1].token, "t0k3n");
    def g as Fake init fake([
        Reply{status: 302, headers: {"Location": "https://evil.example/api/v4/x"}, body: ""}
    ]);
    try {
        latestRelease(tokenClient($g), "7");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "refused to follow");
    }
    finish($g);
    # a write is not redirected
    def h as Fake init fake([
        Reply{status: 307, headers: {"Location": "/api/v4/projects/8/issues"}, body: ""}
    ]);
    try {
        createIssue(tokenClient($h), "7", "x", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 307);
    }
    finish($h);
}

func testProjects() {
    def f as Fake init fake([
        ok(PROJECT),
        pageOf("[" + PROJECT + "]", ""),
        pageOf("[" + PROJECT + "]", ""),
        ok('{"id":33,"full_path":"grp/sub"}'),
        ok(PROJECT),
        ok(PROJECT),
        ok(PROJECT),
        ok(PROJECT),
        ok(""),
        pageOf("[]", "")
    ]);
    def c as Client init tokenClient($f);
    def p as Project init project($c, "grp/sub/app");
    groupProjects($c, "grp", true);
    searchProjects($c, "my app");
    createProject($c, "grp/sub", "app", "An app", "private");
    setArchived($c, "7", true);
    setDefaultBranch($c, "7", "release/1");
    forkProject($c, "7", "grp/forks", "app2");
    deleteProject($c, "7");
    search($c, "7", "issues", "crash");
    def seen as list of Seen init finish($f);
    testing.assertEqual($p.fullPath, "grp/sub/app");
    testing.assertEqual($p.namespace, "grp/sub");
    testing.assertEqual($p.visibility, "private");
    testing.assertEqual($p.stars, 3);
    testing.assertEqual($p.forkedFrom, "");
    testing.assertEqual($seen[1].path, "/api/v4/groups/grp/projects");
    testing.assertEqual($seen[1].query, "include_subgroups=true&per_page=100");
    testing.assertEqual($seen[2].query, "search=my%20app&per_page=100");
    testing.assertEqual($seen[3].path, "/api/v4/namespaces/grp/sub");
    def made as json.Value init bodyJson($seen[4]);
    testing.assertEqual(json.asInt($made, "/namespace_id"), 33);
    testing.assertEqual(json.asString($made, "/path"), "app");
    testing.assertEqual(json.asString($made, "/visibility"), "private");
    testing.assertEqual($seen[5].path, "/api/v4/projects/7/archive");
    testing.assertEqual(json.asString(bodyJson($seen[6]), "/default_branch"), "release/1");
    testing.assertEqual($seen[7].path, "/api/v4/projects/7/fork");
    testing.assertEqual(json.asString(bodyJson($seen[7]), "/namespace_path"), "grp/forks");
    testing.assertEqual($seen[8].method, "DELETE");
    testing.assertEqual($seen[9].query, "scope=issues&search=crash&per_page=100");
    for (def bad in ["public!", ""]) {
        try {
            createProject(client("x"), "", "app", "", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "visibility");
        }
    }
    try {
        search(client("x"), "", "issues; drop", "x");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "search scope");
    }
}

func testGroupsMembersAndHooks() {
    def f as Fake init fake([
        ok('{"id":3,"name":"Sub","path":"sub","full_path":"grp/sub","parent_id":2}'),
        pageOf('[{"id":4,"full_path":"grp/sub/x"}]', ""),
        ok('[{"id":9,"username":"bob"}]'),
        answer(409, '{"message":"Member already exists"}'),
        ok('{"id":9,"username":"bob","access_level":40}'),
        pageOf(
            '[{"id":1,"url":"https://h","push_events":true,"merge_requests_events":true,' +
                '"issues_events":false,"enable_ssl_verification":true}]',
            ""),
        ok('{"id":2,"url":"https://h","push_events":true}')
    ]);
    def c as Client init tokenClient($f);
    def g as Group init group($c, "grp/sub");
    def subs as list of Group init subgroups($c, "grp/sub");
    def m as Member init addMember($c, "7", "bob", ACCESS_MAINTAINER);
    def hs as list of Hook init hooks($c, "7");
    createHook($c, "7", "https://h", "s3", ["push", "tag_push"]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($g.parentId, 2);
    testing.assertEqual($seen[0].path, "/api/v4/groups/grp/sub");
    testing.assertEqual($subs[0].fullPath, "grp/sub/x");
    testing.assertEqual($seen[2].query, "username=bob");
    testing.assertEqual(json.asInt(bodyJson($seen[3]), "/user_id"), 9);
    testing.assertEqual($seen[4].method, "PUT");
    testing.assertEqual($seen[4].path, "/api/v4/projects/7/members/9");
    testing.assertEqual($m.accessLevel, 40);
    testing.assertEqual($hs[0].events, ["push", "merge_requests"]);
    def hook as json.Value init bodyJson($seen[6]);
    testing.assertTrue(json.asBool($hook, "/push_events"));
    testing.assertTrue(json.asBool($hook, "/tag_push_events"));
    testing.assertFalse(json.asBool($hook, "/merge_requests_events"));
    testing.assertTrue(json.asBool($hook, "/enable_ssl_verification"));
    testing.assertEqual(json.asString($hook, "/token"), "s3");
    try {
        addMember(client("x"), "7", "bob", 35);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an access level");
    }
    for (def bad in [["push", "nope"], []]) {
        try {
            createHook(client("x"), "7", "https://h", "", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "hook");
        }
    }
    def u as Fake init fake([ok("[]")]);
    try {
        user(tokenClient($u), "ghost");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: there is no user \"ghost\"");
    }
    finish($u);
}

func testIdsBelowOneAreRefused() {
    def c as Client init client("x");
    def calls as list of string init [];
    for (def bad in [0, -1]) {
        for (def which in [
            "issue",
            "mergeRequest",
            "pipeline",
            "editNote",
            "deleteHook",
            "deleteLabel",
            "deleteMilestone",
            "deleteReleaseLink"
        ]) {
            try {
                if ($which == "issue") {
                    issue($c, "7", $bad);
                } elseif ($which == "mergeRequest") {
                    mergeRequest($c, "7", $bad);
                } elseif ($which == "pipeline") {
                    pipeline($c, "7", $bad);
                } elseif ($which == "editNote") {
                    editNote($c, "7", 1, $bad, "x");
                } elseif ($which == "deleteHook") {
                    deleteHook($c, "7", $bad);
                } elseif ($which == "deleteLabel") {
                    deleteLabel($c, "7", $bad);
                } elseif ($which == "deleteMilestone") {
                    deleteMilestone($c, "7", $bad);
                } else {
                    deleteReleaseLink($c, "7", "v1", $bad);
                }
                missed();
            } catch (e) {
                testing.assertEqual($e.kind, ERROR_KIND);
                testing.assertEqual($e.status, 0);
                testing.assertContains(
                    messageOf($e),
                    " is 1 or more, got " + convert.toString($bad));
                $calls[] = $which;
            }
        }
    }
    testing.assertEqual(len($calls), 16);
    try {
        setMilestone($c, "7", 1, -1);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: a milestone id is 0 (none) or more, got -1");
    }
}

func testIssuesAndNotes() {
    def f as Fake init fake([
        pageOf("[" + ISSUE + "]", ""),
        ok(ISSUE),
        ok(ISSUE),
        ok(ISSUE),
        ok(ISSUE),
        ok('[{"id":9,"username":"bob"}]'),
        ok(ISSUE),
        ok(ISSUE),
        ok(ISSUE),
        ok('{"id":5,"author":{"username":"ada"},"body":"hi","system":false}'),
        pageOf('[{"id":5,"body":"hi"},{"id":6,"body":"added label","system":true}]', "")
    ]);
    def c as Client init tokenClient($f);
    def all as list of Issue init issues($c, "grp/sub/app", "opened");
    createIssue($c, "grp/sub/app", "Crash", "It crashes.");
    closeIssue($c, "grp/sub/app", 12);
    setIssueLabels($c, "grp/sub/app", 12, ["bug", "p1"]);
    addIssueLabels($c, "grp/sub/app", 12, ["p2"]);
    setAssignees($c, "grp/sub/app", 12, ["bob"]);
    setMilestone($c, "grp/sub/app", 12, 0);
    editIssue($c, "grp/sub/app", 12, "", "New text");
    def n as Note init addNote($c, "grp/sub/app", 12, "hi");
    def ns as list of Note init notes($c, "grp/sub/app", 12);
    def seen as list of Seen init finish($f);
    def i as Issue init $all[0];
    testing.assertEqual($i.iid, 12);
    testing.assertEqual($i.state, "opened");
    testing.assertEqual($i.author, "ada");
    testing.assertEqual($i.labels, ["bug", "p1"]);
    testing.assertEqual($i.assignees, ["bob"]);
    testing.assertEqual($i.milestone, "1.0");
    testing.assertEqual($i.notes, 4);
    testing.assertEqual($i.closed, "");
    testing.assertEqual($seen[0].query, "state=opened&per_page=100");
    testing.assertEqual(json.asString(bodyJson($seen[1]), "/title"), "Crash");
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].path, "/api/v4/projects/grp/sub/app/issues/12");
    testing.assertEqual(json.asString(bodyJson($seen[2]), "/state_event"), "close");
    testing.assertEqual(json.asString(bodyJson($seen[3]), "/labels"), "bug,p1");
    testing.assertEqual(json.asString(bodyJson($seen[4]), "/add_labels"), "p2");
    testing.assertEqual(json.encode(bodyJson($seen[6])), '{"assignee_ids":[9]}');
    testing.assertEqual(json.encode(bodyJson($seen[7])), '{"milestone_id":0}');
    testing.assertEqual(json.encode(bodyJson($seen[8])), '{"description":"New text"}');
    testing.assertEqual($n.id, 5);
    testing.assertEqual($seen[10].query, "sort=asc&order_by=created_at&per_page=100");
    testing.assertTrue($ns[1].isSystem);
    for (def bad in ["open", "all "]) {
        try {
            issues(client("x"), "7", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a state is one of opened, closed, all");
        }
    }
    try {
        setIssueLabels(client("x"), "7", 1, ["a,b"]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "no comma");
    }
    try {
        editIssue(client("x"), "7", 1, "", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an edit changes");
    }
    # GitLab answers an empty project edit with a 400 listing every parameter.
    try {
        editProject(client("x"), "7", "", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an edit changes");
        testing.assertEqual($e.status, 0);
    }
}

func testLabelsAndMilestones() {
    def f as Fake init fake([
        ok('{"id":1,"name":"bug","color":"#ee0701","description":"A bug"}'),
        pageOf('[{"id":1,"name":"bug","color":"#ee0701"}]', ""),
        ok('{"id":4,"iid":1,"title":"1.0","state":"active","due_date":"2026-12-31"}'),
        ok('{"id":4,"iid":1,"title":"1.0","state":"closed"}'),
        pageOf("[]", ""),
        pageOf("[]", "")
    ]);
    def c as Client init tokenClient($f);
    def l as Label init createLabel($c, "7", "bug", "#ee0701", "A bug");
    labels($c, "7");
    def m as Milestone init createMilestone($c, "7", "1.0", "", "2026-12-31");
    def closed as Milestone init setMilestoneClosed($c, "7", 4, true);
    milestones($c, "7", "all");
    milestones($c, "7", "closed");
    def seen as list of Seen init finish($f);
    testing.assertEqual($l.color, "#ee0701");
    testing.assertEqual($m.dueDate, "2026-12-31");
    testing.assertEqual($closed.state, "closed");
    testing.assertEqual(json.asString(bodyJson($seen[3]), "/state_event"), "close");
    testing.assertEqual($seen[4].query, "per_page=100");
    testing.assertEqual($seen[5].query, "state=closed&per_page=100");
    try {
        createLabel(client("x"), "7", "bug", "red", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "#rrggbb");
    }
    try {
        createMilestone(client("x"), "7", "1.0", "", "31.12.2026");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "YYYY-MM-DD");
    }
}

func testMergeRequests() {
    def merged as string init strings.replace(
        strings.replace(MR, '"state":"opened"', '"state":"merged"'),
        '"merge_commit_sha":null',
        '"merge_commit_sha":"fff0000"');
    def f as Fake init fake([
        pageOf("[" + MR + "]", ""),
        ok(MR),
        ok($merged),
        ok('{"approved":true,"approved_by":[{"user":{"username":"ada"}}]}'),
        ok('{"approved":true,"approved_by":[{"user":{"username":"ada"}}],' +
            '"approvals_required":2,"approvals_left":1}'),
        pageOf('[{"old_path":"a","new_path":"b","renamed_file":true,"diff":"@@"}]', ""),
        ok(MR),
        answer(405, '{"message":"405 Method Not Allowed"}')
    ]);
    def c as Client init tokenClient($f);
    def all as list of MergeRequest init mergeRequests($c, "grp/sub/app", "merged");
    createMergeRequest($c, "grp/sub/app", "fix/crash", "main", "Fix crash", "");
    def done as MergeRequest init mergeMergeRequest($c, "grp/sub/app", 15, "abc1234", true, true);
    def a as Approvals init approveMergeRequest($c, "grp/sub/app", 15, "");
    def state as Approvals init approvals($c, "grp/sub/app", 15);
    def changes as list of ChangedFile init mergeRequestChanges($c, "grp/sub/app", 15);
    closeMergeRequest($c, "grp/sub/app", 15);
    try {
        mergeMergeRequest($c, "grp/sub/app", 15, "", false, false);
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 405);
        testing.assertContains(messageOf($e), "HTTP 405: Method Not Allowed");
    }
    def seen as list of Seen init finish($f);
    def m as MergeRequest init $all[0];
    testing.assertEqual($m.iid, 15);
    testing.assertEqual($m.sourceBranch, "fix/crash");
    testing.assertTrue($m.mergeable);
    testing.assertFalse($m.merged);
    testing.assertEqual($m.mergeSha, "");
    testing.assertEqual($seen[0].query, "state=merged&per_page=100");
    def made as json.Value init bodyJson($seen[1]);
    testing.assertEqual(json.asString($made, "/source_branch"), "fix/crash");
    testing.assertEqual(json.asString($made, "/target_branch"), "main");
    testing.assertFalse(json.has($made, "/description"));
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].path, "/api/v4/projects/grp/sub/app/merge_requests/15/merge");
    testing.assertEqual(
        json.encode(bodyJson($seen[2])),
        '{"sha":"abc1234","should_remove_source_branch":true,"squash":true}');
    testing.assertTrue($done.merged);
    testing.assertEqual($done.mergeSha, "fff0000");
    testing.assertEqual($a.approvedBy, ["ada"]);
    testing.assertEqual($seen[3].path, "/api/v4/projects/grp/sub/app/merge_requests/15/approve");
    testing.assertEqual($state.left, 1);
    testing.assertTrue($changes[0].isRenamed);
    testing.assertEqual($changes[0].newPath, "b");
    testing.assertEqual($seen[5].path, "/api/v4/projects/grp/sub/app/merge_requests/15/diffs");
    testing.assertEqual(json.asString(bodyJson($seen[6]), "/state_event"), "close");
    try {
        mergeMergeRequest(client("x"), "7", 1, "HEAD", false, false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a commit SHA");
    }
    try {
        mergeRequests(client("x"), "7", "open");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a state is one of");
    }
}

func testReleasesAndAssets() {
    def f as Fake init fake([
        pageOf("[" + RELEASE + "]", ""),
        ok(RELEASE),
        ok(RELEASE),
        Reply{status: 201, headers: {}, body: '{"message":"201 Created"}'},
        ok('{"id":8,"name":"app.tar.gz","url":"x","link_type":"package"}'),
        ok(""),
        ok("")
    ]);
    def c as Client init tokenClient($f);
    def all as list of Release init releases($c, "grp/sub/app");
    release($c, "grp/sub/app", "release/1.0");
    createRelease($c, "grp/sub/app", "v1.2.0", "main", "", "Notes");
    def link as ReleaseLink init uploadAsset(
        $c,
        "grp/sub/app",
        "v1.2.0",
        "app",
        "app.tar.gz",
        convert.bytesFromString("utf-8", "DATA"));
    deleteReleaseLink($c, "grp/sub/app", "v1.2.0", 8);
    deleteRelease($c, "grp/sub/app", "release/1.0");
    def seen as list of Seen init finish($f);
    def r as Release init $all[0];
    testing.assertEqual($r.tag, "v1.2.0");
    testing.assertEqual($r.author, "ada");
    testing.assertEqual($r.commitSha, "abc1234");
    testing.assertEqual($r.webUrl, "https://gl.example.com/grp/sub/app/-/releases/v1.2.0");
    testing.assertEqual($r.sources, ["https://gl.example.com/a.zip"]);
    testing.assertEqual($r.links[0].linkType, "package");
    testing.assertEqual($r.links[0].id, 3);
    testing.assertEqual($seen[1].path, "/api/v4/projects/grp/sub/app/releases/release/1.0");
    def made as json.Value init bodyJson($seen[2]);
    testing.assertEqual(json.asString($made, "/tag_name"), "v1.2.0");
    testing.assertEqual(json.asString($made, "/ref"), "main");
    testing.assertEqual($seen[3].method, "PUT");
    testing.assertEqual(
        $seen[3].path,
        "/api/v4/projects/grp/sub/app/packages/generic/app/v1.2.0/app.tar.gz");
    testing.assertEqual($seen[3].token, "t0k3n");
    testing.assertEqual($seen[3].contentType, "application/octet-stream");
    testing.assertEqual(convert.stringFromBytes("utf-8", $seen[3].body), "DATA");
    def linked as json.Value init bodyJson($seen[4]);
    testing.assertEqual(json.asString($linked, "/link_type"), "package");
    testing.assertEqual(
        json.asString($linked, "/url"),
        tokenClient($f).url +
            "/api/v4/projects/grp%2Fsub%2Fapp/packages/generic/app/v1.2.0/app.tar.gz");
    testing.assertEqual($link.id, 8);
    testing.assertEqual(
        $seen[5].path,
        "/api/v4/projects/grp/sub/app/releases/v1.2.0/assets/links/8");
    testing.assertEqual($seen[6].method, "DELETE");
    for (def bad in ["a b.tar", "~x", "../x", "x/y", ""]) {
        try {
            uploadPackageFile(
                client("x"),
                "7",
                "app",
                "1.0",
                $bad,
                convert.bytesFromString("utf-8", ""));
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "package file name");
        }
    }
    try {
        addReleaseLink(client("x"), "7", "v1", "docs", "ftp://x", "other");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "http:// or https://");
    }
    try {
        addReleaseLink(client("x"), "7", "v1", "docs", "https://x", "binary");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a link type");
    }
}

func testDownloadsKeepTheToken() {
    # the token goes to the instance, and not along a redirect to another origin
    def store as Fake init fake([
        Reply{status: 200, headers: {"Content-Type": "application/octet-stream"}, body: "BYTES"}
    ]);
    def f as Fake init fake([
        Reply{status: 302, headers: {"Location": $store.url + "/bucket/obj?sig=1"}, body: ""}
    ]);
    def c as Client init tokenClient($f);
    def link as ReleaseLink init ReleaseLink{
        id: 1,
        name: "app",
        url: $f.url + "/api/v4/projects/7/packages/generic/app/1.0/app",
        directAssetUrl: "",
        linkType: "package"
    };
    def data as bytes init downloadAsset($c, $link, 0);
    def asked as list of Seen init finish($f);
    def fetched as list of Seen init finish($store);
    testing.assertEqual(convert.stringFromBytes("utf-8", $data), "BYTES");
    testing.assertEqual($asked[0].token, "t0k3n");
    testing.assertEqual($fetched[0].path, "/bucket/obj");
    testing.assertEqual($fetched[0].token, "");
    testing.assertEqual($fetched[0].authorization, "");
    $link.url = "https://elsewhere.example/app";
    try {
        downloadAsset($c, $link, 0);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is not on");
    }
    def g as Fake init fake([ok("0123456789ABCDEF")]);
    $link.url = $g.url + "/api/v4/x";
    try {
        downloadAsset(tokenClient($g), $link, 8);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "gitlab: GET ");
    }
    finish($g);
}

func testFiles() {
    def f as Fake init fake([
        ok("RAW"),
        answer(404, '{"message":"404 File Not Found"}'),
        ok('{"id":"c0ffee1","title":"add"}'),
        ok(PROJECT),
        ok(""),
        ok('{"id":"c0ffee2"}'),
        ok('{"id":"c0ffee3"}')
    ]);
    def c as Client init tokenClient($f);
    def raw as bytes init readFile($c, "grp/sub/app", "docs/a b.md", "release/1", 0);
    def made as string init writeFile(
        $c,
        "grp/sub/app",
        "docs/new.md",
        convert.bytesFromString("utf-8", "hi"),
        "add",
        "main");
    def changed as string init writeFile(
        $c,
        "grp/sub/app",
        "README.md",
        convert.bytesFromString("utf-8", "x"),
        "edit",
        "");
    def gone as string init deleteFile($c, "7", "old.txt", "drop", "dev");
    def seen as list of Seen init finish($f);
    testing.assertEqual(convert.stringFromBytes("utf-8", $raw), "RAW");
    testing.assertEqual(
        $seen[0].path,
        "/api/v4/projects/grp/sub/app/repository/files/docs/a b.md/raw");
    testing.assertEqual($seen[0].query, "lfs=true&ref=release%2F1");
    testing.assertEqual($seen[0].token, "t0k3n");
    testing.assertEqual($seen[1].method, "HEAD");
    testing.assertEqual($seen[1].query, "ref=main");
    testing.assertEqual($made, "c0ffee1");
    def create as json.Value init bodyJson($seen[2]);
    testing.assertEqual($seen[2].path, "/api/v4/projects/grp/sub/app/repository/commits");
    testing.assertEqual(json.asString($create, "/branch"), "main");
    testing.assertEqual(json.asString($create, "/commit_message"), "add");
    testing.assertEqual(json.asString($create, "/actions/0/action"), "create");
    testing.assertEqual(json.asString($create, "/actions/0/file_path"), "docs/new.md");
    testing.assertEqual(json.asString($create, "/actions/0/content"), "aGk=");
    testing.assertEqual(json.asString($create, "/actions/0/encoding"), "base64");
    # "" commits to the default branch, which the project names
    testing.assertEqual($seen[3].path, "/api/v4/projects/grp/sub/app");
    testing.assertEqual($seen[4].query, "ref=main");
    testing.assertEqual(json.asString(bodyJson($seen[5]), "/actions/0/action"), "update");
    testing.assertEqual($changed, "c0ffee2");
    testing.assertEqual(json.asString(bodyJson($seen[6]), "/actions/0/action"), "delete");
    testing.assertEqual(json.asString(bodyJson($seen[6]), "/branch"), "dev");
    testing.assertEqual($gone, "c0ffee3");
    try {
        writeFile(client("x"), "7", "a.txt", convert.bytesFromString("utf-8", ""), " ", "main");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a commit needs a message");
    }
    def g as Fake init fake([answer(500, '{"message":"500 Internal Server Error"}')]);
    try {
        writeFile(tokenClient($g), "7", "a.txt", convert.bytesFromString("utf-8", ""), "m", "main");
        missed();
    } catch (e) {
        # only a 404 means "create"; another failure stops
        testing.assertEqual($e.status, 500);
    }
    finish($g);
}

func testTreeBranchesTagsCommits() {
    def f as Fake init fake([
        ok('[{"id":"aa","name":"docs","type":"tree","path":"docs","mode":"040000"}]'),
        ok('[]'),
        pageOf('[{"name":"main","commit":{"id":"abc"},"protected":true,"default":true}]', ""),
        ok('{"name":"feature/x","commit":{"id":"abc"}}'),
        ok(""),
        ok('{"name":"v1.0","commit":{"id":"abc"},"message":"Release"}'),
        ok(""),
        pageOf(
            '[{"id":"abc","title":"Fix","message":"Fix\n","author_name":"Ada",' +
                '"authored_date":"2026-11-01T09:00:00Z","parent_ids":["p1","p2"]}]',
            ""),
        ok('{"id":"abc","title":"Fix"}')
    ]);
    def c as Client init tokenClient($f);
    def es as list of Entry init listDirectory($c, "7", "docs", "main");
    listTree($c, "7", "", "");
    def bs as list of Branch init branches($c, "7");
    createBranch($c, "7", "feature/x", "main");
    deleteBranch($c, "7", "feature/x");
    def t as Tag init createTag($c, "7", "v1.0", "main", "Release");
    deleteTag($c, "7", "release/1.0");
    def ks as list of Commit init commits($c, "7", "release/1", "src/a b");
    commit($c, "7", "feature/x");
    def seen as list of Seen init finish($f);
    testing.assertEqual($es[0].type, "tree");
    testing.assertEqual($es[0].sha, "aa");
    testing.assertEqual($seen[0].query, "pagination=keyset&path=docs&ref=main&per_page=100");
    testing.assertEqual($seen[1].query, "pagination=keyset&recursive=true&per_page=100");
    testing.assertTrue($bs[0].isDefault);
    testing.assertTrue($bs[0].isProtected);
    testing.assertEqual(json.asString(bodyJson($seen[3]), "/branch"), "feature/x");
    testing.assertEqual(json.asString(bodyJson($seen[3]), "/ref"), "main");
    testing.assertEqual($seen[4].path, "/api/v4/projects/7/repository/branches/feature/x");
    testing.assertEqual($t.message, "Release");
    testing.assertEqual($seen[6].path, "/api/v4/projects/7/repository/tags/release/1.0");
    testing.assertEqual(
        $seen[7].query,
        "with_stats=false&ref_name=release%2F1&path=src%2Fa%20b&per_page=100");
    testing.assertEqual($ks[0].parents, ["p1", "p2"]);
    testing.assertEqual($ks[0].author, "Ada");
    testing.assertEqual($seen[8].path, "/api/v4/projects/7/repository/commits/feature/x");
}

func testCommitStatuses() {
    def f as Fake init fake([
        ok('{"id":1,"name":"ci/build","status":"success","ref":"main","author":{"username":"ci"}}'),
        pageOf(
            '[{"id":11,"name":"a","status":"success"},{"id":12,"name":"b","status":"pending"}]',
            ""),
        pageOf(
            '[{"name":"a","status":"success"},{"name":"b","status":"failed"},' +
                '{"name":"c","status":"running"}]',
            ""),
        pageOf("[]", "")
    ]);
    def c as Client init tokenClient($f);
    def s as CommitStatus init setCommitStatus(
        $c,
        "7",
        "abc1234",
        "success",
        "ci/build",
        "",
        "https://ci/1");
    def all as list of CommitStatus init commitStatuses($c, "7", "abc1234");
    def combined as CombinedStatus init combinedStatus($c, "7", "abc1234");
    def none as CombinedStatus init combinedStatus($c, "7", "abc1234");
    def seen as list of Seen init finish($f);
    testing.assertEqual($s.author, "ci");
    testing.assertEqual($seen[0].path, "/api/v4/projects/7/statuses/abc1234");
    testing.assertEqual(
        json.encode(bodyJson($seen[0])),
        '{"name":"ci/build","state":"success","target_url":"https://ci/1"}');
    testing.assertEqual(len($all), 2);
    # GitLab sends oldest first; the deck returns newest first
    testing.assertEqual($all[0].id, 12);
    testing.assertEqual($all[1].id, 11);
    testing.assertEqual($seen[1].query, "all=true&per_page=100");
    testing.assertEqual($combined.status, "failed");
    testing.assertEqual($none.status, "");
    testing.assertEqual(statusRank("weird"), statusRank("pending"));
    for (def bad in ["passed", "SUCCESS"]) {
        try {
            setCommitStatus(client("x"), "7", "abc1234", $bad, "", "", "");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a commit status is one of");
        }
    }
    try {
        commitStatuses(client("x"), "7", "main");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a commit SHA");
    }
}

func testPipelinesAndVariables() {
    def pl as string init '{"id":40,"iid":3,"ref":"main","sha":"abc","status":"created",' +
        '"source":"api","web_url":"https://gl/p/40"}';
    def f as Fake init fake([
        ok($pl),
        ok($pl),
        pageOf("[" + $pl + "]", ""),
        ok($pl),
        ok($pl),
        ok($pl),
        pageOf(
            '[{"key":"A","value":"1","environment_scope":"*"},' +
                '{"key":"B","value":"2","environment_scope":"*"}]',
            ""),
        answer(404, '{"message":"404 Variable Not Found"}'),
        ok('{"key":"C"}'),
        ok("")
    ]);
    def c as Client init tokenClient($f);
    def p as Pipeline init runPipeline($c, "grp/app", "main", {"B": "2", "A": "1"});
    triggerPipeline(client($f.url), "grp/app", "glptt-x", "main", {"A": "1"});
    pipelines($c, "grp/app", "release/1");
    pipeline($c, "grp/app", 40);
    cancelPipeline($c, "grp/app", 40);
    latestPipeline($c, "grp/app", "main");
    def vs as map of string to string init variables($c, "grp/app");
    setVariable($c, "grp/app", "C", "x y", false);
    deleteVariable($c, "grp/app", "C");
    def seen as list of Seen init finish($f);
    testing.assertEqual($p.id, 40);
    testing.assertEqual($p.source, "api");
    testing.assertEqual($seen[0].path, "/api/v4/projects/grp/app/pipeline");
    testing.assertEqual(
        json.encode(bodyJson($seen[0])),
        '{"ref":"main","variables":[{"key":"A","value":"1"},{"key":"B","value":"2"}]}');
    testing.assertEqual($seen[1].path, "/api/v4/projects/grp/app/trigger/pipeline");
    testing.assertEqual($seen[1].token, "");
    testing.assertEqual(
        json.encode(bodyJson($seen[1])),
        '{"ref":"main","token":"glptt-x","variables":{"A":"1"}}');
    testing.assertEqual($seen[2].query, "ref=release%2F1&per_page=100");
    testing.assertEqual($seen[4].method, "POST");
    testing.assertEqual($seen[4].path, "/api/v4/projects/grp/app/pipelines/40/cancel");
    testing.assertEqual($seen[5].path, "/api/v4/projects/grp/app/pipelines/latest");
    testing.assertEqual($vs, {"A": "1", "B": "2"});
    # Only the every-environment copy: a PUT or DELETE by name alone changes
    # a variable scoped to one environment, or fails 409 with several.
    testing.assertEqual($seen[7].method, "PUT");
    testing.assertEqual($seen[7].path, "/api/v4/projects/grp/app/variables/C");
    testing.assertEqual($seen[7].query, "filter%5Benvironment_scope%5D=%2A");
    testing.assertEqual($seen[8].method, "POST");
    testing.assertEqual(
        json.encode(bodyJson($seen[8])),
        '{"environment_scope":"*","key":"C","masked":false,"value":"x y"}');
    testing.assertEqual($seen[9].method, "DELETE");
    testing.assertEqual($seen[9].path, "/api/v4/projects/grp/app/variables/C");
    testing.assertEqual($seen[9].query, "filter%5Benvironment_scope%5D=%2A");
    for (def bad in ["A-B", "", "A B"]) {
        try {
            setVariable(client("x"), "7", $bad, "v", false);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a variable name");
        }
    }
}

func testGraphql() {
    def f as Fake init fake([
        ok('{"data":{"currentUser":{"username":"root"}}}'),
        ok('{"errors":[{"message":"Field nope does not exist"}]}'),
        answer(401, '{"message":"401 Unauthorized"}')
    ]);
    def c as Client init tokenClient($f);
    def r as json.Value init graphql($c, '{ currentUser { username } }', json.map());
    testing.assertEqual(json.asString($r, "/data/currentUser/username"), "root");
    try {
        graphql($c, '{ nope }', json.map());
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: POST /api/graphql: Field nope does not exist");
        testing.assertEqual($e.status, 200);
    }
    try {
        graphql($c, '{ x }', json.map());
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "HTTP 401");
        testing.assertEqual($e.status, 401);
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api/graphql");
    testing.assertEqual($seen[0].token, "t0k3n");
    testing.assertEqual(
        json.asString(bodyJson($seen[0]), "/query"),
        '{ currentUser { username } }');
    try {
        graphql($c, " ", json.map());
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "not empty");
    }
}

# A local check has status 0; the generic kinds of a failed transfer stay as
# they are, a cancelled task untouched.
func testLocalFailuresAndCaps() {
    try {
        projectPath("nope");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 0);
    }
    for (def kind in ["limit", "timeout", "closed"]) {
        try {
            failTransport("GET /x", Error{kind: $kind, message: "http: it went wrong"});
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, $kind);
            testing.assertEqual($e.message, "gitlab: GET /x: http: it went wrong");
        }
    }
    try {
        failTransport("GET /x", Error{kind: "cancelled", message: "task cancelled"});
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "cancelled");
        testing.assertEqual($e.message, "task cancelled");
    }
    try {
        failTransport("GET /x", Error{kind: "http", message: "http: malformed"});
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "gitlab: GET /x: http: malformed");
        testing.assertEqual($e.status, 0);
    }
}

# A network failure is a net.NetError, passed on unchanged with its fields,
# from every path a request takes: JSON calls, GraphQL, byte downloads and
# uploads.
func testNetworkFailuresPassOnUnchanged() {
    def f as Fake init fake([]);
    def c as Client init tokenClient($f);
    finish($f);
    def calls as int init 0;
    for (def which in ["call", "graphql", "readFile", "upload"]) {
        try {
            if ($which == "call") {
                project($c, "grp/app");
            } elseif ($which == "graphql") {
                graphql($c, '{ currentUser { username } }', json.map());
            } elseif ($which == "readFile") {
                readFile($c, "grp/app", "VERSION", "main", 0);
            } else {
                uploadPackageFile(
                    $c,
                    "grp/app",
                    "app",
                    "1.0",
                    "a.txt",
                    convert.bytesFromString("utf-8", "x"));
            }
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, "net");
            testing.assertEqual($e.reason, "refused");
            testing.assertEqual($e.op, "connect");
            testing.assertFalse($e.sent);
            testing.assertFalse($e.replied);
            testing.assertFalse(strings.startsWith($e.message, "gitlab: "));
            $calls = $calls + 1;
        }
    }
    testing.assertEqual($calls, 4);
}

# The verbs the other tests leave out: each sends the request it names.
func testTheOtherVerbs() {
    def none as Reply init pageOf("[]", "");
    def bob as Reply init ok('[{"id":9,"username":"bob"}]');
    def f as Fake init fake([
        ok('{}'),
        ok(""),
        ok(""),
        ok(""),
        ok(""),
        ok(MR),
        ok('{}'),
        ok(PROJECT),
        ok(RELEASE),
        $none,
        ok(ISSUE),
        $none,
        ok(MR),
        $none,
        $none,
        $none,
        $none,
        ok(ISSUE),
        $bob,
        ok(""),
        ok(ISSUE),
        ok(MR),
        ok('{"id":40}'),
        $bob,
        ok(MR),
        $none,
        ok(""),
        $none
    ]);
    def c as Client init tokenClient($f);
    addMergeRequestNote($c, "7", 15, "hi");
    deleteHook($c, "7", 3);
    deleteLabel($c, "7", 4);
    deleteMilestone($c, "7", 5);
    deleteNote($c, "7", 12, 6);
    editMergeRequest($c, "7", 15, "T", "");
    editNote($c, "7", 12, 6, "x");
    editProject($c, "7", "", "d");
    editRelease($c, "7", "v1", "N", "");
    forks($c, "7");
    issue($c, "7", 12);
    members($c, "7");
    mergeRequest($c, "7", 15);
    mergeRequestCommits($c, "7", 15);
    mergeRequestNotes($c, "7", 15);
    myGroups($c);
    myProjects($c);
    removeIssueLabel($c, "7", 12, "bug");
    removeMember($c, "7", "bob");
    reopenIssue($c, "7", 12);
    reopenMergeRequest($c, "7", 15);
    retryPipeline($c, "7", 40);
    setReviewers($c, "7", 15, ["bob"]);
    tags($c, "7");
    unapproveMergeRequest($c, "7", 15);
    userProjects($c, "bob");
    def seen as list of Seen init finish($f);
    def want as list of string init [
        "POST /projects/7/merge_requests/15/notes",
        "DELETE /projects/7/hooks/3",
        "DELETE /projects/7/labels/4",
        "DELETE /projects/7/milestones/5",
        "DELETE /projects/7/issues/12/notes/6",
        "PUT /projects/7/merge_requests/15",
        "PUT /projects/7/issues/12/notes/6",
        "PUT /projects/7",
        "PUT /projects/7/releases/v1",
        "GET /projects/7/forks",
        "GET /projects/7/issues/12",
        "GET /projects/7/members",
        "GET /projects/7/merge_requests/15",
        "GET /projects/7/merge_requests/15/commits",
        "GET /projects/7/merge_requests/15/notes",
        "GET /groups",
        "GET /projects",
        "PUT /projects/7/issues/12",
        "GET /users",
        "DELETE /projects/7/members/9",
        "PUT /projects/7/issues/12",
        "PUT /projects/7/merge_requests/15",
        "POST /projects/7/pipelines/40/retry",
        "GET /users",
        "PUT /projects/7/merge_requests/15",
        "GET /projects/7/repository/tags",
        "POST /projects/7/merge_requests/15/unapprove",
        "GET /users/bob/projects"
    ];
    testing.assertEqual(len($seen), len($want));
    def i as int init 0;
    for (def s in $seen) {
        testing.assertEqual(
            $s.method + " " + strings.substring($s.path, len("/api/v4")),
            $want[$i]);
        testing.assertEqual($s.token, "t0k3n");
        $i = $i + 1;
    }
    testing.assertEqual(json.encode(bodyJson($seen[5])), '{"title":"T"}');
    testing.assertEqual(json.encode(bodyJson($seen[7])), '{"description":"d"}');
    testing.assertEqual($seen[16].query, "membership=true&per_page=100");
    testing.assertEqual($seen[15].query, "min_access_level=10&per_page=100");
    testing.assertEqual(json.encode(bodyJson($seen[17])), '{"remove_labels":"bug"}');
    testing.assertEqual(json.encode(bodyJson($seen[20])), '{"state_event":"reopen"}');
    testing.assertEqual(json.encode(bodyJson($seen[24])), '{"reviewer_ids":[9]}');
}

# A GET answered 429 is retried after Retry-After; a write is not.
func testRetriesOnlyReads() {
    def f as Fake init fake([
        Reply{status: 429, headers: {"Retry-After": "0"}, body: '{"message":"429 Too Many"}'},
        ok(ISSUE),
        answer(503, "")
    ]);
    def c as Client init withRetries(tokenClient($f), 2);
    testing.assertEqual(issue($c, "7", 12).iid, 12);
    try {
        createIssue($c, "7", "x", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.status, 503);
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual($seen[1].method, "GET");
    testing.assertEqual($seen[2].method, "POST");
}

# variables() lists only the every-environment copies, the ones setVariable
# and deleteVariable act on: GitLab lists a name once per scope.
func testVariablesAreTheEveryEnvironmentCopies() {
    def f as Fake init fake([
        pageOf(
            '[{"key":"REGION","value":"eu","environment_scope":"*"},' +
                '{"key":"REGION","value":"us","environment_scope":"production"},' +
                '{"key":"DEBUG","value":"1","environment_scope":"staging"},' +
                '{"key":"TOKEN","value":"","environment_scope":"*","hidden":true}]',
            "")
    ]);
    def vs as map of string to string init variables(tokenClient($f), "grp/app");
    testing.assertEqual($vs, {"REGION": "eu", "TOKEN": ""});
    testing.assertFalse(maps.has($vs, "DEBUG"));
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v4/projects/grp/app/variables");
}

# A merge request names the projects of its source and target branch: they
# differ for one from a fork.
func testMergeRequestProjects() {
    def fork as string init strings.replace(
        MR,
        '"draft":false,',
        '"draft":false,"source_project_id":9,"target_project_id":7,');
    def f as Fake init fake([ok($fork), ok(MR)]);
    def c as Client init tokenClient($f);
    def mr as MergeRequest init mergeRequest($c, "grp/sub/app", 15);
    testing.assertEqual($mr.sourceProjectId, 9);
    testing.assertEqual($mr.targetProjectId, 7);
    # Absent members read as 0, as every number of a reply.
    def bare as MergeRequest init mergeRequest($c, "grp/sub/app", 15);
    testing.assertEqual($bare.sourceProjectId, 0);
    testing.assertEqual($bare.targetProjectId, 0);
    finish($f);
}
