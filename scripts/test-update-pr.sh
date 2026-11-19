#!/usr/bin/env bash
# Test update-skills.sh, update-pr.sh, publish-pr.sh and update-consumers.sh
# without GitHub.
#
# A scratch "source" repository has the skills of this checkout and release
# tags. A git insteadOf rule sends https://github.com/<source>.git to it, so
# the skills CLI, ls-remote and the pin bump read it. A scratch consumer has a
# bare "origin" and an .npmrc that points npm at a registry that does not
# exist. A fake gh records each call and answers "pr list" from JSON files
# with jq. A wrapper around node records the environment of the skills CLI.
#
# Needs bash 4, node, git, jq and npm (the skills CLI comes from the npm
# registry).
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "test-update-pr: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
source=qoax-community/qoax-agent-skills
branch=agent-skills/update
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The scripts write workflow commands and a job summary in GitHub Actions.
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY
pass=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
git_q() { git -c init.defaultBranch=main -c user.name=Test -c user.email=test@example.com "$@"; }
person() { git -c user.name=Person -c user.email=person@example.com "$@"; }
export SKILLS_CLI_DIR="$work/cli"

# The source: v1.0.0 has the skills of this checkout.
mkdir -p "$work/src"
cp -R "$here/plugins" "$work/src/plugins"
git_q -C "$work/src" init -q
git_q -C "$work/src" add -A
git_q -C "$work/src" commit -q -m "feat: add the skills"
git_q -C "$work/src" tag -a v1.0.0 -m v1.0.0
commit_a=$(git -C "$work/src" rev-parse HEAD)
release() { # $1 = tag. Changes grill-me and tags the result.
  printf '\nA change for %s.\n' "$1" >>"$work/src/plugins/qoax-agent-skills/skills/grill-me/SKILL.md"
  git_q -C "$work/src" commit -q -am "feat: change grill-me for $1"
  git_q -C "$work/src" tag -a "$1" -m "$1"
}

export GIT_CONFIG_GLOBAL="$work/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$work/src.insteadOf" "https://github.com/$source.git"
git config --file "$GIT_CONFIG_GLOBAL" "url.file://$work/origin.git.insteadOf" "https://github.com/test/consumer.git"
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

mkdir -p "$work/bin"
echo '[]' >"$work/prs.json"
echo '[]' >"$work/dependabot.json"
cat >"$work/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$work/gh.log"
jq_expr=.
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do [[ \${args[i]} == --jq ]] && jq_expr=\${args[i+1]}; done
if [[ \$1 == pr && \$2 == list ]]; then
  file="$work/prs.json"
  [[ " \$* " == *" --author "* ]] && file="$work/dependabot.json"
  jq -r "\$jq_expr" "\$file"
elif [[ \$1 == api ]]; then
  case "\$*" in
    *installation/token*) echo revoked >>"$work/revoked" ;;
    *installation/repositories*) printf 'test/consumer\nother/repo\n' ;;
    *repos/test/consumer/contents/skills-lock.json*) git -C "$work/origin.git" show main:skills-lock.json ;;
    *users/test-app*) echo 123 ;;
    *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  esac
fi
EOF
real_node=$(command -v node)
cat >"$work/bin/node" <<EOF
#!/usr/bin/env bash
case "\$*" in *skills/bin/cli.mjs*) env >"$work/cli.env" ;; esac
exec "$real_node" "\$@"
EOF
chmod +x "$work/bin/gh" "$work/bin/node"
export PATH="$work/bin:$PATH"

# The consumer: two shared skills, one skill of another source and a workflow
# that pins the action at v1.0.0. The .npmrc comes after the add, because npx
# reads it.
mkdir -p "$work/consumer" && cd "$work/consumer"
git_q init -q
printf '/.agents/skills/** -text\n' >.gitattributes
mkdir -p "$work/home/.claude"
HOME="$work/home" DISABLE_TELEMETRY=1 npx --yes skills@1.7.3 add "$source" \
  --skill grill-me writing-code-comments -a claude-code codex gemini-cli -y >/dev/null
printf 'registry=http://127.0.0.1:9/\n' >.npmrc
mkdir -p .agents/skills/other-skill .github/workflows
printf -- '---\nname: other-skill\ndescription: test\n---\n' >.agents/skills/other-skill/SKILL.md
ln -s ../../.agents/skills/other-skill .claude/skills/other-skill
node -e '
  const { createHash } = require("crypto"); const fs = require("fs");
  const hash = createHash("sha256").update("SKILL.md").update(fs.readFileSync(".agents/skills/other-skill/SKILL.md")).digest("hex");
  const lock = JSON.parse(fs.readFileSync("skills-lock.json"));
  lock.skills["other-skill"] = { source: "someone/else", sourceType: "github", skillPath: "skills/other-skill/SKILL.md", computedHash: hash };
  fs.writeFileSync("skills-lock.json", JSON.stringify(lock, null, 2) + "\n");
'
cat >.github/workflows/agent-skills.yml <<EOF
jobs:
  lock:
    steps:
      - uses: $source@$commit_a # v1.0.0
EOF
git_q add -A
git_q commit -q -m "chore: add the skills"
git_q init -q --bare "$work/origin.git"
git remote add origin "$work/origin.git"
git push -q origin main
lock_a=$(cat skills-lock.json)
node "$here/scripts/check-skills-lock.mjs" --source "$source" >/dev/null || fail "the consumer does not pass the lock check before the test"

run() { GH_TOKEN=secret-token-for-test bash "$here/scripts/update-pr.sh" --repo test/consumer --bump-pin "$@" >"$work/run.log" 2>&1 || { cat "$work/run.log" >&2; fail "update-pr.sh failed"; }; }
remote() { git ls-remote origin "refs/heads/$branch" | cut -f1; }
open_pr() { echo '[{"number":7,"isCrossRepository":false}]' >"$work/prs.json"; }

# 1. No change and no newer release: nothing happens.
run
grep -q "No update" "$work/run.log" || fail "a run with no change did not say 'No update'"
[[ -z $(remote) ]] || fail "a run with no change pushed a branch"
ok "no change: no branch and no pull request"

# 2. The source changes one skill and releases v1.1.0.
release v1.1.0
commit_b=$(git -C "$work/src" rev-parse HEAD)
: >"$work/gh.log"
run
branch_sha=$(remote)
[[ -n $branch_sha ]] || fail "the update did not push the branch"
git fetch -q origin
mapfile -t subjects < <(git log --reverse --format=%s "main..origin/$branch")
[[ ${subjects[*]} == "ci: bump $source from v1.0.0 to v1.1.0 chore: update the agent skills from qoax-agent-skills" ]] ||
  fail "unexpected commits: ${subjects[*]}"
ok "update: two commits, the pin bump and then the skills, with a bad registry in .npmrc"
[[ $(git diff --name-only main "origin/$branch~1") == .github/workflows/agent-skills.yml ]] || fail "the ci commit changes more than the workflow"
git diff --name-only "origin/$branch~1" "origin/$branch" | grep -qvE '^(\.agents/skills/grill-me/|skills-lock\.json$)' &&
  fail "the chore commit changes more than grill-me and the lock"
git show "origin/$branch:.github/workflows/agent-skills.yml" | grep -qF "$source@$commit_b # v1.1.0" || fail "the pin is not at v1.1.0"
ok "each commit changes only its own files, and the pin moved to the commit of v1.1.0"
for sha in $(git rev-list "main..origin/$branch"); do
  git log -1 --format=%B "$sha" >"$work/msg"
  COMMIT_MSG_REPORT_ONLY=1 bash "$here/.githooks/commit-msg" "$work/msg" >"$work/hook.log" 2>&1 || { cat "$work/hook.log" >&2; fail "the commit-msg hook rejects $sha"; }
  [[ $(git log -1 --format=%ae "$sha") == "41898282+github-actions[bot]@users.noreply.github.com" ]] || fail "the bot did not author $sha"
done
sed -n 's/.* --title \(.*\) --body-file .*/\1/p' "$work/gh.log" | head -1 >"$work/msg"
bash "$here/.githooks/commit-msg" "$work/msg" >"$work/hook.log" 2>&1 || { cat "$work/hook.log" >&2; fail "the commit-msg hook rejects the title"; }
grep -q "^gh pr create --repo test/consumer --base main --head $branch --title chore: update the agent skills from qoax-agent-skills" "$work/gh.log" || fail "no 'gh pr create' call"
ok "the commit messages and the title pass the commit-msg hook, and the pull request is opened"
git switch -q --detach "origin/$branch"
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
[[ -s $work/cli.env ]] || fail "the test did not see the skills CLI run"
grep -q "secret-token-for-test" "$work/cli.env" && fail "the skills CLI got the token"
grep -qx "HOME=$HOME" "$work/cli.env" && fail "the skills CLI got the real home"
grep -q '^GIT_CONFIG_GLOBAL=' "$work/cli.env" || fail "the test lost its insteadOf rule"
grep -q "secret-token-for-test\|extraheader" .git/config && fail "the token is in .git/config"
ok "the skills CLI did not get the token, and .git/config has no token"

# 3. A second run with the pull request open: no push, the body is refreshed.
open_pr
: >"$work/gh.log"
run
[[ $(remote) == "$branch_sha" ]] || fail "the second run pushed again"
grep -q "^gh pr edit 7 " "$work/gh.log" || fail "the second run did not edit the pull request"
ok "second run: no push, the pull request is edited"

# 4. A Dependabot pull request for the same pin is closed. A group pull request is not.
echo "[{\"number\":12,\"headRefName\":\"dependabot/github_actions/$source-1.1.0\"},{\"number\":13,\"headRefName\":\"dependabot/github_actions/actions-1a2b3c\"}]" >"$work/dependabot.json"
: >"$work/gh.log"
run
grep -q "^gh pr close 12 " "$work/gh.log" || fail "the Dependabot pull request was not closed"
grep -q "^gh pr close 13 " "$work/gh.log" && fail "the bot closed a group pull request of Dependabot"
echo '[]' >"$work/dependabot.json"
ok "the Dependabot pull request for the pin is closed, a group pull request stays"

# 5. A fork has a branch with the same name: the bot ignores its pull request.
echo '[{"number":99,"isCrossRepository":true}]' >"$work/prs.json"
: >"$work/gh.log"
run
grep -qE "^gh pr (edit|close) 99 " "$work/gh.log" && fail "the bot changed the pull request of a fork"
grep -q "^gh pr create " "$work/gh.log" || fail "the bot did not open its own pull request"
open_pr
ok "a pull request from a fork with the same branch name is not the bot's"

# 6. A person amends a bot commit, so the bot stays the author: the bot leaves the branch.
git fetch -q origin
git switch -q -c amend "origin/$branch"
echo "note" >>README.md
git_q add README.md
person commit -q --amend --no-edit
git push -q --force origin "HEAD:refs/heads/$branch"
person_sha=$(git rev-parse HEAD)
git switch -q main
run
grep -q "commits from a person" "$work/run.log" || fail "the bot did not see the amend of the person"
[[ $(remote) == "$person_sha" ]] || fail "the bot pushed over the amend of the person"
[[ -z $(git status --porcelain) && $(git symbolic-ref --short HEAD) == main ]] || fail "the run left changes or another branch"
ok "a commit that a person amended stops the bot while the pull request is open"

# 7. The pull request closes without a merge: the bot takes the branch back.
echo '[]' >"$work/prs.json"
run
[[ $(remote) != "$person_sha" ]] || fail "after the close, the bot did not make the branch again"
git fetch -q origin
[[ -z $(git log --format=%ce "main..origin/$branch" | grep -v '\[bot\]') ]] || fail "the new branch still has the commit of the person"
open_pr
ok "after a close without a merge, the bot makes the branch again"

# 8. A shallow clone, after main moved: no false commit of a person.
git_q commit -q --allow-empty -m "chore: move main"
git_q commit -q --allow-empty -m "chore: move main again"
git push -q origin main
git clone -q --depth 1 "file://$work/origin.git" "$work/shallow"
cd "$work/shallow"
run
grep -q "commits from a person" "$work/run.log" && { cat "$work/run.log" >&2; fail "a shallow clone saw a false commit of a person"; }
# A clone with --depth is also --single-branch, so read the branch with ls-remote.
git merge-base --is-ancestor origin/main "$(remote)" || { cat "$work/run.log" >&2; fail "the branch is not on the new main"; }
ok "a shallow clone gets the history, and the branch moves to the new main"

# 9. A patch that also changes another file: publish refuses it.
GH_TOKEN=x bash "$here/scripts/update-pr.sh" --repo test/consumer --bump-pin --prepare "$work/prep" >"$work/run.log" 2>&1 ||
  { cat "$work/run.log" >&2; fail "update-pr.sh --prepare failed"; }
[[ -s $work/prep/patch ]] || fail "prepare made no patch"
printf 'hello\n' >EVIL.md
git_q add EVIL.md
git diff --cached --binary >>"$work/prep/patch"
git_q reset -q --hard HEAD
if GH_TOKEN=x bash "$here/scripts/update-pr.sh" --repo test/consumer --bump-pin --publish "$work/prep" >"$work/run.log" 2>&1; then
  fail "publish took a patch that adds EVIL.md"
fi
grep -q "changes EVIL.md, which it may not change" "$work/run.log" || { cat "$work/run.log" >&2; fail "no message about EVIL.md"; }
[[ -z $(git status --porcelain --untracked-files=all) ]] || fail "the refused patch left changes"
ok "publish refuses a patch that changes a path outside the skills and the pin, and cleans up"

# 10. A token kept in .git/config: publish stops.
git config http.https://github.com/.extraheader "AUTHORIZATION: basic eA=="
if GH_TOKEN=x bash "$here/scripts/update-pr.sh" --repo test/consumer --bump-pin >"$work/run.log" 2>&1; then
  fail "publish ran with a token in .git/config"
fi
grep -q "persist-credentials: false" "$work/run.log" || { cat "$work/run.log" >&2; fail "no message about persist-credentials"; }
git config --unset http.https://github.com/.extraheader
ok "a token in .git/config stops the bot"

# 11. The pull request merges: the next run closes it, if it is still open.
cd "$work/consumer"
git fetch -q origin
git merge -q --ff-only "origin/$branch"
git push -q origin main
: >"$work/gh.log"
run
grep -q "No update" "$work/run.log" || fail "after the merge, the run found an update"
grep -q "^gh pr close 7 " "$work/gh.log" || fail "after the merge, the open pull request was not closed"
ok "after the merge: no update, and the stale pull request is closed"

# 12. Without the -text attribute, the update stops.
git_q switch -q -c no-attributes
git_q rm -q .gitattributes
git_q commit -q -m "chore: remove the attributes"
if sh "$here/scripts/update-skills.sh" >"$work/run.log" 2>&1; then fail "the update ran without the -text attribute"; fi
grep -q "Add the line '/.agents/skills/\*\* -text'" "$work/run.log" || fail "no message about the -text attribute"
git switch -q main
ok "without the -text attribute, the update stops"

# 13. The central workflow: prepare revokes the token before the skills CLI, then publish.
release v1.2.0
echo '[]' >"$work/prs.json"
: >"$work/gh.log"
GH_TOKEN=secret-token-for-test bash "$here/scripts/update-consumers.sh" --owner test --prepare "$work/updates" --revoke >"$work/run.log" 2>&1 ||
  { cat "$work/run.log" >&2; fail "update-consumers.sh --prepare failed"; }
[[ -s $work/revoked ]] || fail "prepare did not revoke the token"
grep -q "secret-token-for-test" "$work/cli.env" && fail "the skills CLI got the token in prepare"
grep -q "other/repo" "$work/gh.log" && fail "prepare read a repository of another owner"
[[ -s $work/updates/test__consumer/patch && $(cat "$work/updates/consumers.txt") == test/consumer ]] || fail "prepare made no patch"
GH_TOKEN=secret-token-for-test APP_SLUG=test-app bash "$here/scripts/update-consumers.sh" --owner test --publish "$work/updates" >"$work/run.log" 2>&1 ||
  { cat "$work/run.log" >&2; fail "update-consumers.sh --publish failed"; }
git fetch -q origin
[[ $(git log -1 --format=%ae "origin/$branch") == "123+test-app[bot]@users.noreply.github.com" ]] || fail "the App is not the author"
git show "origin/$branch:.github/workflows/agent-skills.yml" | grep -qF "# v1.2.0" || fail "the pin is not at v1.2.0"
grep -q "^gh pr create --repo test/consumer " "$work/gh.log" || fail "publish did not open the pull request"
ok "central workflow: prepare revokes the token before the skills CLI, publish opens the pull request as the App"

# 14. publish refuses a folder of another owner.
mkdir -p "$work/updates/other__repo"
echo other/repo >"$work/updates/other__repo/repo"
cp "$work/updates/test__consumer/base" "$work/updates/test__consumer/patch" "$work/updates/other__repo/"
if GH_TOKEN=x bash "$here/scripts/update-consumers.sh" --owner test --publish "$work/updates" >"$work/run.log" 2>&1; then
  fail "publish took the folder of another owner"
fi
grep -q "does not belong to test" "$work/run.log" || { cat "$work/run.log" >&2; fail "no message about the other owner"; }
ok "publish refuses a folder of another owner"

echo "$pass checks passed."
