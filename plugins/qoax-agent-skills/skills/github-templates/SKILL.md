---
name: github-templates
description: Follow the organization-wide pull request and issue templates from qoax-community/.github when opening or editing a PR or issue. Required before running `gh pr create`, `gh pr edit`, `gh issue create`, or writing a PR title, because the gh CLI bypasses templates and the PR title is validated as a commit message.
---

# Use the organization's templates

This repository carries no templates of its own. They come from
`qoax-community/.github`, which supplies defaults to every repository in the
organization.

| Template | Path in `qoax-community/.github` |
|---|---|
| Pull request | `.github/PULL_REQUEST_TEMPLATE.md` |
| Bug report | `.github/ISSUE_TEMPLATE/bug-report.yml` |
| Feature request | `.github/ISSUE_TEMPLATE/feature-request.yml` |

Read the current one before writing anything. Do not reproduce it from memory or
from this file, because it changes in one place for the whole organization:

```sh
gh api repos/qoax-community/.github/contents/.github/PULL_REQUEST_TEMPLATE.md \
  --jq .content | base64 -d
```

**Never add a template to this repository.** A local
`.github/PULL_REQUEST_TEMPLATE.md` silently overrides the organization default,
which is the opposite of what anyone wants. Three were added here once and had to
be removed.

## The gh CLI ignores templates

GitHub's web interface fills the template in. The CLI does not when you supply a
body:

- `gh pr create --body "..."` uses your text and ignores the template.
- `gh pr create --fill` builds the body from commit messages and ignores it too.
- `gh issue create --body "..."` behaves the same way.

The `-T/--template` flag only seeds an interactive editor, so it is no help in a
non-interactive run and does not combine with `--body`. Nothing fails and no
check complains. The pull request is simply in the wrong format.

So fetch the template, fill every section, and pass the result with
`--body-file`. Keep the headings exactly as they are, so pull requests stay
comparable. `gh pr edit --body-file` replaces the body wholesale, so re-supply
the whole template rather than the part being changed.

## The pull request title is validated

The `commit-conventions` check runs the shared `commit-msg` hook over every
commit **and over the pull request title**, because a squash merge turns the
title into the subject on `main`. A title such as "Build out the monorepo" fails
with "unknown type" and "whitespace inside the type/scope prefix".

Write the title as a Conventional Commit: `feat: build out the api and codegen
pipeline`. Check it before setting it:

```sh
printf 'feat: your title here\n' > /tmp/title
COMMIT_MSG_REPORT_ONLY=1 .githooks/commit-msg /tmp/title
```

Never put an AI attribution trailer in a commit message or a pull request body.
The hook rejects it by name.

## Filling the sections

Answer what each section asks, and say so plainly when a section does not apply
rather than deleting its heading. A missing section reads the same as an
overlooked one.

`Validation` carries the most weight. Name what ran and what it produced. "Tests
pass" says less than "adding a query produced the diff CI fails on, and reverting
returned a clean tree". State plainly whatever could not be checked, instead of
leaving the reader to assume it was.
