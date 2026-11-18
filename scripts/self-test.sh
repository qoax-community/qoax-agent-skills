#!/bin/sh
# Install every skill from this checkout into a scratch repository with the
# pinned skills CLI, then run the lock check on the result. This proves three
# things: the CLI finds every skill, each skill folder has a LICENSE, and
# check-skills-lock.mjs computes the same hash as the CLI. Then it checks that
# an unknown source makes check-skills-lock.mjs fail.
# Name more than one agent: with Claude Code alone, the CLI copies the skills
# into .claude/skills and writes no .agents/skills.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.claude" "$work/repo"
cd "$work/repo"
git init -q
HOME="$work/home" DISABLE_TELEMETRY=1 npx --yes skills@1.7.3 add "$here" --skill '*' -a claude-code codex gemini-cli -y >/dev/null
expected=$(find "$here/plugins" -mindepth 4 -maxdepth 4 -name SKILL.md | wc -l | tr -d ' ')
found=$(find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
if [ "$expected" != "$found" ]; then
  echo "self-test: the skills CLI installed $found skill(s), expected $expected" >&2
  exit 1
fi
for dir in .agents/skills/*/; do
  [ -f "$dir/LICENSE" ] || { echo "self-test: $dir has no LICENSE" >&2; exit 1; }
done
if find "$here/plugins" -type l | grep -q .; then
  echo "self-test: symbolic links in plugins/ change the skills CLI hash" >&2
  exit 1
fi
node "$here/scripts/check-skills-lock.mjs" --root "$work/repo"

# A source that no lock entry has must fail in both modes. Otherwise a typo in
# the source input of the action makes CI pass with nothing checked.
for mode in lock upstream; do
  set -- --root "$work/repo" --source no-such-owner/no-such-repo
  if [ "$mode" = upstream ]; then set -- "$@" --upstream "$here"; fi
  if out=$(node "$here/scripts/check-skills-lock.mjs" "$@"); then status=0; else status=$?; fi
  case $status:$out in
    1:*"no entry in skills-lock.json has this source"*) ;;
    *)
      echo "self-test: the $mode check gave exit $status for an unknown source, expected exit 1 and a message:" >&2
      echo "$out" >&2
      exit 1
      ;;
  esac
done
echo "ok   an unknown source fails the lock and the upstream check"

# Lock entries of other sources: off by default, a warning with "report", a
# failure with "fail". The upstream check reads one checkout for each source.
other="$work/other"
mkdir -p "$other/repo/.agents/skills/mine" "$other/repo/.claude/skills/theirs" "$other/up-mine/skills/mine" "$other/up-theirs/skills/theirs"
cd "$other/repo"
printf 'mine\n' >.agents/skills/mine/SKILL.md
printf 'theirs\n' >.claude/skills/theirs/SKILL.md
ln -s ../../.agents/skills/mine .claude/skills/mine
cp .agents/skills/mine/SKILL.md "$other/up-mine/skills/mine/SKILL.md"
printf 'theirs, newer\n' >"$other/up-theirs/skills/theirs/SKILL.md"
node -e '
  const { createHash } = require("crypto"); const fs = require("fs");
  const hash = (file) => createHash("sha256").update("SKILL.md").update(fs.readFileSync(file)).digest("hex");
  fs.writeFileSync("skills-lock.json", JSON.stringify({ version: 1, skills: {
    mine: { source: "me/skills", sourceType: "github", skillPath: "skills/mine/SKILL.md", computedHash: hash(".agents/skills/mine/SKILL.md") },
    theirs: { source: "them/skills", sourceType: "github", skillPath: "skills/theirs/SKILL.md", computedHash: hash(".claude/skills/theirs/SKILL.md") },
  } }));
'
check() {
  expected=$1
  shift
  if out=$(node "$here/scripts/check-skills-lock.mjs" --root "$other/repo" --source me/skills "$@"); then status=0; else status=$?; fi
  [ "$status" = "$expected" ] || { echo "self-test: exit $status, expected $expected, for: $*" >&2; echo "$out" >&2; exit 1; }
  printf '%s\n' "$out"
}
check 0 | grep -q "theirs" && { echo "self-test: the default check read the other source" >&2; exit 1; }
check 0 --other-sources report | grep -q "^ok   theirs" || { echo "self-test: the copy of the other source is not ok" >&2; exit 1; }
printf 'theirs, edited\n' >.claude/skills/theirs/SKILL.md
check 0 --other-sources report | grep -q "^warn theirs: hash" || { echo "self-test: no warning for an edited copy" >&2; exit 1; }
check 1 --other-sources fail >/dev/null
up="--upstream $other/up-mine"
# shellcheck disable=SC2086
check 0 $up --other-sources report --upstream-other "them/skills=$other/up-theirs" | grep -q "^warn theirs: theirs is out of date" ||
  { echo "self-test: no warning for an upstream change of the other source" >&2; exit 1; }
# shellcheck disable=SC2086
check 1 $up --other-sources fail --upstream-other "them/skills=$other/up-theirs" >/dev/null
# shellcheck disable=SC2086
check 0 $up --other-sources report | grep -q "^warn theirs: there is no checkout" ||
  { echo "self-test: no warning for a missing checkout" >&2; exit 1; }
echo "ok   lock entries of other sources: off, report and fail"
