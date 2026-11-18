#!/bin/sh
# Update the skills of one source in a repository to the main branch of that
# source. This is the manual update command, with checks before and after:
#
# - Only the lock entries of the source change. The script names them, so the
#   update leaves the skills of other sources as they are.
# - The skills CLI runs with a scratch home that has only .claude. Then it
#   writes .agents/skills and the .claude/skills links, and no folders for
#   other agents. It also gets no GitHub token from the environment.
# - After the update, only these paths may change: .agents/skills/<name>,
#   .claude/skills/<name> and skills-lock.json. The lock check must pass.
#
# Usage: sh update-skills.sh [--root DIR] [--source OWNER/REPO] [--bump-pin]
# --bump-pin also moves the commit pins of the source action in
# .github/workflows to its latest release (see bump-action-pin.mjs).
# Run it in a clean clone. It does not commit.
# Exit status: 0 when done, also with no change, 1 on an error, 2 on bad usage.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=.
source=qoax-community/qoax-agent-skills
bump_pin=false
skills_cli=skills@1.7.3
while [ $# -gt 0 ]; do
  case $1 in
    --root) root=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --bump-pin) bump_pin=true; shift ;;
    *) echo "update-skills: unknown argument: $1" >&2; exit 2 ;;
  esac
done
die() {
  echo "update-skills: $*" >&2
  exit 1
}

cd "$root"
[ -f skills-lock.json ] || die "no skills-lock.json in $(pwd)"
[ -z "$(git status --porcelain --untracked-files=all)" ] ||
  die "the working tree has changes. Commit or remove them first, because the check after the update compares with HEAD."

names=$(node "$here/scripts/check-skills-lock.mjs" --root . --source "$source" --names) ||
  die "$names"
for name in $names; do
  case $name in
    *[!a-z0-9._-]*) die "unexpected skill name in skills-lock.json: $name" ;;
  esac
  # Without -text, git can change the line endings of a skill file, and the
  # hash in the lock no longer matches.
  attr=$(git check-attr text -- ".agents/skills/$name/SKILL.md")
  case $attr in
    *": text: unset") ;;
    *) die "git can change the line endings in .agents/skills. Add the line '/.agents/skills/** -text' to .gitattributes." ;;
  esac
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.claude"
cache=${npm_config_cache:-$(npm config get cache)}
echo "Updating from $source:" $names
# shellcheck disable=SC2086
env -u GITHUB_TOKEN -u GH_TOKEN -u XDG_CONFIG_HOME -u CODEX_HOME -u CLAUDE_CONFIG_DIR \
  HOME="$work/home" npm_config_cache="$cache" DISABLE_TELEMETRY=1 \
  npx --yes "$skills_cli" update -p -y $names >"$work/update.log" 2>&1 || {
  cat "$work/update.log" >&2
  die "the skills CLI failed"
}
grep -E 'Updated|up to date|Failed|✗' "$work/update.log" || true

if [ "$bump_pin" = true ]; then
  node "$here/scripts/bump-action-pin.mjs" --root . --source "$source" >"$work/pin" ||
    die "cannot move the pin of the $source action"
  cat "$work/pin"
fi

# Only the skills of the source, their links, the lock and, with --bump-pin,
# the workflow files may change.
git status --porcelain --untracked-files=all | cut -c4- >"$work/changed"
while IFS= read -r path; do
  case $path in
    skills-lock.json) continue ;;
    .github/workflows/*) grep -qxF "file=$path" "$work/pin" 2>/dev/null && continue ;;
  esac
  ok=false
  for name in $names; do
    case $path in
      .agents/skills/"$name"/* | .claude/skills/"$name") ok=true ;;
    esac
  done
  [ "$ok" = true ] || echo "$path" >>"$work/unexpected"
done <"$work/changed"
if [ -s "$work/unexpected" ]; then
  echo "update-skills: the update changed paths outside the skills of $source:" >&2
  cat "$work/unexpected" >&2
  exit 1
fi

# The lock entries of other sources must stay the same.
git show HEAD:skills-lock.json >"$work/lock-before.json"
node -e '
  const [before, after, ...names] = process.argv.slice(1);
  const read = (p) => JSON.parse(require("fs").readFileSync(p, "utf-8")).skills ?? {};
  const a = read(before), b = read(after);
  for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
    if (names.includes(key)) continue;
    if (JSON.stringify(a[key]) !== JSON.stringify(b[key])) {
      console.error(`update-skills: the lock entry ${key} changed, but it is not from the source`);
      process.exit(1);
    }
  }
' "$work/lock-before.json" skills-lock.json $names

# A folder in .agents/skills that HEAD already has is the business of the
# lock check in the CI of the repository, for example a skill of its own.
allow=
for dir in .agents/skills/*/; do
  [ -d "$dir" ] || continue
  allow="$allow --allow $(basename "$dir")"
done
# shellcheck disable=SC2086
node "$here/scripts/check-skills-lock.mjs" --root . --source "$source" $allow >"$work/check" || {
  cat "$work/check" >&2
  die "the lock check fails after the update"
}
if [ -s "$work/changed" ]; then
  echo "Changed:"
  sed 's/^/  /' "$work/changed"
else
  echo "No change. The skills from $source are current."
fi
