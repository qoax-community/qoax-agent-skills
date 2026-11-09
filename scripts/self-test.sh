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
