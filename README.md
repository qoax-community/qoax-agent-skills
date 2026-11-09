# qoax-agent-skills

Shared agent skills for Qoax repositories. Each skill is in this repository
one time. Other repositories copy the skills with the
[skills CLI](https://www.npmjs.com/package/skills) and pin them in
`skills-lock.json`. Claude Code can also install the skills as plugins from
this repository.

## Skills

| Skill | Plugin | Source | Commit | Licence |
| --- | --- | --- | --- | --- |
| `asd-ste100` | `asd-ste100` | `woosal1337/blog`, `videos/ep01-the-cure-for-ai-slop/asd-ste100` | `79c0288` | MIT, Ege Chelebi |
| `grill-me` | `qoax-agent-skills` | `mattpocock/skills`, `skills/productivity/grill-me` | `4ae2317` | MIT, Matt Pocock |
| `grilling` | `qoax-agent-skills` | `mattpocock/skills`, `skills/productivity/grilling` | `4ae2317` | MIT, Matt Pocock |
| `writing-code-comments` | `qoax-agent-skills` | `posthog/posthog`, `.agents/skills/writing-code-comments` | `f18803e` | MIT (Expat), PostHog Inc. |
| `github-templates` | `qoax-agent-skills` | this repository | | MIT, Qoax Community |

`upstream/sources.json` records the upstream commit of each third-party
skill. Each skill folder has its own `LICENSE` file, so the licence goes with
every copy.

ASD-STE100 is a trademark of ASD. The `asd-ste100` skill is unofficial, and
ASD does not support it. This repository does not include the ASD-STE100
specification.

Local changes to third-party skills:

- `asd-ste100`: `SKILL.md` tells the agent to keep the spelling of the
  repository or document. ASD-STE100 rule 1.14 asks for American spelling. The
  patch is in `upstream/patches/asd-ste100/`.
- `asd-ste100`: some upstream files are not copied. These are the hooks,
  tests, installer, output style, README and plugin manifest.
  `hooks/run-python.cjs` stays, because `SKILL.md` uses it to run the linter.
- `grill-me`, `grilling` and `writing-code-comments`: the upstream skill
  folders have no `LICENSE`. The `LICENSE` in each folder here is a copy of the
  file at the root of the upstream repository.

## Add the skills to a repository

Run this command in the root of the repository, on a computer that has a
`~/.claude` directory. Select only the skills that the repository needs:

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 add qoax-community/qoax-agent-skills \
  --skill asd-ste100 grill-me grilling writing-code-comments \
  -a claude-code codex gemini-cli -y
```

The CLI copies each skill to `.agents/skills/<name>`. Codex and Gemini CLI
read that folder. For Claude Code, the CLI adds a symbolic link
`.claude/skills/<name>`. Name more than one agent. With Claude Code only, the
CLI copies the skills into `.claude/skills` and does not write
`.agents/skills`.

Without `DISABLE_TELEMETRY=1`, the CLI sends usage data to skills.sh. Put it
in front of each skills CLI command, also in scripts and in `AGENTS.md`.

Then:

1. Commit `.agents/skills`, `.claude/skills` and `skills-lock.json`. Do not
   edit the files in `.agents/skills`. Change the skill in this repository.
2. Copy `templates/agent-skills.yml` to `.github/workflows/`.
3. Pin the action to the commit of a release tag. Get the commit in a clone of
   this repository:

   ```sh
   git rev-parse 'vX.Y.Z^{commit}'
   ```

   Then write `uses: qoax-community/qoax-agent-skills@<commit> # vX.Y.Z` in
   both jobs.

Some repositories do not commit `.agents`. After a clone, they restore the
skills from `skills-lock.json`:

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 experimental_install
```

## Update a repository

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y
```

Run it on a computer that has a `~/.claude` directory. If the home directory
has no agent directory, the CLI writes to every agent that it knows, for
example `agent/skills`. The CLI takes the skills from the main branch of this
repository. The lock records no commit.

The `update` command does not add a skill that is new in this repository. Use
`add` for a new skill. Commit the changes in `.agents/skills`,
`.claude/skills` and `skills-lock.json`.

The "Skills are current" job of `agent-skills.yml` runs once a week. It fails
when the main branch of this repository has a newer skill than the lock.

## Change a skill

- A Qoax skill: change it in `plugins/` and open a pull request.
- A third-party skill: do not edit the copied files.
  1. Run `node scripts/sync-upstream.mjs check`. It shows each skill whose
     upstream folder changed.
  2. Run `node scripts/sync-upstream.mjs pull NAME COMMIT`. It copies the
     files in `"files"` and the licence, applies the patches and updates
     `upstream/sources.json`.
  3. For a local change, add a patch to `upstream/patches/NAME/` and its
     file name to `"patches"`. Then run `pull` again.
  4. Run `node scripts/sync-upstream.mjs verify`. It builds each skill again
     at its pinned commit and compares it with `plugins/`.
- Before a pull request, run `node scripts/check-repo.mjs` and
  `sh scripts/self-test.sh`. The self-test installs every skill with the
  skills CLI and compares the hashes.

## Releases

A release is an annotated tag `vX.Y.Z` on `main`:

```sh
git tag -a vX.Y.Z -m vX.Y.Z
git push origin vX.Y.Z
```

Consumers pin the action by the commit of the tag, not by the tag name. Do not
move or delete a tag after you push it. Make a release when `action.yml` or
`scripts/check-skills-lock.mjs` changes. The skills CLI does not read the
tags.

## Claude Code

This repository is also a Claude Code plugin marketplace with the name
`qoax`:

```sh
claude plugin marketplace add qoax-community/qoax-agent-skills
claude plugin install asd-ste100@qoax
claude plugin install qoax-agent-skills@qoax
```

The plugin manifests have no `version`. Claude Code then uses the commit as
the version, and each change gets to the users.

## claude.ai

claude.ai organisation sync accepts only a private marketplace repository.
This repository is public, so organisation sync is not set up. Instead, build
a zip file for each plugin from a release tag:

```sh
git archive --format=zip -o asd-ste100.zip vX.Y.Z:plugins/asd-ste100
git archive --format=zip -o qoax-agent-skills.zip vX.Y.Z:plugins/qoax-agent-skills
```

An Owner of the claude.ai organisation uploads the two zip files in the
organisation settings. Then the Owner removes the old uploads.

## Commit messages

The `commit-msg` hook from
[qoax-githooks](https://github.com/qoax-community/qoax-githooks) checks each
commit message. Run this command once after a clone:

```sh
sh scripts/setup-hooks.sh
```

It checks out the `.githooks/shared` submodule and sets `core.hooksPath`. The
commit-conventions workflow runs the same check on each pull request.
