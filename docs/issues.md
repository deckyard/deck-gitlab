<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Issues and merge requests

## Issues

```jennifer
def i as gitlab.Issue init gitlab.createIssue($c, "me/app", "Crash on start", "Steps: ...");
gitlab.setIssueLabels($c, "me/app", $i.iid, ["bug", "priority::high"]);
gitlab.setAssignees($c, "me/app", $i.iid, ["ada"]);
gitlab.addNote($c, "me/app", $i.iid, "Reproduced on 1.2.0.");
gitlab.closeIssue($c, "me/app", $i.iid);
```

`issues` lists `opened`, `closed` or `all` issues, newest first.
`setIssueLabels` replaces the labels, `addIssueLabels` and
`removeIssueLabel` change them one by one; a label that does not exist yet
is created. Each returns the issue as it is now. A label name holds no
comma: GitLab takes the list comma-separated.

`setAssignees` and `setReviewers` take user names and look up their ids;
GitLab Free keeps one assignee. `setMilestone` takes a milestone's `id`
(not its `iid`), 0 to take it out.

`notes` lists the notes oldest first, GitLab's own system notes (`isSystem`)
included. `editNote` and `deleteNote` need the issue's `iid` too: a note
belongs to its issue.

## Labels and milestones

```jennifer
gitlab.createLabel($c, "me/app", "bug", "#ee0701", "Something is broken");
def m as gitlab.Milestone init gitlab.createMilestone($c, "me/app", "1.2", "", "2026-12-31");
gitlab.setMilestone($c, "me/app", 12, $m.id);
gitlab.setMilestoneClosed($c, "me/app", $m.id, true);
```

A milestone is `active` or `closed`; `milestones` filters on those or `all`.

## Merge requests

```jennifer
def mr as gitlab.MergeRequest init gitlab.createMergeRequest(
    $c, "me/app", "fix/crash", "main", "Fix the crash", "Closes #12");
gitlab.approveMergeRequest($c, "me/app", $mr.iid, "");
def now as gitlab.MergeRequest init gitlab.mergeRequest($c, "me/app", $mr.iid);
if ($now.mergeable) {
    gitlab.mergeMergeRequest($c, "me/app", $mr.iid, $now.sha, true, true);
}
```

`mergeStatus` is GitLab's `detailed_merge_status`. GitLab works it out in
the background: right after a push or after `createMergeRequest` it reads
`preparing` or `checking`, and `mergeRequestCommits` may still be empty.
Poll `mergeRequest` until it settles.

`mergeMergeRequest` merges with the project's merge method; `squash`
squashes first and `removeSourceBranch` deletes the branch afterwards.
Passing the head `sha` makes the merge refuse (HTTP 409) when someone
pushed in between. HTTP 405 means it cannot be merged now: a draft,
conflicts, missing approvals or a pipeline that must succeed.

`approvals` reads who approved; `required` and `left` count only on GitLab
Premium and Ultimate. `mergeRequestChanges` lists the changed files with
their diffs, `mergeRequestNotes` and `addMergeRequestNote` the discussion.
