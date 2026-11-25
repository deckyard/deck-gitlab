# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * Summarize a project: its latest release, its open merge requests that
 * can be merged, and its open issues without a label.
 *
 *   jennifer run examples/triage.j gitlab-org/cli
 *
 * Reads public data anonymously from gitlab.com; set GITLAB_URL and
 * GITLAB_TOKEN for another instance or a private project.
 */
use io;
use os;

import "../src/gitlab.j" as gitlab;

if (len(os.ARGS) != 2) {
    throw Error{kind: "usage", message: "usage: triage.j <group/project>"};
}
def project as string init os.ARGS[1];

def url as string init "gitlab.com";
if (os.hasEnv("GITLAB_URL")) {
    $url = os.getEnv("GITLAB_URL");
}
def c as gitlab.Client init gitlab.withRetries(gitlab.client($url), 2);
if (os.hasEnv("GITLAB_TOKEN")) {
    $c = gitlab.withToken($c, os.getEnv("GITLAB_TOKEN"));
}

def p as gitlab.Project init gitlab.project($c, $project);
io.printf("%s: default branch %s, %d stars\n", $p.fullPath, $p.defaultBranch, $p.stars);

# A project without releases answers 404 here.
try {
    def rel as gitlab.Release init gitlab.latestRelease($c, $project);
    io.printf("latest release %s, %d links\n", $rel.tag, len($rel.links));
} catch (e) {
    if ($e.kind != gitlab.ERROR_KIND or $e.status != 404) {
        throw $e;
    }
    io.printf("no releases\n");
}

for (def mr in gitlab.mergeRequests($c, $project, "opened")) {
    if ($mr.mergeable) {
        io.printf("  mergeable !%d %s\n", $mr.iid, $mr.title);
    }
}
for (def i in gitlab.issues($c, $project, "opened")) {
    if (len($i.labels) == 0) {
        io.printf("  unlabelled #%d %s\n", $i.iid, $i.title);
    }
}
