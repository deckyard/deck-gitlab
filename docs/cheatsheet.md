<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# gitlab cheatsheet

Every export of `@deckyard/gitlab`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/gitlab/" as gitlab;
```

Every function that sends a request throws a `GitlabError` (kind `"gitlab"`,
with the HTTP `status`) when it fails; a list past `MAX_PAGES` pages or a reply
over its size cap is kind `"limit"`, a deadline `"timeout"`, and a network failure
is a `net.NetError` (kind `"net"`, with `reason`, `sent` and `replied`), passed on
unchanged. A `project` is a
numeric id (`"42"`) or a full path (`"group/sub/name"`); an `iid` is an issue's
or merge request's number in its project. An `iid` or id below 1 is refused
before anything is sent (status 0).

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"gitlab"` | The `kind` of every error of the deck's own |
| `PAGE_SIZE` | `100` | The entries `getAll` and the list verbs ask for per page, GitLab™'s most |
| `MAX_PAGES` | `1000` | The most pages a list follows before it refuses: 100000 entries |
| `ACCESS_GUEST` | `10` | Access level of a guest |
| `ACCESS_PLANNER` | `15` | Access level of a planner |
| `ACCESS_REPORTER` | `20` | Access level of a reporter |
| `ACCESS_DEVELOPER` | `30` | Access level of a developer |
| `ACCESS_MAINTAINER` | `40` | Access level of a maintainer |
| `ACCESS_OWNER` | `50` | Access level of an owner |
| `HOOK_EVENTS` | `["push", "tag_push", "issues", "confidential_issues", "note", "confidential_note", "merge_requests", "job", "pipeline", "wiki_page", "deployment", "releases"]` | The events a project hook can fire on, as `createHook` takes them |
| `STATUS_STATES` | `["pending", "running", "success", "failed", "canceled", "skipped"]` | The states `setCommitStatus` can set |

## Types

### `GitlabError`

A failed request or a refused value.

| Field | Meaning |
|---|---|
| `kind as string` | always `"gitlab"` (`ERROR_KIND`) |
| `message as string` | `gitlab: ` and what failed; for a refused request `gitlab: <verb> <path>: HTTP <status>: <reason>` |
| `status as int` | the HTTP status the instance answered (400, 401, 403, 404, 409, 422, ...); 0 when no answer was read or for a local check |

### `Client`

A connection to one GitLab instance.

| Field | Meaning |
|---|---|
| `url as string` | `https://host` or `https://host/path`, without `/api/v4` |
| `token as string` | the token; "" for anonymous reads |
| `authHeader as string` | the header that carries it: `PRIVATE-TOKEN`, `Authorization` (OAuth, as `Bearer`) or `JOB-TOKEN` |
| `tls as http.TlsOptions` | certificate checking |
| `timeoutMs as int` | the idle timeout of each request; 0 for 30 s |
| `retries as int` | retries of a GET answered 429 or 5xx |
| `allowPlainHttp as bool` | whether the token may go over plain `http` to another machine (it then crosses the network in clear) |

### `User`

An account.

| Field | Meaning |
|---|---|
| `id as int` | the user id |
| `username as string` | the user name |
| `name as string` | the display name |
| `email as string` | the e-mail address, as far as the token may see it |
| `isAdmin as bool` | whether it administers the instance, as far as the token may see it |
| `state as string` | e.g. `active` or `blocked` |
| `webUrl as string` | its page |

### `Project`

A project.

| Field | Meaning |
|---|---|
| `id as int` | the project id |
| `name as string` | the name |
| `path as string` | the last segment of its path |
| `fullPath as string` | `group/sub/name` |
| `namespace as string` | the full path of its group or user |
| `description as string` | the description |
| `visibility as string` | `private`, `internal` or `public` |
| `isArchived as bool` | whether it is archived |
| `defaultBranch as string` | e.g. `main`, also in an empty repository (the branch a first push creates); "" when GitLab reports none |
| `webUrl as string` | its page |
| `httpUrl as string` | the HTTPS clone URL |
| `sshUrl as string` | the SSH clone URL |
| `stars as int` | the star count |
| `forks as int` | the fork count |
| `openIssues as int` | open issues; 0 when issues are off |
| `lastActivity as string` | RFC 3339 |
| `forkedFrom as string` | the full path of the project it is a fork of; "" otherwise |

### `Group`

A group or subgroup.

| Field | Meaning |
|---|---|
| `id as int` | the group id |
| `name as string` | the name |
| `path as string` | the last segment of its path |
| `fullPath as string` | `group/sub` |
| `description as string` | the description |
| `visibility as string` | `private`, `internal` or `public` |
| `parentId as int` | the parent group's id; 0 for a top-level group |
| `webUrl as string` | its page |

### `Issue`

An issue.

| Field | Meaning |
|---|---|
| `iid as int` | the number within the project |
| `id as int` | the instance-wide id |
| `title as string` | the title |
| `description as string` | the text, Markdown |
| `state as string` | `opened` or `closed` |
| `author as string` | who opened it |
| `labels as list of string` | label names |
| `assignees as list of string` | assigned user names |
| `milestone as string` | the milestone's title; "" for none |
| `notes as int` | the count of notes by users |
| `isConfidential as bool` | whether it is confidential |
| `created as string` | RFC 3339 |
| `updated as string` | RFC 3339 |
| `closed as string` | RFC 3339; "" while open |
| `webUrl as string` | its page |

### `Note`

A note (comment) on an issue or merge request.

| Field | Meaning |
|---|---|
| `id as int` | the note id |
| `author as string` | who wrote it |
| `body as string` | the text, Markdown |
| `isSystem as bool` | whether GitLab wrote it for an event, such as a label change |
| `created as string` | RFC 3339 |
| `updated as string` | RFC 3339 |

### `MergeRequest`

A merge request.

| Field | Meaning |
|---|---|
| `iid as int` | the number within the project |
| `id as int` | the instance-wide id |
| `title as string` | the title |
| `description as string` | the text, Markdown |
| `state as string` | `opened`, `closed`, `locked` or `merged` |
| `author as string` | who opened it |
| `sourceBranch as string` | the branch with the changes |
| `targetBranch as string` | the branch it merges into |
| `sha as string` | the commit at the head of the source branch |
| `isDraft as bool` | whether it is a draft |
| `mergeStatus as string` | GitLab's `detailed_merge_status`, e.g. `mergeable`, `checking`, `conflict`, `not_approved`, `not_open` |
| `mergeable as bool` | whether `mergeStatus` is `mergeable` |
| `merged as bool` | whether it is merged |
| `mergeSha as string` | the merge commit; "" until merged or for a fast-forward merge |
| `squashSha as string` | the squash commit; "" without one |
| `webUrl as string` | its page |
| `created as string` | RFC 3339 |
| `mergedAt as string` | RFC 3339; "" until merged |
| `sourceProjectId as int` | the project the source branch is in; another than `targetProjectId` for a merge request from a fork |
| `targetProjectId as int` | the project it merges into |

### `Approvals`

The approval state of a merge request.

| Field | Meaning |
|---|---|
| `approved as bool` | whether it counts as approved |
| `approvedBy as list of string` | the user names that approved it |
| `required as int` | approvals its rules require; 0 on GitLab Free |
| `left as int` | approvals still missing; 0 on GitLab Free |

### `ChangedFile`

A file a merge request changes.

| Field | Meaning |
|---|---|
| `oldPath as string` | the path before |
| `newPath as string` | the path after |
| `isNew as bool` | whether it adds the file |
| `isRenamed as bool` | whether it renames the file |
| `isDeleted as bool` | whether it deletes the file |
| `diff as string` | the unified diff of the file; "" when GitLab left it out as too large |

### `Release`

A release.

| Field | Meaning |
|---|---|
| `tag as string` | the tag it is for; also its key |
| `name as string` | the title |
| `description as string` | the notes, Markdown |
| `author as string` | who created it |
| `commitSha as string` | the tagged commit |
| `created as string` | RFC 3339 |
| `released as string` | RFC 3339; may lie in the future |
| `isUpcoming as bool` | whether `released` is in the future |
| `webUrl as string` | its page |
| `links as list of ReleaseLink` | the attached links |
| `sources as list of string` | the URLs of the source archives |

### `ReleaseLink`

A link attached to a release, GitLab's release asset.

| Field | Meaning |
|---|---|
| `id as int` | the link id |
| `name as string` | the name |
| `url as string` | where it points |
| `directAssetUrl as string` | its permanent URL under the release page |
| `linkType as string` | `other`, `runbook`, `image` or `package` |

### `Branch`

A branch.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `isProtected as bool` | whether a protection rule covers it |
| `isDefault as bool` | whether it is the default branch |
| `isMerged as bool` | whether it is merged into the default branch |

### `Tag`

A tag.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `message as string` | the annotation; "" for a lightweight tag |
| `isProtected as bool` | whether a protection rule covers it |

### `Commit`

A commit.

| Field | Meaning |
|---|---|
| `sha as string` | the commit SHA |
| `title as string` | the first line of the message |
| `message as string` | the commit message |
| `author as string` | the author's name, as Git™ records it |
| `authorEmail as string` | the author's e-mail address |
| `date as string` | the author date, RFC 3339 |
| `parents as list of string` | the parent SHAs |
| `webUrl as string` | its page |

### `CommitStatus`

A status set on a commit, by a pipeline job or an outside CI system.

| Field | Meaning |
|---|---|
| `id as int` | the status id |
| `name as string` | which check it is, e.g. `ci/build` |
| `status as string` | `pending`, `running`, `success`, `failed`, `canceled`, `skipped`, or another state a pipeline job has |
| `description as string` | a short text |
| `targetUrl as string` | where the details are |
| `author as string` | who set it |
| `ref as string` | the branch or tag it was set for |
| `created as string` | RFC 3339 |

### `CombinedStatus`

The statuses of a commit, combined.

| Field | Meaning |
|---|---|
| `status as string` | the worst state of the latest status per name; "" when there is none |
| `statuses as list of CommitStatus` | the latest status per name |

### `Label`

A label of a project.

| Field | Meaning |
|---|---|
| `id as int` | the label id |
| `name as string` | the name, e.g. `bug` or `scope::ui` |
| `color as string` | the colour, e.g. `#ee0701` |
| `description as string` | the description |

### `Milestone`

A milestone of a project.

| Field | Meaning |
|---|---|
| `id as int` | the milestone id, which `setMilestone` takes |
| `iid as int` | the number within the project |
| `title as string` | the title |
| `description as string` | the description |
| `state as string` | `active` or `closed` |
| `dueDate as string` | `YYYY-MM-DD`; "" without one |
| `startDate as string` | `YYYY-MM-DD`; "" without one |
| `webUrl as string` | its page |

### `Hook`

A hook of a project.

| Field | Meaning |
|---|---|
| `id as int` | the hook id |
| `url as string` | where it posts to |
| `events as list of string` | the events it fires on, from `HOOK_EVENTS` |
| `sslVerification as bool` | whether it checks the receiver's certificate |

### `Entry`

An entry of a directory in a repository.

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `path as string` | the path from the repository root |
| `type as string` | `blob` (a file), `tree` (a directory) or `commit` (a submodule) |
| `mode as string` | the Git file mode, e.g. `100644` |
| `sha as string` | the blob or tree SHA |

### `Pipeline`

A CI/CD pipeline.

| Field | Meaning |
|---|---|
| `id as int` | the pipeline id |
| `iid as int` | the number within the project |
| `ref as string` | the branch or tag it ran for |
| `sha as string` | the commit |
| `status as string` | e.g. `created`, `pending`, `running`, `success`, `failed`, `canceled`, `skipped`, `manual` |
| `source as string` | what started it, e.g. `push`, `web`, `api`, `trigger`, `schedule` |
| `webUrl as string` | its page |
| `created as string` | RFC 3339 |
| `updated as string` | RFC 3339 |

### `Member`

A member of a project.

| Field | Meaning |
|---|---|
| `id as int` | the user id |
| `username as string` | the user name |
| `name as string` | the display name |
| `accessLevel as int` | one of the `ACCESS_*` levels |
| `expiresAt as string` | `YYYY-MM-DD`; "" when it does not expire |

## Connecting

| Function | Returns | Does |
|---|---|---|
| `gitlab.client(address)` | `Client` | a client for an instance, without a token |
| `gitlab.withToken(c, token)` | `Client` | authenticate with a personal, project or group access token, sent as `PRIVATE-TOKEN` |
| `gitlab.withBearer(c, token)` | `Client` | authenticate with an OAuth 2 access token, sent as `Authorization: Bearer` |
| `gitlab.withJobToken(c, token)` | `Client` | authenticate with a CI/CD job token (`CI_JOB_TOKEN`), sent as `JOB-TOKEN` |
| `gitlab.withCaCert(c, pem)` | `Client` | trust a certificate (PEM) |
| `gitlab.withInsecure(c)` | `Client` | accept any certificate |
| `gitlab.withTimeout(c, ms)` | `Client` | set the idle timeout of each request |
| `gitlab.withRetries(c, n)` | `Client` | retry GETs answered 429 or 5xx, honouring `Retry-After` |
| `gitlab.withPlainHttp(c)` | `Client` | allow the token over plain http to another machine (an instance on the LAN) |
| `gitlab.call(c, method, path, body)` | `json.Value` | any endpoint; `body` is JSON text |
| `gitlab.getAll(c, path)` | `list of json.Value` | every page of a list endpoint |
| `gitlab.graphql(c, query, variables)` | `json.Value` | a GraphQL™ query or mutation at `/api/graphql` |
| `gitlab.version(c)` | `string` | the version of the instance |
| `gitlab.currentUser(c)` | `User` | the account the token belongs to |
| `gitlab.user(c, username)` | `User` | an account by its user name |

## Projects and groups

| Function | Returns | Does |
|---|---|---|
| `gitlab.project(c, project)` | `Project` | one project |
| `gitlab.userProjects(c, username)` | `list of Project` | the projects a user owns, as far as the token may see them |
| `gitlab.groupProjects(c, group, includeSubgroups)` | `list of Project` | the projects of a group, as far as the token may see them |
| `gitlab.myProjects(c)` | `list of Project` | the projects the token's account is a member of |
| `gitlab.searchProjects(c, query)` | `list of Project` | search the projects the token may see by name, path and description |
| `gitlab.search(c, project, scope, query)` | `list of json.Value` | search with GitLab's search API, in one project or the whole instance |
| `gitlab.createProject(c, namespace, name, description, visibility)` | `Project` | create an empty project |
| `gitlab.deleteProject(c, project)` |  | delete a project, with its issues, merge requests and releases |
| `gitlab.editProject(c, project, name, description)` | `Project` | change a project's name or description |
| `gitlab.setArchived(c, project, archived)` | `Project` | archive a project, or bring it back |
| `gitlab.setDefaultBranch(c, project, branch)` | `Project` | change a project's default branch |
| `gitlab.forkProject(c, project, namespace, name)` | `Project` | fork a project |
| `gitlab.forks(c, project)` | `list of Project` | the forks of a project the token may see |
| `gitlab.group(c, group)` | `Group` | one group or subgroup |
| `gitlab.subgroups(c, group)` | `list of Group` | the direct subgroups of a group |
| `gitlab.myGroups(c)` | `list of Group` | the groups the token's account is a member of |
| `gitlab.members(c, project)` | `list of Member` | the direct members of a project, without those it inherits from groups |
| `gitlab.addMember(c, project, username, accessLevel)` | `Member` | add a member to a project, or change the access level of one |
| `gitlab.removeMember(c, project, username)` |  | remove a member from a project |
| `gitlab.hooks(c, project)` | `list of Hook` | the hooks of a project |
| `gitlab.createHook(c, project, url, secret, events)` | `Hook` | add a hook that posts JSON to a URL, with certificate checking on |
| `gitlab.deleteHook(c, project, id)` |  | delete a hook |

## Issues

| Function | Returns | Does |
|---|---|---|
| `gitlab.issues(c, project, state)` | `list of Issue` | the issues of a project, newest first |
| `gitlab.issue(c, project, iid)` | `Issue` | one issue |
| `gitlab.createIssue(c, project, title, description)` | `Issue` | open an issue |
| `gitlab.editIssue(c, project, iid, title, description)` | `Issue` | change an issue's title or text |
| `gitlab.closeIssue(c, project, iid)` | `Issue` | close an issue |
| `gitlab.reopenIssue(c, project, iid)` | `Issue` | reopen an issue |
| `gitlab.setAssignees(c, project, iid, names)` | `Issue` | set who is assigned to an issue |
| `gitlab.setMilestone(c, project, iid, milestoneId)` | `Issue` | put an issue in a milestone |
| `gitlab.setIssueLabels(c, project, iid, names)` | `Issue` | replace the labels of an issue |
| `gitlab.addIssueLabels(c, project, iid, names)` | `Issue` | add labels to an issue |
| `gitlab.removeIssueLabel(c, project, iid, name)` | `Issue` | take a label off an issue |
| `gitlab.notes(c, project, iid)` | `list of Note` | the notes on an issue, oldest first, system notes included |
| `gitlab.addNote(c, project, iid, body)` | `Note` | comment on an issue |
| `gitlab.editNote(c, project, iid, noteId, body)` | `Note` | change the text of a note on an issue |
| `gitlab.deleteNote(c, project, iid, noteId)` |  | delete a note on an issue |
| `gitlab.labels(c, project)` | `list of Label` | the labels of a project, those of its groups included |
| `gitlab.createLabel(c, project, name, color, description)` | `Label` | create a label |
| `gitlab.deleteLabel(c, project, id)` |  | delete a label, from the project and every issue and merge request |
| `gitlab.milestones(c, project, state)` | `list of Milestone` | the milestones of a project |
| `gitlab.createMilestone(c, project, title, description, dueDate)` | `Milestone` | create a milestone |
| `gitlab.setMilestoneClosed(c, project, id, closed)` | `Milestone` | close a milestone, or make it active again |
| `gitlab.deleteMilestone(c, project, id)` |  | delete a milestone |

## Merge requests

| Function | Returns | Does |
|---|---|---|
| `gitlab.mergeRequests(c, project, state)` | `list of MergeRequest` | the merge requests of a project, newest first |
| `gitlab.mergeRequest(c, project, iid)` | `MergeRequest` | one merge request |
| `gitlab.createMergeRequest(c, project, sourceBranch, targetBranch, title, description)` | `MergeRequest` | open a merge request within a project |
| `gitlab.editMergeRequest(c, project, iid, title, description)` | `MergeRequest` | change a merge request's title or text |
| `gitlab.closeMergeRequest(c, project, iid)` | `MergeRequest` | close a merge request without merging it |
| `gitlab.reopenMergeRequest(c, project, iid)` | `MergeRequest` | reopen a closed merge request |
| `gitlab.mergeMergeRequest(c, project, iid, sha, squash, removeSourceBranch)` | `MergeRequest` | merge a merge request now, with the project's merge method |
| `gitlab.setReviewers(c, project, iid, names)` | `MergeRequest` | set who reviews a merge request |
| `gitlab.approvals(c, project, iid)` | `Approvals` | the approval state of a merge request |
| `gitlab.approveMergeRequest(c, project, iid, sha)` | `Approvals` | approve a merge request as the token's account |
| `gitlab.unapproveMergeRequest(c, project, iid)` |  | take back the token account's approval of a merge request |
| `gitlab.mergeRequestChanges(c, project, iid)` | `list of ChangedFile` | the files a merge request changes, with their diffs |
| `gitlab.mergeRequestCommits(c, project, iid)` | `list of Commit` | the commits of a merge request, newest first |
| `gitlab.mergeRequestNotes(c, project, iid)` | `list of Note` | the notes on a merge request, oldest first, system notes included |
| `gitlab.addMergeRequestNote(c, project, iid, body)` | `Note` | comment on a merge request |

## Releases and packages

| Function | Returns | Does |
|---|---|---|
| `gitlab.releases(c, project)` | `list of Release` | the releases of a project, newest release date first |
| `gitlab.release(c, project, tag)` | `Release` | the release of a tag |
| `gitlab.latestRelease(c, project)` | `Release` | the release with the latest release date that is not upcoming |
| `gitlab.createRelease(c, project, tag, ref, name, description)` | `Release` | publish a release; `ref` creates a missing tag |
| `gitlab.editRelease(c, project, tag, name, description)` | `Release` | change a release's title or notes |
| `gitlab.deleteRelease(c, project, tag)` |  | delete a release |
| `gitlab.addReleaseLink(c, project, tag, name, url, linkType)` | `ReleaseLink` | attach a link to a release: GitLab's release asset |
| `gitlab.deleteReleaseLink(c, project, tag, linkId)` |  | delete a link of a release |
| `gitlab.uploadPackageFile(c, project, packageName, version, fileName, data)` | `string` | upload to the generic package registry; the download URL |
| `gitlab.uploadAsset(c, project, tag, packageName, fileName, data)` | `ReleaseLink` | upload a file and link it to a release |
| `gitlab.downloadAsset(c, link, maxBytes)` | `bytes` | download a link's target on the instance |

## Repository

| Function | Returns | Does |
|---|---|---|
| `gitlab.branches(c, project)` | `list of Branch` | the branches of a project |
| `gitlab.createBranch(c, project, name, from)` | `Branch` | create a branch |
| `gitlab.deleteBranch(c, project, name)` |  | delete a branch |
| `gitlab.tags(c, project)` | `list of Tag` | the tags of a project, newest first |
| `gitlab.createTag(c, project, name, target, message)` | `Tag` | create a tag |
| `gitlab.deleteTag(c, project, name)` |  | delete a tag |
| `gitlab.readFile(c, project, path, ref, maxBytes)` | `bytes` | read a file from a repository |
| `gitlab.writeFile(c, project, path, data, message, branch)` | `string` | create or replace a file with a commit of its own |
| `gitlab.deleteFile(c, project, path, message, branch)` | `string` | delete a file with a commit of its own |
| `gitlab.listDirectory(c, project, path, ref)` | `list of Entry` | the entries of a directory in a repository |
| `gitlab.listTree(c, project, path, ref)` | `list of Entry` | every file and directory below a path, at any depth |
| `gitlab.commits(c, project, ref, path)` | `list of Commit` | the commits reachable from a ref, newest first |
| `gitlab.commit(c, project, sha)` | `Commit` | one commit |

## CI/CD

| Function | Returns | Does |
|---|---|---|
| `gitlab.setCommitStatus(c, project, sha, state, name, description, targetUrl)` | `CommitStatus` | set a status on a commit, as an outside CI system reports a check |
| `gitlab.commitStatuses(c, project, sha)` | `list of CommitStatus` | every status set on a commit, newest first |
| `gitlab.combinedStatus(c, project, sha)` | `CombinedStatus` | the latest status per name, and the worst |
| `gitlab.pipelines(c, project, ref)` | `list of Pipeline` | the pipelines of a project, newest first |
| `gitlab.pipeline(c, project, id)` | `Pipeline` | one pipeline, with its current status |
| `gitlab.latestPipeline(c, project, ref)` | `Pipeline` | the newest pipeline of a branch or tag |
| `gitlab.runPipeline(c, project, ref, variables)` | `Pipeline` | run a pipeline for a branch or tag, as the token's account |
| `gitlab.triggerPipeline(c, project, triggerToken, ref, variables)` | `Pipeline` | run a pipeline with a trigger token |
| `gitlab.cancelPipeline(c, project, id)` | `Pipeline` | cancel the running jobs of a pipeline |
| `gitlab.retryPipeline(c, project, id)` | `Pipeline` | retry the failed and canceled jobs of a pipeline |
| `gitlab.variables(c, project)` | `map of string to string` | the CI/CD variables of a project that apply to every environment (`*`) |
| `gitlab.setVariable(c, project, name, value, masked)` |  | create or replace a CI/CD variable of a project, for every environment |
| `gitlab.deleteVariable(c, project, name)` |  | delete the every-environment (`*`) CI/CD variable of a project |

