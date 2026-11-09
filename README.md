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

1. Add this line to `.gitattributes`, below any `* text` line. The file
   `templates/gitattributes` has the line with a comment. The "Line endings"
   section below tells why.

   ```gitattributes
   /.agents/skills/** -text
   ```

2. Commit `.gitattributes`, `.agents/skills`, `.claude/skills` and
   `skills-lock.json`. Do not edit the files in `.agents/skills`. Change the
   skill in this repository.
3. Copy `templates/agent-skills.yml` to `.github/workflows/`.
4. Pin the action to the commit of a release tag. Get the commit in a clone of
   this repository:

   ```sh
   git rev-parse 'vX.Y.Z^{commit}'
   ```

   Then write `uses: qoax-community/qoax-agent-skills@<commit> # vX.Y.Z` in
   both jobs.
5. In `AGENTS.md`, tell Windows users to clone with symbolic links. The
   "Symbolic links" section below gives the steps.

Commit the skills from this repository, also in a repository that does not
commit its other skills. A new clone, a Claude Code worktree or a cloud
session does not run a restore step. Claude Code then skips each link to a
missing folder and shows no message. Also, `experimental_install` takes each
skill from the main branch of its source, not the version in the lock.

To ignore only the other skills, put these lines in `.gitignore`. Add one `!`
line for each skill from this repository:

```gitignore
/.agents/skills/*
!/.agents/skills/asd-ste100/
!/.agents/skills/grill-me/
```

The other skills have lock entries, so the lock check accepts their folders
and needs no `allow` input. A restore step with `experimental_install` also
installs the committed skills again. When the main branch of this repository
has a newer skill, git then shows changes in `.agents/skills` and
`skills-lock.json`. Commit them as an update, or discard them.

### Symbolic links

Each `.claude/skills/<name>` is a symbolic link. Git makes the links only when
`core.symlinks` is `true`. Git for Windows sets it to `false` by default.
Then each link is a small text file, and Claude Code loads none of the skills.
The lock check in CI does not find this problem, because CI runs on Linux.

On Windows, turn on Developer Mode. Then clone with:

```sh
git clone -c core.symlinks=true URL
```

To repair a clone that has text files in place of the links, run these
commands in its root:

```sh
git config core.symlinks true
rm -r .claude/skills
git checkout -- .claude/skills
```

A zip download of the repository has the same problem on Windows, so use a
clone. To check a clone, run this command in a clone of this repository:

```sh
node scripts/check-skills-lock.mjs --root PATH --source qoax-community/qoax-agent-skills
```

### Line endings

Git for Windows sets `core.autocrlf` to `true` by default. Git then writes
text files with CRLF line endings. The skills CLI and the lock check take the
hash of the bytes in each skill file. With CRLF, the lock check fails with a
hash error, and `update` writes hashes that the CI check does not accept.

The `-text` attribute stops this change. A consumer repository sets it on
`.agents/skills` in step 1 of "Add the skills". This repository sets it on
`plugins/` and `upstream/`. The skills CLI clones this repository, so its
copies also keep LF line endings. The shell scripts of this repository also
keep LF, because `sh` stops at a CRLF line ending.

To repair a clone that has CRLF line endings in the skills, get the commit
with the `.gitattributes` line. Then run these commands in its root:

```sh
rm -r .agents/skills
git checkout -- .agents/skills
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
- After the merge, make a release and upload the new zip files to claude.ai.
  Without a release, claude.ai keeps the old skill.

## Releases

A release is an annotated tag `vX.Y.Z` on `main`. Make a release after each
merge that changes `plugins/`, `action.yml` or
`scripts/check-skills-lock.mjs`:

```sh
git tag -a vX.Y.Z -m vX.Y.Z
git push origin vX.Y.Z
```

The release workflow then builds a zip file for each plugin and attaches it
to the GitHub release. Upload the zip files to claude.ai. The "claude.ai"
section below gives the steps.

Consumers pin the action by the commit of the tag, not by the tag name. Do not
move or delete a tag after you push it. The skills CLI does not read the tags.

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

Do not use the plugins in a repository that has the skills in
`.claude/skills`. There, Claude Code loads two copies of each skill: the
copy in the repository and the plugin copy, for example
`asd-ste100:asd-ste100`. The plugin copy comes from the main branch, so it can
be different from the copy that `skills-lock.json` pins. To use only the copy
in the repository, disable the plugins in its `.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "asd-ste100@qoax": false,
    "qoax-agent-skills@qoax": false
  }
}
```

## claude.ai

claude.ai organisation sync accepts only a private marketplace repository.
This repository is public, so organisation sync is not set up. Instead, an
Owner of the claude.ai organisation uploads a zip file for each plugin after
each release:

1. Get `asd-ste100.zip` and `qoax-agent-skills.zip` from the GitHub release.
   If the release has no zip files, run the release workflow by hand with
   the tag. Or build them in a clone of this repository:

   ```sh
   sh scripts/build-zips.sh vX.Y.Z
   ```

   The script writes the zip files to `dist/`.
2. In the organisation settings, remove the old uploads of the two plugins.
3. Upload the two new zip files.

Remove the old uploads first. The uploads before v1.0.0 came from other
repositories. Their versions are 2.0.5 (`asd-ste100`) and 1.0.0
(`qoax-agent-skills`). The new zip files have version 1.0.0. That is not
higher than the old versions. When the old uploads are gone, the organisation
has one copy of each plugin, with the release version.

Each zip file has the release version in its `plugin.json`. Compare it with
the latest release to see if claude.ai has the current skills. The
`plugin.json` files in this repository have no version, so the version is
only in the zip files.

## Commit messages

The `commit-msg` hook from
[qoax-githooks](https://github.com/qoax-community/qoax-githooks) checks each
commit message. Run this command once after a clone:

```sh
sh scripts/setup-hooks.sh
```

It checks out the `.githooks/shared` submodule and sets `core.hooksPath`. The
commit-conventions workflow runs the same check on each pull request.
