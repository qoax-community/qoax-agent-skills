#!/usr/bin/env bash
# Update the skills of one repository and open or refresh one pull request,
# as Dependabot does for a dependency. Run it in a clone of the repository, on
# its default branch.
#
# 1. update-skills.sh updates the skills from the main branch of the source.
#    With --bump-pin, it also moves the pin of the source action to its latest
#    release, so the same pull request has the Dependabot bump.
# 2. The script makes the branch again from the default branch: one "ci:"
#    commit for the pin and one "chore:" commit for the skills.
# 3. It pushes the branch and opens or edits the pull request. When nothing
#    changed and the bot pull request is still open, it closes it.
#
# The branch belongs to the bot. When it has a commit from a person, the
# script does not push to it. It also closes an open Dependabot pull
# request that moves the same pin, because this pull request has that change.
#
# Usage: bash update-pr.sh --repo OWNER/NAME [--source OWNER/REPO] [--bump-pin]
#          [--branch NAME] [--dry-run]
# Environment:
#   GH_TOKEN              Token for git push and the gh CLI. It needs contents
#                         and pull-requests write, and workflows write for
#                         --bump-pin. The skills CLI never gets it.
#   BOT_NAME, BOT_EMAIL   Commit author (default: github-actions[bot]).
#   CHECKS_NEED_APPROVAL  "true" when GH_TOKEN is the GITHUB_TOKEN of the
#                         repository. Then the pull request body tells a person
#                         to approve the workflow runs.
# --dry-run makes the commits but does not push, and runs no gh command that
# changes something.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "update-pr: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
repo=
source=qoax-community/qoax-agent-skills
branch=agent-skills/update
bump_pin=false
dry_run=false
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --bump-pin) bump_pin=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "update-pr: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "update-pr: give --repo OWNER/NAME" >&2; exit 2; }
: "${GH_TOKEN:?update-pr: set GH_TOKEN}"
bot_name=${BOT_NAME:-github-actions[bot]}
bot_email=${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
notice() { if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::notice title=$repo::$*"; else echo "$*"; fi; }

# The token goes only to the git commands that need it. It is not in
# .git/config, so the skills CLI cannot read it there.
header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
[[ ${GITHUB_ACTIONS:-} == true ]] && echo "::add-mask::${header#AUTHORIZATION: basic }"
git_auth() { git -c "http.https://github.com/.extraheader=$header" "$@"; }
gh_change() {
  if [[ $dry_run == true ]]; then echo "dry run: gh $*"; else gh "$@"; fi
}

base=$(git symbolic-ref --short HEAD) || { echo "update-pr: check out the default branch first" >&2; exit 1; }
[[ $base != "$branch" ]] || { echo "update-pr: check out the default branch, not $branch" >&2; exit 1; }
base_sha=$(git rev-parse HEAD)
lock_before=$(git show HEAD:skills-lock.json)

update_args=(--source "$source")
[[ $bump_pin == true ]] && update_args+=(--bump-pin)
pin_log=$(mktemp)
body=$(mktemp)
# Go back to the default branch, so that the next run starts from it. The
# local branch stays for a look after a dry run.
cleanup() {
  rm -f "$pin_log" "$body"
  if [[ $(git symbolic-ref --short HEAD 2>/dev/null) == "$branch" ]]; then git switch -q "$base"; fi
}
trap cleanup EXIT
sh "$here/scripts/update-skills.sh" "${update_args[@]}" | tee "$pin_log"
pin_from=$(sed -n 's/^from=//p' "$pin_log")
pin_to=$(sed -n 's/^to=//p' "$pin_log")
mapfile -t pin_files < <(sed -n 's/^file=//p' "$pin_log")

remote_sha=$(git_auth ls-remote origin "refs/heads/$branch" | cut -f1)
pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty')

# A commit on the bot branch from a person. Any GitHub bot counts as the bot,
# so a change from github-actions[bot] to an App keeps the old branch.
foreign_commits() {
  git_auth fetch -q --filter=blob:none origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git log --format='%ae' "$base_sha..origin/$branch" | grep -v '\[bot\]@users\.noreply\.github\.com$' || true
}

if [[ -z $(git status --porcelain --untracked-files=all) ]]; then
  if [[ -n $pr && -n $remote_sha && -z $(foreign_commits) ]]; then
    gh_change pr close "$pr" --repo "$repo" --delete-branch \
      --comment "$base already has the skills and the action pin of this pull request. The bot closed it."
  fi
  notice "No update. The skills from $source are current."
  exit 0
fi

if [[ -n $remote_sha && -n $(foreign_commits) ]]; then
  # update-skills.sh started from a clean tree, so this removes only its changes.
  git checkout -q -- .
  git clean -fdq -- .agents/skills .claude/skills
  notice "$branch has commits from a person, so the bot did not change it. Merge or close pull request #${pr:-?} first."
  exit 0
fi

git switch -q -C "$branch"
commit() { git -c user.name="$bot_name" -c user.email="$bot_email" commit -q "$@"; }
# The commit-msg hook allows body lines of 100 characters at most.
wrap() { fold -s -w 72 <<<"$1" | sed 's/ *$//'; }
if ((${#pin_files[@]})); then
  git add -- "${pin_files[@]}"
  commit -m "ci: bump $source from $pin_from to $pin_to" \
    -m "$(wrap "Move the pin of the $source action in .github/workflows to the commit of $pin_to.")"
fi

# Hash changes for the commit body and the pull request.
table=$(node -e '
  const [before, after] = process.argv.slice(1).map((p) => JSON.parse(p).skills ?? {});
  for (const name of Object.keys({ ...before, ...after }).sort()) {
    const a = before[name]?.computedHash?.slice(0, 12) ?? "none";
    const b = after[name]?.computedHash?.slice(0, 12) ?? "none";
    if (a !== b) console.log(`${name} ${a} ${b}`);
  }
' "$lock_before" "$(cat skills-lock.json)")
if [[ -n $(git status --porcelain --untracked-files=all) ]]; then
  git add -A -- .agents/skills .claude/skills skills-lock.json
  lines=$(awk '{ printf "- %s: %s to %s\n", $1, $2, $3 }' <<<"$table")
  commit -m "chore: update the agent skills from $(basename "$source")" \
    -m "$(wrap "Update these skills to the main branch of $source. The values are the first 12 characters of computedHash in skills-lock.json.")" \
    -m "$lines"
fi
[[ -z $(git status --porcelain --untracked-files=all) ]] || { echo "update-pr: files are left after the commits" >&2; git status --short >&2; exit 1; }

if [[ -n $table ]]; then
  title="chore: update the agent skills from $(basename "$source")"
else
  title="ci: bump $source from $pin_from to $pin_to"
fi

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
  if ((${#pin_files[@]})); then
    [[ -z $table ]] || echo
    echo "Move the pin of the \`$source\` action from $pin_from to [$pin_to](https://github.com/$source/releases/tag/$pin_to). This is the Dependabot bump of the action. The bot closes the Dependabot pull request for this pin."
  fi
  echo
  echo "The bot makes this branch again from \`$base\` at each run. If you push a commit to the branch, the bot does not change the branch again until this pull request merges or closes."
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
  echo "The bot ran \`scripts/update-skills.sh\` from \`$source\`. After the update, only the skills of \`$source\`, their links, \`skills-lock.json\` and the action pin changed, and the lock check passed. The checks of this repository run on this pull request."
  if [[ ${CHECKS_NEED_APPROVAL:-false} == true ]]; then
    echo
    echo "GITHUB_TOKEN opened this pull request, so its workflow runs wait for approval. Select **Approve workflows to run** in the merge box."
  fi
  echo
  echo "### Additional Context / Visuals"
  echo "Made by \`scripts/update-pr.sh\` in [$source](https://github.com/$source)."
} >"$body"

if [[ $dry_run == true ]]; then
  echo "dry run: title: $title"
  sed 's/^/dry run: body: /' "$body"
fi

if [[ -n $remote_sha ]]; then
  git_auth fetch -q --filter=blob:none origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  if [[ $(git rev-parse "origin/$branch^{tree}") == $(git rev-parse "HEAD^{tree}") ]] &&
    git merge-base --is-ancestor "$base_sha" "origin/$branch"; then
    notice "$branch already has this update."
    push=false
  else
    push=true
  fi
else
  push=true
fi
if [[ $push == true ]]; then
  if [[ $dry_run == true ]]; then
    echo "dry run: git push --force-with-lease=refs/heads/$branch:$remote_sha origin HEAD:refs/heads/$branch"
  else
    git_auth push -q --force-with-lease="refs/heads/$branch:$remote_sha" origin "HEAD:refs/heads/$branch"
  fi
fi

if [[ -n $pr ]]; then
  gh_change pr edit "$pr" --repo "$repo" --title "$title" --body-file "$body"
else
  if ! gh_change pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body"; then
    echo "update-pr: cannot open the pull request. With GITHUB_TOKEN, turn on 'Allow GitHub Actions to create and approve pull requests' in Settings > Actions > General of $repo." >&2
    exit 1
  fi
  pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty' || true)
fi

if ((${#pin_files[@]})); then
  gh pr list --repo "$repo" --state open --author app/dependabot --json number,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"dependabot/github_actions/$source-\")) | .number" |
    while read -r number; do
      gh_change pr close "$number" --repo "$repo" \
        --comment "Pull request #${pr:-?} moves this pin together with the skills, so the bot closed this one."
    done
fi
