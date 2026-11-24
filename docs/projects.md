<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Projects and groups

## Projects

```jennifer
def p as gitlab.Project init gitlab.createProject($c, "my-group/tools", "app", "An app", "private");
io.printf("%s %s\n", $p.fullPath, $p.httpUrl);
gitlab.setDefaultBranch($c, $p.fullPath, "main");
```

`createProject` takes the group's full path, `""` for the token's own
account; the name is also the path. `project` reads one by id or full path,
`groupProjects` the projects of a group (with its subgroups' when asked),
`userProjects` a user's, `myProjects` the token account's, and
`searchProjects` searches what the token may see. `search` runs GitLab™'s
search API in one project or the whole instance and returns the matches as
JSON.

`forkProject` forks into a group (`""` for the token's account), `forks`
lists the forks. `setArchived` archives a project or brings it back,
`deleteProject` deletes it; an instance with delayed deletion keeps it for
some days first.

## Groups

```jennifer
def g as gitlab.Group init gitlab.group($c, "my-group/tools");
for (def s in gitlab.subgroups($c, "my-group")) {
    io.printf("%s\n", $s.fullPath);
}
```

## Members

```jennifer
gitlab.addMember($c, "me/app", "ada", gitlab.ACCESS_DEVELOPER);
gitlab.removeMember($c, "me/app", "ada");
```

`addMember` adds a member or changes the level of one. The levels are the
`ACCESS_*` constants. `members` lists the direct members, not those a
group brings in.

## Hooks

```jennifer
gitlab.createHook($c, "me/app", "https://ci.example.com/hook", $secret, ["push", "merge_requests"]);
```

GitLab sends the secret in `X-Gitlab-Token`. The events are from
`HOOK_EVENTS`; certificate checking of the receiver is on.
