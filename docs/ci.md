<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Commits and CI/CD

## Reporting a check

A CI system outside GitLab reports on a commit with a status per name:

```jennifer
gitlab.setCommitStatus($c, "me/app", $sha, "running", "ci/build", "building", $logUrl);
# ... build ...
gitlab.setCommitStatus($c, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);

def s as gitlab.CombinedStatus init gitlab.combinedStatus($c, "me/app", $sha);
io.printf("%s over %d checks\n", $s.status, len($s.statuses));
```

A state is one of `STATUS_STATES`: `pending`, `running`, `success`,
`failed`, `canceled` or `skipped`. GitLab refuses some moves, such as from
`success` back to `pending`. The statuses of a commit form an external
pipeline of their own. `combinedStatus` keeps the latest status per name
and names the worst; `commitStatuses` lists every one.

## Pipelines

```jennifer
def p as gitlab.Pipeline init gitlab.runPipeline($c, "me/app", "main", {"DEPLOY": "staging"});
while (not lists.contains(["success", "failed", "canceled", "skipped"], $p.status)) {
    time.sleep(time.fromSeconds(10));
    $p = gitlab.pipeline($c, "me/app", $p.id);
}
```

`runPipeline` runs as the token's account; `triggerPipeline` uses a
pipeline trigger token instead, as another project's job does. GitLab
answers HTTP 400 when the configuration creates no jobs for the ref.
`cancelPipeline` and `retryPipeline` act on the jobs, which change state in
the background. `latestPipeline` is the newest pipeline of a ref.

## CI/CD variables

```jennifer
gitlab.setVariable($c, "me/app", "DEPLOY_REGION", "eu-west", false);
gitlab.setVariable($c, "me/app", "DEPLOY_TOKEN", fs.readString("deploy.token"), true);
def vars as map of string to string init gitlab.variables($c, "me/app");
```

A variable is set for every environment (scope `*`); `setVariable` and
`deleteVariable` leave a variable of the same name scoped to one
environment alone. `variables` reads every scope, so such a name appears
once, with one of its values. GitLab stores the value as given, with no
client-side encryption; `masked` only hides it in job logs, and needs 8 or
more characters without spaces. Names are letters, digits and `_`.

## Commits

```jennifer
for (def k in gitlab.commits($c, "me/app", "main", "src")) {
    io.printf("%s %s\n", $k.sha, $k.title);
}
```

`commits` follows every page; `commit` fetches one by SHA, branch or tag.
