---
title: Publishing
order: 0
---

## How does the registry work?

The lde registry is hosted on a GitHub repository for everyone to access and send
pull requests to.

Packages are simply links to git repositories hosted anywhere with a few bits of metadata such as package description, authors, license, and tags.

## Logging in

Publishing is programmatic: `lde publish` creates a branch, a commit, and a pull request through the GitHub API. Sign in once with the GitHub device flow:

```sh
lde login
```

The command prints a short code and opens `https://github.com/login/device`. The
stored session expires after eight hours and refreshes automatically; run
`lde logout` to remove it.

Two-factor authentication must be enabled on the GitHub account. `lde publish`
refuses to run without it, and the registry website rejects namespace and owner
changes from accounts without 2FA.

`lde login` needs a GitHub OAuth App client ID. The client ID is public and is
read from `github.clientId` in `~/.lde/config.json` (or
`LDE_GITHUB_CLIENT_ID`). The CLI requests `public_repo offline_access` and
stores no client secret. Contributors without write access publish through a
fork, so the registry never needs to grant them write access.

## Creating packages

`lde publish` reads your `lde.json`, resolves the current git commit, checks
whether you are allowed to publish the name, and opens the pull request:

```sh
lde publish
```

What happens next depends on the package:

- **First publish:** the bot validates the portfile, approves it, and waits for a
  moderator. This prevents name squatting.
- **You own the package:** the bot approves and auto-merges the version update.
- **You do not own it:** `lde publish` stops before opening a pull request.

Use `lde publish --dry-run` to print the authorization check and the generated
portfile without pushing anything.

## Updating packages

Bump the version in `lde.json`, then run `lde publish` again. Existing versions
are immutable; a version can be published once.

A package may move to a different git repository or branch. When the current
source differs from the portfile's top-level `git`/`branch`, `lde publish`
records the new source on that version:

```json
{
	"versions": {
		"1.0.0": "5d4bb28703d8f1c17a0e241810145194a51042f0",
		"2.0.0": {
			"commit": "9f1c2e...",
			"git": "https://github.com/new-owner/new-repo",
			"branch": "main"
		}
	}
}
```

Older versions keep resolving to the repository they were published from.

## Tarball releases

A version can come from a hash-pinned tarball instead of a git repository:

```sh
lde publish --archive https://example.com/hood-1.0.0.tar.gz
```

`lde publish` downloads the archive, computes its SHA-256, and publishes both
the URL and the hash. Pass `--sha256 <hash>` to check a known hash before
publishing. The installer downloads the same URL, verifies the hash, and only
then extracts it; a changed source is rejected.

Git publishes also record the SHA-256 of the archive the client will download.
If the host regenerates byte-different archives for the same commit, installs
fail closed; publish the release as a tarball with `--archive` when you need a
stable artifact.

```json
{
	"versions": {
		"1.0.0": {
			"archive": "https://example.com/hood-1.0.0.tar.gz",
			"sha256": "9f2c4e8a7b6d5c3e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e"
		}
	}
}
```

The hash is a content commitment stored in the trusted registry. It protects
against a source server changing after publication; it is not an author
signature. Signing with a personal key needs a separate key distribution and
trust policy.

## Tags

Add `tags` to `lde.json` to make the package easier to find:

```json
{
	"tags": ["json", "parser"]
}
```

Tags are lowercase, at most 10, and unique. They are included in the registry
index and matched by `lde search`.

## Security

The registry repository is public and every portfile change is a pull request.
The bot never executes code from a pull request; it reads the changed files with
`git show` and validates them against the schema.

Ownership is recorded by numeric GitHub id in `authority.json`. A package owner
can add co-owners through the registry website; the resulting pull request may
only append owner ids and must be merged by a maintainer.
