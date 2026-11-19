#!/usr/bin/env bash
# Put a prepared change on a bot branch and open or refresh one pull request,
# as Dependabot does. This is the half of the bot that holds a token that can
# write. The other half (update-pr.sh --prepare, bump-mwg.mjs) runs the
# skills CLI and npm, and gives this script a patch. The patch is data: this
# script applies it to a fresh checkout and checks each path again.
#
# Usage: bash publish-pr.sh --repo OWNER/NAME --in DIR --branch NAME
#          [--skills-of OWNER/REPO] [--pin-of OWNER/REPO] [--allow PATH]...
#          [--dry-run]
# Run it in a clean clone of the repository, on its default branch.
# DIR has these files:
#   base         the commit that the patch is against
#   patch        git diff --binary output. Empty when nothing changed.
#   title        the pull request title
#   body.md      the pull request body
#   message      the commit message for the change
#   message-pin  the commit message for the pin change (optional). The
#                change in .github/workflows then gets its own first commit.
# The patch may change only:
#   --skills-of  .agents/skills/<name>/, .claude/skills/<name> and
#                skills-lock.json, for the lock entries of that source. Then
#                the lock check must pass after the change.
#   --pin-of     lines `uses: OWNER/REPO@<commit> # vX.Y.Z` in
#                .github/workflows/*.yml and *.yaml.
#   --allow      a path, or a folder when it ends in "/".
#
# The branch belongs to the bot. While the pull request is open and the
# branch has a commit that a person made or changed, the script does not push
# to it. With --pin-of, it closes an open Dependabot pull request that moves
# the same pin.
#
# Environment:
#   GH_TOKEN              Token for git and the gh CLI: contents and
#                         pull-requests write, and workflows write for a pin.
#   BOT_NAME, BOT_EMAIL   Commit author (default: github-actions[bot]).
#   CHECKS_NEED_APPROVAL  "true" when GH_TOKEN is the GITHUB_TOKEN of the
#                         repository. The body then asks a person to approve
#                         the workflow runs.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "publish-pr: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
repo= in= branch= skills_of= pin_of=
allow=()
dry_run=false
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --in) in=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --skills-of) skills_of=$2; shift 2 ;;
    --pin-of) pin_of=$2; shift 2 ;;
    --allow) allow+=("$2"); shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "publish-pr: unknown argument: $1" >&2; exit 2 ;;
  esac
done
die() { echo "publish-pr: $*" >&2; exit 1; }
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "give --repo OWNER/NAME"
[[ -n $branch && -f $in/base && -f $in/patch ]] || die "give --branch and --in DIR with base and patch"
: "${GH_TOKEN:?publish-pr: set GH_TOKEN}"
bot_name=${BOT_NAME:-github-actions[bot]}
bot_email=${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
notice() { if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::notice title=$repo::$*"; else echo "$*"; fi; }

# The token goes to git only through the environment of each git command:
# not into .git/config and not into argv. Hooks and fsmonitor stay off there.
b64=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
[[ ${GITHUB_ACTIONS:-} == true ]] && echo "::add-mask::$b64"
git_auth() {
  GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64" \
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null \
    GIT_CONFIG_KEY_2=core.fsmonitor GIT_CONFIG_VALUE_2=false \
    git "$@"
}
gh_change() {
  if [[ $dry_run == true ]]; then echo "dry run: gh $*"; else gh "$@"; fi
}
if [[ -n $(git config --get-all http.https://github.com/.extraheader || true) ]]; then
  die "the clone keeps a token in .git/config. Check out with persist-credentials: false."
fi

base=$(git symbolic-ref --short HEAD) || die "check out the default branch first"
[[ $base != "$branch" ]] || die "check out the default branch, not $branch"
[[ -z $(git status --porcelain --untracked-files=all) ]] || die "the working tree has changes"
base_sha=$(git rev-parse HEAD)
if [[ $(cat "$in/base") != "$base_sha" ]]; then
  notice "$base moved after the update was prepared. The next run makes it again."
  exit 0
fi
# The check for commits of a person needs the history of the default branch.
if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
  git_auth fetch -q --unshallow --filter=blob:none origin
fi

# Only a pull request from this repository. A fork can have a branch with the
# same name.
pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)][0].number // empty')
remote_sha=$(git_auth ls-remote origin "refs/heads/$branch" | cut -f1)
person_commits=
if [[ -n $remote_sha ]]; then
  git_auth fetch -q --filter=blob:none origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  # Author and committer: a person who amends a bot commit is its committer.
  log=$(git log --format='%ae%n%ce' "$base_sha..origin/$branch")
  person_commits=$(grep -v '\[bot\]@users\.noreply\.github\.com$' <<<"$log" || true)
fi

if [[ ! -s $in/patch ]]; then
  if [[ -n $pr && -z $person_commits ]]; then
    gh_change pr close "$pr" --repo "$repo" --delete-branch \
      --comment "$base already has the change of this pull request. The bot closed it."
  fi
  notice "No update for $repo."
  exit 0
fi
if [[ -n $pr && -n $person_commits ]]; then
  notice "$branch has commits from a person, so the bot did not change it. Merge or close pull request #$pr first."
  exit 0
fi

# The names of the skills of the source come from the default branch, not
# from the patch.
names=
if [[ -n $skills_of ]]; then
  names=$(node "$here/scripts/check-skills-lock.mjs" --root . --source "$skills_of" --names) || die "$names"
fi
lock_before=$(git show HEAD:skills-lock.json 2>/dev/null || echo '{}')

# At the end, also after an error: back to the default branch with a clean
# tree, so a next run starts there. The tree was clean at the start.
cleanup() {
  if [[ $(git symbolic-ref --short HEAD 2>/dev/null) == "$branch" ]]; then git switch -q -f "$base"; fi
  git reset -q --hard "$base_sha"
  git clean -fdq
}
trap cleanup EXIT
git apply --binary --index --whitespace=nowarn "$in/patch" || die "the patch does not apply to $base_sha"
mapfile -t paths < <(git diff --cached --name-only)
pin_files=()
for path in "${paths[@]}"; do
  ok=false
  if [[ -n $skills_of ]]; then
    [[ $path == skills-lock.json ]] && ok=true
    for name in $names; do
      [[ $path == .agents/skills/"$name"/* || $path == .claude/skills/"$name" ]] && ok=true
    done
  fi
  if [[ -n $pin_of && $path =~ ^\.github/workflows/[^/]+\.ya?ml$ ]]; then
    # Each changed line must be a pin of the action.
    pin_re="^[-+][[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?${pin_of//./\\.}@[0-9a-f]{40}[\"']?([[:space:]]+#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+)?[[:space:]]*$"
    if ! git diff --cached -U0 -- "$path" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -qvE "$pin_re"; then
      ok=true
      pin_files+=("$path")
    fi
  fi
  for prefix in "${allow[@]}"; do
    if [[ $prefix == */ ]]; then [[ $path == "$prefix"* ]] && ok=true; else [[ $path == "$prefix" ]] && ok=true; fi
  done
  [[ $ok == true ]] || die "the patch changes $path, which it may not change"
done

if [[ -n $skills_of ]]; then
  # The lock entries of other sources stay the same.
  node -e '
    const [before, after, ...names] = process.argv.slice(1);
    const a = JSON.parse(before).skills ?? {}, b = JSON.parse(after).skills ?? {};
    for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (!names.includes(key) && JSON.stringify(a[key]) !== JSON.stringify(b[key])) {
        console.error(`publish-pr: the patch changes the lock entry ${key}, which is not from the source`);
        process.exit(1);
      }
    }
  ' "$lock_before" "$(git show :skills-lock.json)" $names
  allow_dirs=()
  for dir in .agents/skills/*/; do [[ -d $dir ]] && allow_dirs+=(--allow "$(basename "$dir")"); done
  node "$here/scripts/check-skills-lock.mjs" --root . --source "$skills_of" "${allow_dirs[@]}" >/dev/null ||
    die "the lock check fails after the patch"
fi

git switch -q -C "$branch"
commit() { git -c core.hooksPath=/dev/null -c user.name="$bot_name" -c user.email="$bot_email" commit -q "$@"; }
if ((${#pin_files[@]})) && [[ -f $in/message-pin ]]; then
  commit -F "$in/message-pin" -- "${pin_files[@]}"
fi
if [[ -n $(git status --porcelain --untracked-files=all) ]]; then commit -F "$in/message"; fi
[[ -z $(git status --porcelain --untracked-files=all) ]] || die "files are left after the commits"

body=$(mktemp)
trap 'rm -f "$body"; cleanup' EXIT
cp "$in/body.md" "$body"
if [[ ${CHECKS_NEED_APPROVAL:-false} == true ]]; then
  printf '\nGITHUB_TOKEN opened this pull request, so its workflow runs wait for approval. Select **Approve workflows to run** in the merge box.\n' >>"$body"
fi
title=$(head -1 "$in/title")
if [[ $dry_run == true ]]; then
  echo "dry run: title: $title"
  sed 's/^/dry run: body: /' "$body"
fi

push=true
if [[ -n $remote_sha ]] && [[ $(git rev-parse "origin/$branch^{tree}") == $(git rev-parse "HEAD^{tree}") ]] &&
  git merge-base --is-ancestor "$base_sha" "origin/$branch"; then
  notice "$branch already has this change."
  push=false
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
    die "cannot open the pull request. With GITHUB_TOKEN, turn on 'Allow GitHub Actions to create and approve pull requests' in Settings > Actions > General of $repo."
  fi
  pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository | not)][0].number // empty' || true)
fi

if [[ -n $pin_of ]] && ((${#pin_files[@]})); then
  dependabot=$(gh pr list --repo "$repo" --state open --author app/dependabot --json number,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"dependabot/github_actions/$pin_of-\")) | .number")
  for number in $dependabot; do
    gh_change pr close "$number" --repo "$repo" \
      --comment "Pull request #${pr:-?} moves this pin together with the skills, so the bot closed this one."
  done
fi
