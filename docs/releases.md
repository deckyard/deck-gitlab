<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Releases and files

## Releases

A GitLab release belongs to a tag and is addressed by it. Its assets are
links; the files themselves live elsewhere, usually in the project's
generic package registry:

```jennifer
def rel as gitlab.Release init gitlab.createRelease($c, "me/app", "v1.2.0", "main", "", $notes);
gitlab.uploadAsset($c, "me/app", "v1.2.0", "app", "app-1.2.0.tar.gz", fs.readBytes("dist/app.tar.gz"));
```

`uploadAsset` puts the file into the generic package `app`, version
`v1.2.0` (the tag), and links it to the release as a `package` link.
`uploadPackageFile` does only the upload and returns the file's download
URL; `addReleaseLink` links any URL, such as a download page elsewhere.
Package names and versions are letters, digits and `._+-`; file names may
also hold `~` and `@`.

`createRelease` creates the tag at `ref` when it does not exist; with `""`
the tag must exist. `latestRelease` is the one with the latest release date
that is not upcoming. `editRelease` changes the title or notes,
`deleteRelease` removes the release and keeps the tag.

```jennifer
def latest as gitlab.Release init gitlab.latestRelease($c, "me/app");
for (def l in $latest.links) {
    fs.writeBytes($l.name, gitlab.downloadAsset($c, $l, 268435456));
}
```

`downloadAsset` holds the file in memory and refuses one over its limit,
64 MiB with 0. It downloads only links on the instance, with the token; a
redirect to object storage is followed without it.

## Branches and tags

```jennifer
gitlab.createBranch($c, "me/app", "release/1.2", "main");
gitlab.createTag($c, "me/app", "v1.2.0", "release/1.2", "Release 1.2.0");
gitlab.deleteBranch($c, "me/app", "release/1.2");
```

A tag with a message is annotated; `""` makes a lightweight one. Protected
branches and tags refuse to be deleted. Names with `/` are fine.

## Files

`readFile` reads a file at a branch, tag or commit, a file in Git LFS as its
content; `writeFile` commits a new version, or the first one:

```jennifer
def v as string init encoding.decode("utf-8", gitlab.readFile($c, "me/app", "VERSION", "main", 0));
gitlab.writeFile($c, "me/app", "VERSION", encoding.encode("utf-8", "1.2.1"), "Bump to 1.2.1", "main");
```

Each `writeFile` and `deleteFile` is a commit of its own, made through the
commits API, and returns its SHA. `writeFile` asks first whether the file
exists, to create or update it; a branch of `""` is the default branch.

`listDirectory` lists one directory, `""` the root; `listTree` every entry
below it. An entry's `type` is `blob`, `tree` or `commit` (a submodule).

```jennifer
for (def e in gitlab.listDirectory($c, "me/app", "docs", "main")) {
    io.printf("%s %s\n", $e.type, $e.path);
}
```
