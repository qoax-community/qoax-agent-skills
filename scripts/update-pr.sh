#!/usr/bin/env bash
# Update the skills of one repository and open or refresh one pull request,
# as Dependabot does for a dependency. Run it in a clone of the repository, on
# its default branch.
#
# The work has two halves:
# - prepare: update-skills.sh updates the skills from the main branch of the
#   source. With --bump-pin, it also moves the pin of the source action to
#   its latest release, so the pull request has the Dependabot bump too. The
#   result is a patch with the commit messages and the pull request text. This
#   half runs the skills CLI and needs no token.
# - publish: publish-pr.sh applies the patch to the default branch, checks
#   each path, makes one "ci:" commit for the pin and one "chore:" commit for
#   the skills, and pushes the branch and opens the pull request.
#
# Usage: bash update-pr.sh --repo OWNER/NAME [--source OWNER/REPO] [--bump-pin]
#          [--branch NAME] [--dry-run] [--prepare DIR | --publish DIR]
# With no --prepare or --publish, the script does both in one run. Then the
# token is in the same job as the skills CLI, so use it only with a token
# that can write to this one repository. The central workflow runs the two
# halves in two jobs.
# Environment: see publish-pr.sh. --prepare needs no GH_TOKEN.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "update-pr: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
repo=
source=qoax-community/qoax-agent-skills
branch=agent-skills/update
bump_pin=false
dry_run=false
mode=both
dir=
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --bump-pin) bump_pin=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --prepare) mode=prepare; dir=$2; shift 2 ;;
    --publish) mode=publish; dir=$2; shift 2 ;;
    *) echo "update-pr: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "update-pr: give --repo OWNER/NAME" >&2; exit 2; }

prepare() {
  local out=$1
  mkdir -p "$out"
  local base_sha lock_before
  git symbolic-ref -q HEAD >/dev/null || { echo "update-pr: check out the default branch first" >&2; exit 1; }
  base_sha=$(git rev-parse HEAD)
  lock_before=$(git show HEAD:skills-lock.json)
  echo "$base_sha" >"$out/base"
  echo "$repo" >"$out/repo"
  : >"$out/patch"

  local args=(--source "$source")
  [[ $bump_pin == true ]] && args+=(--bump-pin)
  sh "$here/scripts/update-skills.sh" "${args[@]}" | tee "$out/update.log"
  local pin_from pin_to
  pin_from=$(sed -n 's/^from=//p' "$out/update.log")
  pin_to=$(sed -n 's/^to=//p' "$out/update.log")
  [[ -n $(git status --porcelain --untracked-files=all) ]] || return 0

  git add -A
  git diff --cached --binary >"$out/patch"
  local table
  table=$(node -e '
    const [before, after] = process.argv.slice(1).map((p) => JSON.parse(p).skills ?? {});
    for (const name of Object.keys({ ...before, ...after }).sort()) {
      const a = before[name]?.computedHash?.slice(0, 12) ?? "none";
      const b = after[name]?.computedHash?.slice(0, 12) ?? "none";
      if (a !== b) console.log(`${name} ${a} ${b}`);
    }
  ' "$lock_before" "$(git show :skills-lock.json)")
  # update-skills.sh started from a clean tree, so this removes only its changes.
  git reset -q --hard HEAD
  git clean -fdq -- .agents/skills .claude/skills

  # The commit-msg hook allows body lines of 100 characters at most.
  wrap() { fold -s -w 72 <<<"$1" | sed 's/ *$//'; }
  local name
  name=$(basename "$source")
  if [[ -n $pin_to ]]; then
    printf '%s\n\n%s\n' "ci: bump $source from $pin_from to $pin_to" \
      "$(wrap "Move the pin of the $source action in .github/workflows to the commit of $pin_to.")" >"$out/message-pin"
  fi
  if [[ -n $table ]]; then
    printf '%s\n\n%s\n\n%s\n' "chore: update the agent skills from $name" \
      "$(wrap "Update these skills to the main branch of $source. The values are the first 12 characters of computedHash in skills-lock.json.")" \
      "$(awk '{ printf "- %s: %s to %s\n", $1, $2, $3 }' <<<"$table")" >"$out/message"
    echo "chore: update the agent skills from $name" >"$out/title"
  elif [[ -n $pin_to ]]; then
    cp "$out/message-pin" "$out/message"
    echo "ci: bump $source from $pin_from to $pin_to" >"$out/title"
  else
    printf '%s\n\n%s\n' "chore: repair the agent skills from $name" \
      "$(wrap "Make the files and links of the skills from $source match skills-lock.json again.")" >"$out/message"
    echo "chore: repair the agent skills from $name" >"$out/title"
  fi

  local source_commit
  source_commit=$(git ls-remote "https://github.com/$source.git" HEAD | cut -c1-12)
  {
    echo "### Description"
    if [[ -n $table ]]; then
      echo "Update the agent skills from \`$source\` to its main branch (\`$source_commit\`)."
      echo
      echo "| Skill | Hash before | Hash after |"
      echo "| --- | --- | --- |"
      awk '{ printf "| `%s` | `%s` | `%s` |\n", $1, $2, $3 }' <<<"$table"
      echo
      echo "A hash is the first 12 characters of \`computedHash\` in \`skills-lock.json\`."
    fi
    if [[ -n $pin_to ]]; then
      [[ -z $table ]] || echo
      echo "Move the pin of the \`$source\` action from $pin_from to [$pin_to](https://github.com/$source/releases/tag/$pin_to). This is the Dependabot bump of the action. The bot closes the Dependabot pull request for this pin."
    fi
    echo
    echo "The bot makes this branch again from the default branch at each run. If you push a commit to the branch, the bot does not change the branch while this pull request is open."
    echo
    echo "### Referenced Issue"
    echo "None."
    echo
    echo "### Type of Change"
    echo "- [ ] Bug fix"
    echo "- [ ] New feature / Infrastructure addition"
    echo "- [ ] Documentation update"
    echo
    echo "None of these: this is a dependency update."
    echo
    echo "### Breaking Changes"
    echo "- [x] **No**, this change is fully backwards-compatible and safe to deploy independently."
    echo "- [ ] **Yes**, this change requires downstream updates, manual intervention, or downtime (explain below)."
    echo
    echo "### Validation"
    echo "The bot ran \`scripts/update-skills.sh\` from \`$source\`. Then \`scripts/publish-pr.sh\` applied the result to the default branch, checked that it changes only the skills of \`$source\`, their links, \`skills-lock.json\` and the action pin, and ran the lock check. The checks of this repository run on this pull request."
    echo
    echo "### Additional Context / Visuals"
    echo "Made by \`scripts/update-pr.sh\` in [$source](https://github.com/$source)."
  } >"$out/body.md"
}

publish() {
  local args=(--repo "$repo" --in "$1" --branch "$branch" --skills-of "$source")
  [[ $bump_pin == true ]] && args+=(--pin-of "$source")
  [[ $dry_run == true ]] && args+=(--dry-run)
  bash "$here/scripts/publish-pr.sh" "${args[@]}"
}

case $mode in
  prepare) prepare "$dir" ;;
  publish) publish "$dir" ;;
  both)
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    (unset GH_TOKEN GITHUB_TOKEN; prepare "$work")
    publish "$work"
    ;;
esac
