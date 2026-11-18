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
| `modern-web-guidance` | `modern-web-guidance` | `GoogleChrome/modern-web-guidance`, `skills/modern-web-guidance` | `64a6d70` | Apache-2.0 and CC BY 4.0, Google Chrome |
| `chrome-extensions` | `chrome-extensions` | `GoogleChrome/modern-web-guidance`, `skills/chrome-extensions` | `64a6d70` | Apache-2.0 and CC BY 4.0, Google Chrome |
| `github-templates` | `qoax-agent-skills` | this repository | | MIT, Qoax Community |

`upstream/sources.json` records the upstream commit of each third-party
skill. Each skill folder has its own `LICENSE` file, so the licence goes with
every copy.

The `modern-web-guidance` and `chrome-extensions` plugins are not MIT.
Upstream puts its code under Apache-2.0, and its documentation and guide
content in `guides/` under CC BY 4.0. The two copies have no `guides/`
folder, but they treat their documentation files as CC BY 4.0 too. The two
skill folders also have a `NOTICE` file. It gives the source, the licences,
the credit to MDN, W3C, WHATWG and IETF, and the local changes. Keep
`LICENSE` and `NOTICE` with each copy.

ASD-STE100 is a trademark of ASD. The `asd-ste100` skill is unofficial, and
ASD does not support it. This repository does not include the ASD-STE100
specification.

The `modern-web-guidance` and `chrome-extensions` plugins are unofficial
copies. Google does not support them.

Local changes to third-party skills:

- `asd-ste100`: `SKILL.md` tells the agent to keep the spelling of the
  repository or document. ASD-STE100 rule 1.14 asks for American spelling. The
  patch is in `upstream/patches/asd-ste100/`.
- `asd-ste100`: some upstream files are not copied. These are the hooks,
  tests, installer, output style, README and plugin manifest.
  `hooks/run-python.cjs` stays, because `SKILL.md` uses it to run the linter.
- `modern-web-guidance`: the copy has only `SKILL.md`, not the guides. The
  CLI reads the guides from its npm package, not from the skill folder.
- `modern-web-guidance`: `SKILL.md` pins the CLI to version 1.0.1. The
  `search`, `retrieve` and `legacy-scan` commands start with
  `DISABLE_TELEMETRY=1 npx --prefer-offline -y modern-web-guidance@1.0.1`.
  The offline retry uses `--offline` in place of `--prefer-offline`. Where a
  guide shows `@latest`, the agent uses `@1.0.1` and keeps
  `DISABLE_TELEMETRY=1`.
- `modern-web-guidance`: without `DISABLE_TELEMETRY=1`, the CLI sends the
  search text, the guide ids and the agent name to Google. The npm integrity
  of 1.0.1 is
  `sha512-5ztUh5F1p2PewnSkA6EhsGUXqomaZY9qe6iWJCU4JbIQxHTky7s5lMJcPE4EbD1uhbQZIhl0HROH0+s6fIiGzg==`.
  The skill does not pin this value. Compare it with `npm view` at each
  update.
- `modern-web-guidance`: the agent always uses `npx`, not `pnpx`. It does not
  run the CLI commands `install`, `update`, `uninstall`, `set-baseline`,
  `set-allow-origin-trials` and `set-allow-volatile-features`. These commands
  install skills without a pin, or write `.mwgrc` into the repository.
- `modern-web-guidance`: the patch removes Step 4, which adds a
  `### Modern Web Guidance` section to each reply. The agent names a guide id
  only where it explains a choice.
- `modern-web-guidance`: a line after the frontmatter says that Qoax
  Community changed the file. The patch is in
  `upstream/patches/modern-web-guidance/`.
- `chrome-extensions`: the upstream files have no change. The patch in
  `upstream/patches/chrome-extensions/` adds only `NOTICE`.
- `grill-me`, `grilling`, `writing-code-comments`, `modern-web-guidance` and
  `chrome-extensions`: the upstream skill folders have no `LICENSE`. The
  `LICENSE` in each folder here is a copy of the file at the root of the
  upstream repository.

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
5. Install the skills bot on the repository. The "Update pull requests"
   section tells how. The bot moves the skills and the pin of the action.
   Without the bot, and if `.github/dependabot.yml` has an `allow` list for
   `github-actions`, add this entry to it. Without the entry, Dependabot
   does not bump the pin of the action:

   ```yaml
   - dependency-name: "qoax-community/qoax-agent-skills"
   ```

6. In `AGENTS.md`, tell Windows users to clone with symbolic links. The
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

### Web repositories

A repository with browser code also gets the `modern-web-guidance` skill. A
repository with a browser extension also gets `chrome-extensions`. Add the
skills with the same command:

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 add qoax-community/qoax-agent-skills \
  --skill modern-web-guidance -a claude-code codex gemini-cli -y
```

For a browser extension, use `--skill modern-web-guidance chrome-extensions`.

The skill runs the `modern-web-guidance` CLI with npx. Each computer that
uses the skill needs Node 22 or later and access to registry.npmjs.org.

Then do these steps, in addition to the steps above:

1. In `AGENTS.md`, add a short "Web guidance" paragraph:
   - The skill needs Node 22 or later and access to registry.npmjs.org.
   - Use the version of the `modern-web-guidance` CLI that the skill names.
   - Do not run these commands of the `modern-web-guidance` CLI: `install`,
     `update`, `uninstall`, `set-baseline`, `set-allow-origin-trials` and
     `set-allow-volatile-features`.
   - Do not install a `modern-web-guidance` plugin from another marketplace
     for this repository.
2. In `AGENTS.md`, add a `**Browser Support:**` line that names the browsers
   or the Baseline target of the repository. Without it, the skill adds a
   fallback for each feature that is not Baseline Widely available.
3. In `.claude/settings.json`, turn off the plugin copies of the skill. The
   `@qoax` copy comes from the main branch of this repository, not from the
   lock. The other two copies run the `@latest` CLI with telemetry on:

   ```json
   {
     "enabledPlugins": {
       "modern-web-guidance@qoax": false,
       "modern-web-guidance@claude-plugins-official": false,
       "modern-web-guidance@googlechrome": false
     }
   }
   ```

   For a browser extension, also add `"chrome-extensions@qoax": false`. If
   the repository commits other skills from this repository, also turn off
   their plugins. The "Claude Code" section below gives the names.

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

The skills bot opens the update pull request. The "Update pull requests"
section below tells how it works. To update by hand, run this command in a
clone of this repository. `PATH` is the root of a clean clone of the
consumer repository:

```sh
sh scripts/update-skills.sh --root PATH --bump-pin
```

The script updates only the skills from this repository, also in a
repository that has skills from other sources. It installs the skills CLI from
`scripts/skills-cli/package-lock.json` into a cache folder, so an `.npmrc` in
the consumer cannot change the package. It runs the CLI with a scratch home
directory, so the computer needs no `~/.claude` directory. Then it makes sure
that only the skills, their links, `skills-lock.json` and the pin changed, and
runs the lock check. Commit the changes.

The plain skills CLI command also works:

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y
```

Run it on a computer that has a `~/.claude` directory. If the home directory
has no agent directory, the CLI writes to every agent that it knows, for
example `agent/skills`. Without skill names, it also updates the skills of
other sources. The CLI takes the skills from the main branch of this
repository. The lock records no commit.

The `update` command does not add a skill that is new in this repository. Use
`add` for a new skill. Commit the changes in `.agents/skills`,
`.claude/skills` and `skills-lock.json`.

The "Skills are current" job of `agent-skills.yml` runs once a week. It fails
when the main branch of this repository has a newer skill than the lock.

## Update pull requests

The "Update consumers" workflow opens one pull request in each consumer
repository, as Dependabot does for a dependency. A consumer is a repository
where the `qoax-skills-bot` GitHub App is installed and whose
`skills-lock.json` has a skill from this repository. The workflow runs after
each successful run of the "Release" workflow, each Monday, and by hand.

In each consumer, the pull request does two things:

- It updates the skills from this repository to the main branch, with
  `scripts/update-skills.sh`. It does not change the skills of other sources.
- It moves the pin of this action in `.github/workflows` to the latest
  release. This is the bump that Dependabot opens as its own pull request,
  so the bot closes that Dependabot pull request.

The branch is `agent-skills/update`. Each run makes it again from the default
branch, with one `ci:` commit for the pin and one `chore:` commit for the
skills. The App is the author. When nothing changed and the pull request is
still open, the bot closes it. When a person pushes a commit to the branch,
or amends a commit of the bot, the bot does not change the branch while the
pull request is open. After a close without a merge, the bot makes the
branch again.

The App token makes the pull request, so the checks of the consumer run as
they do for a person. A pull request from `GITHUB_TOKEN` starts no workflow
run until a person approves it. `GITHUB_TOKEN` also cannot change a workflow
file, so it cannot move the pin.

The workflow has two jobs, so that no job has both the skills CLI and a token
that can write:

1. "Prepare" clones each consumer with an App token that can only read. Then
   it revokes the token and runs `scripts/update-pr.sh --prepare`. The result
   for each consumer is a patch and the texts of the pull request.
2. "Publish" gets an App token that can write. `scripts/publish-pr.sh`
   applies each patch to a new clone and checks each path again. Only the
   skills of this repository, their links, `skills-lock.json` and the pin
   lines may change. Then it pushes the branch and opens the pull request.

The token goes to git only in the environment of each git command, not into
`.git/config` and not onto the command line. The workflow starts on
`workflow_run`, so GitHub always runs the workflow file of `main`. A tag on a
commit that nobody reviewed thus cannot run a changed copy with the App key.

### Set up the bot

Do these steps one time. Steps 1 to 3 need an owner of qoax-community.

1. In the qoax-community organisation settings, make a GitHub App:
   - Name: `qoax-skills-bot`. Homepage URL: this repository.
   - Webhook: off.
   - Repository permissions: Contents, Pull requests and Workflows, each
     "Read and write". Metadata stays "Read-only".
   - Where the App can be installed: "Any account". The personal account
     angel-penchev has consumers too, and a private App can only go on the
     account that owns it.
2. Make a private key for the App. Write down the Client ID.
3. Install the App on qoax-community and on angel-penchev. Select only the
   consumer repositories.
4. In this repository, make the environment `skills-bot`:
   - Deployment branches and tags: "Selected branches and tags", with the
     branch `main` only.
   - Environment secret `SKILLS_BOT_PRIVATE_KEY`: the private key.
   - Environment variable `SKILLS_BOT_CLIENT_ID`: the Client ID.
5. Add a ruleset for `main` that requires a pull request. The environment
   trusts each workflow file on `main`. Without the ruleset, each person with
   write access can push a changed workflow to `main` and use the key.
6. Run "Update consumers" by hand with "dry-run" on. The log shows each pull
   request that the bot would open. Then run it again with "dry-run" off.

GitHub Free does not give organisation secrets to private repositories. Thus
the key is in this repository only, not in each consumer.

To add a consumer, install the App on it. To stop the bot in one
repository, remove the repository from the installation. The matrix of the
workflow lists the owners. When a consumer has a new owner, add the owner
there and install the App on it.

### Without the App

A repository can run the update itself with its own `GITHUB_TOKEN`. Add this
job to its `agent-skills.yml`:

```yaml
  update:
    name: Update the skills
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
        with:
          persist-credentials: false
      - uses: qoax-community/qoax-agent-skills@<commit> # vX.Y.Z
        with:
          update: "true"
```

Then:

1. In Settings > Actions > General of the repository, turn on "Allow GitHub
   Actions to create and approve pull requests".
2. On each update pull request, select "Approve workflows to run" in the
   merge box.
3. Keep the Dependabot bump of this action. Leave `bump-pin` off, because
   `GITHUB_TOKEN` cannot change a workflow file.

In this mode, the skills CLI runs in the same job as the token. The script
removes the token from the environment of the CLI, but a process of the same
job can still read it. The token can write only to this one repository.

## Skills from other sources

A repository can also add skills straight from another source, for example
`shadcn` from `shadcn/ui`. The default check reads only the lock entries of
this repository. With the `other-sources` input, the action also checks the
other entries:

- `report`: each finding is a warning in the job and in the job summary.
  The job does not fail. The template uses it in "Skills are current".
- `fail`: each finding fails the job.
- `off`: the action does not read them. This is the default.

In "Skills match the lock", the action compares each copy in the repository
with the lock. It reads `.agents/skills/<name>`, or a real folder
`.claude/skills/<name>`. It does not check a skill that the repository does
not commit, for example one that a bootstrap step installs. In "Skills are
current", the action clones the skill folders of each other GitHub source,
with no history, and compares them with the lock.

The update bot does not change these skills. To update one, read the
upstream change, then run:

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y NAME
```

## Change a skill

- A Qoax skill: change it in `plugins/` and open a pull request.
- A third-party skill: do not edit the copied files.
  1. Run `node scripts/sync-upstream.mjs check`. It shows each skill whose
     upstream folder changed, and then exits with status 3. A change of a
     source with `"check": "report"` in `upstream/sources.json` does not
     give status 3. Use it for an upstream that releases more often than we
     update the pin. The "Upstream skills" workflow runs the check each
     Monday and writes the result to its job summary.
  2. Run `node scripts/sync-upstream.mjs pull NAME COMMIT`. It copies the
     files in `"files"` and the licence, applies the patches and updates
     `upstream/sources.json`.
  3. For a local change, add a patch to `upstream/patches/NAME/` and its
     file name to `"patches"`. Then run `pull` again.
  4. Run `node scripts/sync-upstream.mjs verify`. It builds each skill again
     at its pinned commit and compares it with `plugins/`.
- Before a pull request, run `node scripts/check-repo.mjs`,
  `sh scripts/self-test.sh` and `bash scripts/test-update-pr.sh`. The
  self-test installs every skill with the skills CLI and compares the
  hashes. The update test runs the bot on a scratch repository with a fake
  `gh`. It needs bash 4 or later and `jq`.
- After the merge, make a release as "Releases" tells.

### Update modern-web-guidance

Upstream releases the `modern-web-guidance` and `chrome-extensions` skills
almost each week. The "Upstream skills" workflow shows a new release in its
job summary, but the job does not fail. Update the pin at most once a month.

Do not let the pin get older than 60 days. The age counts from the date at
the start of the `--skill-version` value in `SKILL.md`. The pinned CLI has
the same skill version and shows no warning. But an agent can run a newer
CLI, for example the `@latest` form from a guide. After 60 days, that CLI
tells the agent to make the user update the skill. For 1.0.1, the skill
version starts with `2026_11_10`, so update before 2027-01-09.

1. Get the commit of the new release tag. For an annotated tag, use the line
   that ends in `^{}`:

   ```sh
   git ls-remote https://github.com/GoogleChrome/modern-web-guidance.git 'refs/tags/vX.Y.Z*'
   ```

2. Examine the npm package of the release. Do not run it:

   ```sh
   npm view modern-web-guidance@X.Y.Z dependencies scripts dist.integrity dist.attestations
   ```

   The output must show no `dependencies`, no `scripts` and a provenance
   attestation. Keep the `dist.integrity` value for this README.
3. In a new empty folder, get the package and read its skill version:

   ```sh
   npm pack --ignore-scripts modern-web-guidance@X.Y.Z
   tar -xzf modern-web-guidance-X.Y.Z.tgz
   cat package/skills/modern-web-guidance/skill-version.txt
   ```

   The value must be the same as `--skill-version` in the new upstream
   `SKILL.md`.
4. Make sure that the upstream commit has no `NOTICE` file. If it has one,
   add its text to the two `NOTICE` files.
5. Make the patch of each skill again, because each `NOTICE` has the commit.
   `NAME` is `modern-web-guidance` or `chrome-extensions`. `PATCH` is the
   file name in `"patches"`.
   1. In `upstream/sources.json`, set `"patches"` of `NAME` to `[]`.
   2. Copy the upstream files. Put them in the index for the diff in
      sub-step 5. Then apply the old patch where it still fits:

      ```sh
      dir=plugins/NAME/skills/NAME
      node scripts/sync-upstream.mjs pull NAME COMMIT
      git add "$dir"
      git apply --reject --directory="$dir" upstream/patches/NAME/PATCH
      ```

   3. Apply each `.rej` hunk by hand, then delete the `.rej` files.
   4. Put the new version and commit in `SKILL.md` and `NOTICE`.
   5. Write the new patch:

      ```sh
      git add -N "$dir"
      git diff --relative="$dir" >upstream/patches/NAME/PATCH
      ```

   6. Put `PATCH` back in `"patches"` and run `pull` again.
   7. Reset the index of the folder. Without this step, a commit can take the
      upstream files from sub-step 2, not the patched files:

      ```sh
      git reset -q -- "$dir"
      ```

6. Run `node scripts/sync-upstream.mjs verify`, `node scripts/check-repo.mjs`
   and `sh scripts/self-test.sh`.
7. In this README, change the commit in the skills table. Change the version
   and the npm integrity in "Local changes". In the 60-day paragraph above,
   change the version and the two dates.
8. Open a pull request. After the merge, make a release.
9. After the release, "Update consumers" opens an update pull request in
   each web repository, with the skills and the new pin. Without the bot,
   update each one as "Update a repository" tells. If Dependabot opens a pull
   request that moves the pin of this action to the new release, put that
   change in the same pull request. Then close the Dependabot pull request.

### Stop or remove modern-web-guidance

Use these steps when a CLI release is bad or the skill must go:

- **Stop the CLI in one repository at once.** Add this line to the "Web
  guidance" text of its `AGENTS.md`: "Do not run the `modern-web-guidance`
  CLI." Agents read it when a session starts.
- **Stop the CLI everywhere.** Change the patch so that `SKILL.md` tells
  agents not to run the CLI. Make a release, then update each web
  repository.
- **Remove the skill.** Delete the plugin and its source here, and make a
  release. In each web repository, run
  `DISABLE_TELEMETRY=1 npx skills@1.7.3 remove modern-web-guidance -y` and
  remove the "Web guidance" text. Until that pull request merges, the
  "Skills are current" job of the repository fails and names the `remove`
  command.
- **One person.** A person can tell the agent not to use the skill in a
  session. No permanent personal opt-out is tested.

An npm version cannot change after its publish. But the publisher can
unpublish a version in the first 72 hours. Pin a version only when it is
older than 72 hours.

## Releases

A release is an annotated tag `vX.Y.Z` on `main`. Make a release after each
merge that changes `plugins/`, `action.yml` or
`scripts/check-skills-lock.mjs`:

```sh
git tag -a vX.Y.Z -m vX.Y.Z
git push origin vX.Y.Z
```

The release workflow then makes the GitHub release, with notes from the
merged pull requests.

Consumers pin the action by the commit of the tag, not by the tag name. Do not
move or delete a tag after you push it. The skills CLI does not read the tags.

## Claude Code

This repository is also a Claude Code plugin marketplace with the name
`qoax`:

```sh
claude plugin marketplace add qoax-community/qoax-agent-skills
claude plugin install asd-ste100@qoax
claude plugin install qoax-agent-skills@qoax
claude plugin install modern-web-guidance@qoax
```

Install `chrome-extensions@qoax` only for work on browser extensions.

Anthropic's `claude-plugins-official` marketplace and Google's `googlechrome`
marketplace also have a `modern-web-guidance` plugin. Those copies run the
`@latest` CLI with telemetry on. Use `modern-web-guidance@qoax`. If you have
one of the other copies, uninstall it:

```sh
claude plugin uninstall modern-web-guidance@claude-plugins-official
claude plugin uninstall modern-web-guidance@googlechrome
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
    "qoax-agent-skills@qoax": false,
    "modern-web-guidance@qoax": false,
    "chrome-extensions@qoax": false
  }
}
```

## claude.ai

This repository has no claude.ai upload. The skills reach agents in two ways:

- the copies in each repository, which the skills CLI adds and the lock pins
- the `qoax` marketplace for Claude Code

claude.ai organisation sync accepts only a private marketplace repository, and
this repository is public. An upload also syncs into the Claude desktop app,
next to the copies in each repository. Then the agent has two copies of each
skill, and a repository cannot turn off the uploaded copy.

Remove the old uploads of `asd-ste100` and `qoax-agent-skills` from the
claude.ai organisation settings and from your personal uploads.

## Commit messages

The `commit-msg` hook from
[qoax-githooks](https://github.com/qoax-community/qoax-githooks) checks each
commit message. `.githooks/commit-msg` is a tracked copy of that hook. Run
this command once after a clone:

```sh
sh scripts/setup-hooks.sh
```

It sets `core.hooksPath` to `.githooks`. The commit-conventions workflow pins
a release of qoax-githooks by commit. On each pull request, it runs the same
check and compares the copy with the hook of that release. When a Dependabot
bump changes the hook, the bump pull request must also sync the copy. The
[qoax-githooks README](https://github.com/qoax-community/qoax-githooks#readme)
gives the details.
