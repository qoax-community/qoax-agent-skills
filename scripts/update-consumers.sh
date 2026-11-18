#!/usr/bin/env bash
# Run update-pr.sh in each consumer repository of one owner. A consumer is a
# repository where the GitHub App of the skills bot is installed and whose
# skills-lock.json has a skill from the source. One failing repository does
# not stop the others.
#
# Usage: bash update-consumers.sh --owner OWNER [--source OWNER/REPO]
#          [--only OWNER/NAME]... [--dry-run]
# --only names the repositories, and the script does not ask GitHub for the
# repositories of the App. Use it for a dry run with a token of a person.
# Environment:
#   GH_TOKEN   Installation token of the App for OWNER, with contents,
#              pull-requests and workflows write.
#   APP_SLUG   Slug of the App. The commits then have the App as author.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "update-consumers: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
owner=
source=qoax-community/qoax-agent-skills
only=()
pr_args=()
while (($#)); do
  case $1 in
    --owner) owner=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --only) only+=("$2"); shift 2 ;;
    --dry-run) pr_args+=(--dry-run); shift ;;
    *) echo "update-consumers: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $owner ]] || { echo "update-consumers: give --owner OWNER" >&2; exit 2; }
: "${GH_TOKEN:?update-consumers: set GH_TOKEN}"

if [[ -n ${APP_SLUG:-} ]]; then
  BOT_NAME="$APP_SLUG[bot]"
  BOT_EMAIL="$(gh api "users/$APP_SLUG%5Bbot%5D" --jq .id)+$APP_SLUG[bot]@users.noreply.github.com"
  export BOT_NAME BOT_EMAIL
fi
header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
[[ ${GITHUB_ACTIONS:-} == true ]] && echo "::add-mask::${header#AUTHORIZATION: basic }"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
echo "| Repository | Result |" >>"$summary"
echo "| --- | --- |" >>"$summary"
failed=()

if ((${#only[@]})); then
  repos=("${only[@]}")
else
  mapfile -t repos < <(gh api --paginate /installation/repositories \
    --jq '.repositories[] | select(.archived | not) | .full_name' | sort)
fi
for repo in "${repos[@]}"; do
  [[ ${repo%%/*} == "$owner" && $repo != "$source" ]] || continue
  if ! gh api "repos/$repo/contents/skills-lock.json" -H "Accept: application/vnd.github.raw" >"$work/lock.json" 2>/dev/null; then
    continue
  fi
  if ! node -e '
    const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf-8"));
    process.exit(Object.values(lock.skills ?? {}).some((e) => e.source === process.argv[2]) ? 0 : 1);
  ' "$work/lock.json" "$source" 2>/dev/null; then
    continue
  fi
  echo "::group::$repo"
  dir="$work/${repo//\//_}"
  if git -c "http.https://github.com/.extraheader=$header" clone -q --filter=blob:none \
    "https://github.com/$repo.git" "$dir" &&
    (cd "$dir" && bash "$here/scripts/update-pr.sh" --repo "$repo" --source "$source" --bump-pin "${pr_args[@]}"); then
    echo "| \`$repo\` | done |" >>"$summary"
  else
    echo "::error title=$repo::The skills update failed. Open the log group of $repo."
    echo "| \`$repo\` | failed |" >>"$summary"
    failed+=("$repo")
  fi
  rm -rf "$dir"
  echo "::endgroup::"
done

if ((${#failed[@]})); then
  echo "update-consumers: failed in ${failed[*]}" >&2
  exit 1
fi
