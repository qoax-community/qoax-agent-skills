#!/usr/bin/env bash
# Test update-skills.sh and update-pr.sh without GitHub.
#
# A scratch "source" repository has the skills of this checkout and two
# release tags. A git insteadOf rule sends https://github.com/<source>.git to
# it, so the skills CLI, ls-remote and the pin bump read it. A scratch
# consumer has a bare "origin". A fake gh records each call. A wrapper around
# npx records the environment that the skills CLI gets.
#
# Needs bash 4, node, git and npm (the skills CLI comes from the npm registry).
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "test-update-pr: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
source=qoax-community/qoax-agent-skills
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

git_q() { git -c init.defaultBranch=main -c user.name=Test -c user.email=test@example.com "$@"; }

# The source: commit A is v1.0.0, commit B (one skill changed) is v1.1.0.
mkdir -p "$work/src"
cp -R "$here/plugins" "$work/src/plugins"
git_q -C "$work/src" init -q
git_q -C "$work/src" add -A
git_q -C "$work/src" commit -q -m "feat: add the skills"
git_q -C "$work/src" tag -a v1.0.0 -m v1.0.0
commit_a=$(git -C "$work/src" rev-parse HEAD)

export GIT_CONFIG_GLOBAL="$work/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$work/src.insteadOf" "https://github.com/$source.git"
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

# Fake gh: "pr list --head" prints $work/pr, "--author" prints $work/dependabot.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$work/gh.log"
if [[ \$1 == pr && \$2 == list ]]; then
  if [[ " \$* " == *" --author "* ]]; then cat "$work/dependabot" 2>/dev/null || true
  else cat "$work/pr" 2>/dev/null || true; fi
elif [[ \$1 == api ]]; then
  case "\$*" in
    *installation/repositories*) printf 'test/consumer\nother/repo\n' ;;
    *repos/test/consumer/contents/skills-lock.json*) git -C "$work/origin.git" show main:skills-lock.json ;;
    *users/test-app*) echo 123 ;;
    *) exit 1 ;;
  esac
fi
EOF
real_npx=$(command -v npx)
cat >"$work/bin/npx" <<EOF
#!/usr/bin/env bash
env >"$work/npx.env"
exec "$real_npx" "\$@"
EOF
chmod +x "$work/bin/gh" "$work/bin/npx"
export PATH="$work/bin:$PATH"

# The consumer: two shared skills, one skill of another source and a
# workflow that pins the action at v1.0.0.
mkdir -p "$work/consumer" && cd "$work/consumer"
git_q init -q
printf '/.agents/skills/** -text\n' >.gitattributes
mkdir -p "$work/home/.claude"
HOME="$work/home" DISABLE_TELEMETRY=1 npx --yes skills@1.7.3 add "$source" \
  --skill grill-me writing-code-comments -a claude-code codex gemini-cli -y >/dev/null
mkdir -p .agents/skills/other-skill .github/workflows
printf -- '---\nname: other-skill\ndescription: test\n---\n' >.agents/skills/other-skill/SKILL.md
ln -s ../../.agents/skills/other-skill .claude/skills/other-skill
other_hash=$(node -e '
  const { createHash } = require("crypto"); const fs = require("fs");
  const h = createHash("sha256"); h.update("SKILL.md"); h.update(fs.readFileSync(process.argv[1])); console.log(h.digest("hex"));
' .agents/skills/other-skill/SKILL.md)
node -e '
  const fs = require("fs"); const lock = JSON.parse(fs.readFileSync("skills-lock.json"));
  lock.skills["other-skill"] = { source: "someone/else", sourceType: "github", skillPath: "skills/other-skill/SKILL.md", computedHash: process.argv[1] };
  fs.writeFileSync("skills-lock.json", JSON.stringify(lock, null, 2) + "\n");
' "$other_hash"
cat >.github/workflows/agent-skills.yml <<EOF
jobs:
  lock:
    steps:
      - uses: $source@$commit_a # v1.0.0
EOF
git_q add -A
git_q commit -q -m "chore: add the skills"
git init -q --bare "$work/origin.git"
git remote add origin "$work/origin.git"
git push -q origin main
lock_a=$(cat skills-lock.json)
node "$here/scripts/check-skills-lock.mjs" --source "$source" >/dev/null || fail "the consumer does not pass the lock check before the test"

run() { GH_TOKEN=secret-token-for-test bash "$here/scripts/update-pr.sh" --repo test/consumer --bump-pin "$@" >"$work/run.log" 2>&1 || { cat "$work/run.log" >&2; fail "update-pr.sh failed"; }; }

# 1. No change in the source and no newer release: nothing happens.
run
grep -q "No update" "$work/run.log" || fail "a run with no change did not say 'No update'"
[[ -z $(git ls-remote origin refs/heads/agent-skills/update) ]] || fail "a run with no change pushed a branch"
ok "no change: no branch and no pull request"

# 2. The source changes one skill and releases v1.1.0.
printf '\nA line from the test.\n' >>"$work/src/plugins/qoax-agent-skills/skills/grill-me/SKILL.md"
git_q -C "$work/src" commit -q -am "feat: change grill-me"
git_q -C "$work/src" tag -a v1.1.0 -m v1.1.0
commit_b=$(git -C "$work/src" rev-parse HEAD)
: >"$work/gh.log"
run
branch_sha=$(git ls-remote origin refs/heads/agent-skills/update | cut -f1)
[[ -n $branch_sha ]] || fail "the update did not push the branch"
git fetch -q origin
mapfile -t subjects < <(git log --reverse --format=%s main..origin/agent-skills/update)
[[ ${subjects[*]} == "ci: bump $source from v1.0.0 to v1.1.0 chore: update the agent skills from qoax-agent-skills" ]] ||
  fail "unexpected commits: ${subjects[*]}"
ok "update: two commits, the pin bump and then the skills"
[[ $(git diff --name-only main origin/agent-skills/update~1) == .github/workflows/agent-skills.yml ]] || fail "the ci commit changes more than the workflow"
git diff --name-only origin/agent-skills/update~1 origin/agent-skills/update | grep -qvE '^(\.agents/skills/grill-me/|skills-lock\.json$)' &&
  fail "the chore commit changes more than grill-me and the lock"
ok "each commit changes only its own files"
git show origin/agent-skills/update:.github/workflows/agent-skills.yml | grep -qF "$source@$commit_b # v1.1.0" || fail "the pin is not at v1.1.0"
ok "the pin moved to the commit of v1.1.0"
for sha in $(git rev-list main..origin/agent-skills/update); do
  git log -1 --format=%B "$sha" >"$work/msg"
  COMMIT_MSG_REPORT_ONLY=0 bash "$here/.githooks/commit-msg" "$work/msg" >"$work/hook.log" 2>&1 || { cat "$work/hook.log" >&2; fail "the commit-msg hook rejects $sha"; }
  [[ $(git log -1 --format=%ae "$sha") == "41898282+github-actions[bot]@users.noreply.github.com" ]] || fail "the bot did not author $sha"
done
title=$(sed -n 's/.* --title \(.*\) --body-file .*/\1/p' "$work/gh.log" | head -1)
printf '%s\n' "$title" >"$work/msg"
bash "$here/.githooks/commit-msg" "$work/msg" >"$work/hook.log" 2>&1 || { cat "$work/hook.log" >&2; fail "the commit-msg hook rejects the title: $title"; }
ok "the commit messages and the pull request title pass the commit-msg hook"
grep -q "^gh pr create --repo test/consumer --base main --head agent-skills/update --title chore: update the agent skills from qoax-agent-skills" "$work/gh.log" || fail "no 'gh pr create' call"
ok "the pull request is opened"
git switch -q --detach origin/agent-skills/update
node "$here/scripts/check-skills-lock.mjs" --source "$source" >/dev/null || fail "the branch fails the lock check"
node -e '
  const [a, b] = process.argv.slice(1).map((t) => JSON.parse(t).skills);
  if (JSON.stringify(a["other-skill"]) !== JSON.stringify(b["other-skill"])) process.exit(1);
  if (a["writing-code-comments"].computedHash !== b["writing-code-comments"].computedHash) process.exit(1);
  if (a["grill-me"].computedHash === b["grill-me"].computedHash) process.exit(1);
' "$lock_a" "$(cat skills-lock.json)" || fail "the lock entries did not change as expected"
[[ -L .claude/skills/grill-me && $(readlink .claude/skills/grill-me) == ../../.agents/skills/grill-me ]] || fail "the grill-me link is wrong"
git switch -q main
ok "the branch passes the lock check, and the entry of the other source did not change"
grep -q "secret-token-for-test" "$work/npx.env" && fail "the skills CLI got the token"
grep -q "^HOME=$work/consumer" "$work/npx.env" && fail "the skills CLI got the real home"
grep -q '^GIT_CONFIG_GLOBAL=' "$work/npx.env" || fail "the test lost its insteadOf rule"
ok "the skills CLI did not get the token"

# 3. A second run with the pull request open: no push, the body is refreshed.
echo 7 >"$work/pr"
: >"$work/gh.log"
run
[[ $(git ls-remote origin refs/heads/agent-skills/update | cut -f1) == "$branch_sha" ]] || fail "the second run pushed again"
grep -q "^gh pr edit 7 " "$work/gh.log" || fail "the second run did not edit the pull request"
ok "second run: no push, the pull request is edited"

# 4. A Dependabot pull request for the same pin is closed.
printf '12\n' >"$work/dependabot"
: >"$work/gh.log"
run
grep -q "^gh pr close 12 " "$work/gh.log" || { cat "$work/gh.log" "$work/run.log" >&2; fail "the Dependabot pull request was not closed"; }
: >"$work/dependabot"
ok "the Dependabot pull request for the pin is closed"

# 5. A person pushes to the branch: the bot leaves it.
git switch -q -c person origin/agent-skills/update
echo "note" >>README.md
git_q add README.md
git_q commit -q -m "docs: add a note"
git push -q origin HEAD:refs/heads/agent-skills/update
person_sha=$(git rev-parse HEAD)
git switch -q main
run
grep -q "commits from a person" "$work/run.log" || fail "the bot did not see the commit of the person"
[[ $(git ls-remote origin refs/heads/agent-skills/update | cut -f1) == "$person_sha" ]] || fail "the bot changed the branch of the person"
ok "a commit from a person stops the bot"

# 6. The pull request merges: the next run closes nothing and pushes nothing.
git push -q --force origin "$branch_sha:refs/heads/agent-skills/update"
git merge -q --ff-only "$branch_sha"
git push -q origin main
: >"$work/gh.log"
run
grep -q "No update" "$work/run.log" || fail "after the merge, the run found an update"
grep -q "^gh pr close 7 " "$work/gh.log" || fail "after the merge, the open pull request was not closed"
ok "after the merge: no update, and a stale pull request is closed"

# 7. Without the -text attribute, the update stops.
git_q switch -q -c no-attributes
git_q rm -q .gitattributes
git_q commit -q -m "chore: remove the attributes"
if sh "$here/scripts/update-skills.sh" >"$work/run.log" 2>&1; then fail "the update ran without the -text attribute"; fi
grep -q "Add the line '/.agents/skills/\*\* -text'" "$work/run.log" || fail "no message about the -text attribute"
git switch -q main
ok "without the -text attribute, the update stops"

# 8. The loop of the central workflow: discovery, clone and App author.
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$work/origin.git.insteadOf" "https://github.com/test/consumer.git"
printf '\nA second line from the test.\n' >>"$work/src/plugins/qoax-agent-skills/skills/grill-me/SKILL.md"
git_q -C "$work/src" commit -q -am "feat: change grill-me again"
git_q -C "$work/src" tag -a v1.2.0 -m v1.2.0
: >"$work/pr"
: >"$work/gh.log"
GH_TOKEN=secret-token-for-test APP_SLUG=test-app bash "$here/scripts/update-consumers.sh" --owner test >"$work/run.log" 2>&1 ||
  { cat "$work/run.log" >&2; fail "update-consumers.sh failed"; }
git fetch -q origin
[[ $(git log -1 --format=%ae origin/agent-skills/update) == "123+test-app[bot]@users.noreply.github.com" ]] || fail "the App is not the author"
git show origin/agent-skills/update:.github/workflows/agent-skills.yml | grep -qF "# v1.2.0" || fail "the pin is not at v1.2.0"
grep -q "^gh pr create --repo test/consumer " "$work/gh.log" || fail "the loop did not open the pull request"
grep -q "other/repo" "$work/gh.log" && fail "the loop read a repository of another owner"
ok "central loop: finds the consumer, the App is the author, and the pull request is opened"

echo "$pass checks passed."
