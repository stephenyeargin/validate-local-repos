# validate-local-repos

Keeps a folder of git checkouts up to date. For every repo directly under the
target directory it fetches all remotes in parallel, then fast-forwards the
current branch when it is behind and has no local changes. Repos that are
ahead, diverged, detached, missing an upstream, or have uncommitted work are
flagged instead of touched.

## Install

```sh
flox install stephenyeargin/validate-local-repos
```

## Usage

```sh
validate-local-repos [options] [dir]
```

`dir` defaults to `$VALIDATE_REPOS_DIR`, or `~/Sites` if that is unset.

| Option           | Effect                                  |
| ---------------- | --------------------------------------- |
| `-v, --verbose`  | Show raw git output                     |
| `--only-errors`  | Show only repos with errors             |
| `--only-updated` | Show only repos that pulled new commits |
| `--version`      | Show version                            |
| `-h, --help`     | Show help                               |

```sh
validate-local-repos ~/code
VALIDATE_REPOS_DIR=~/code validate-local-repos --only-errors
```

Each repo gets one row: `✓` up to date or pulled, `⚠` needs attention, `✗`
error, followed by a summary line. Git runs non-interactively, so repos that
need a password or SSH passphrase report an authentication error rather than
prompting.

## Releases

Bump `VERSION` in `update.sh` and push to `main`. When no
`v<version>` tag exists yet, GitHub Actions publishes every system and then
creates the tag and GitHub release. Don't tag by hand, and don't run
`flox publish` locally.
