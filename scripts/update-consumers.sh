#!/usr/bin/env bash
# Run update-pr.sh in each consumer repository of one owner. A consumer is a
# repository where the GitHub App of the skills bot is installed and whose
# skills-lock.json has a skill from the source. One failing repository does
# not stop the others.
#
# Usage: bash update-consumers.sh --owner OWNER (--prepare DIR | --publish DIR | --both)
#          [--source OWNER/REPO] [--only OWNER/NAME]... [--revoke] [--dry-run]
# --prepare clones each consumer and writes one folder in DIR for each, with
#   the patch and the texts. It runs the skills CLI. With --revoke, it
#   revokes GH_TOKEN after the clones, before the skills CLI runs, so give it
#   a token that can only read.
# --publish reads DIR, clones each consumer again and runs publish-pr.sh. It
#   never runs the skills CLI.
# --both does the two in one run, for a dry run on a computer.
# --only names the repositories, and the script does not ask GitHub for the
#   repositories of the App. Use it with a token of a person.
# Environment:
#   GH_TOKEN   Installation token of the App for OWNER.
#   APP_SLUG   Slug of the App. The commits then have the App as author.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || { echo "update-consumers: needs bash 4 or later" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
owner= mode= dir=
source=qoax-community/qoax-agent-skills
only=()
revoke=false
pr_args=()
while (($#)); do
  case $1 in
    --owner) owner=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --only) only+=("$2"); shift 2 ;;
    --prepare) mode=prepare; dir=$2; shift 2 ;;
    --publish) mode=publish; dir=$2; shift 2 ;;
    --both) mode=both; shift ;;
    --revoke) revoke=true; shift ;;
    --dry-run) pr_args+=(--dry-run); shift ;;
    *) echo "update-consumers: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $owner && -n $mode ]] || { echo "update-consumers: give --owner and a mode" >&2; exit 2; }
: "${GH_TOKEN:?update-consumers: set GH_TOKEN}"
[[ $mode == both ]] && dir=$(mktemp -d)
mkdir -p "$dir"

b64=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
[[ ${GITHUB_ACTIONS:-} == true ]] && echo "::add-mask::$b64"
clone() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64" \
    git clone -q --filter=blob:none "https://github.com/$1.git" "$2"
}
work=$(mktemp -d)
trap 'rm -rf "$work"; [[ $mode == both ]] && rm -rf "$dir"' EXIT
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
failed=()

consumers() {
  local listing repo out
  if ((${#only[@]})); then
    listing=$(printf '%s\n' "${only[@]}")
  else
    # A failure here must fail the run, not give an empty list.
    listing=$(gh api --paginate /installation/repositories --jq '.repositories[] | select(.archived | not) | .full_name')
  fi
  for repo in $(sort <<<"$listing"); do
    [[ ${repo%%/*} == "$owner" && $repo != "$source" ]] || continue
    if ! out=$(gh api "repos/$repo/contents/skills-lock.json" -H "Accept: application/vnd.github.raw" 2>&1); then
      [[ $out == *"HTTP 404"* ]] && continue
      echo "update-consumers: cannot read skills-lock.json of $repo: $out" >&2
      return 1
    fi
    if node -e '
      const lock = JSON.parse(process.argv[1]);
      process.exit(Object.values(lock.skills ?? {}).some((e) => e.source === process.argv[2]) ? 0 : 1);
    ' "$out" "$source" 2>/dev/null; then echo "$repo"; fi
  done
}

prepare() {
  local repos repo key
  repos=$(consumers)
  # The list also keeps the artifact of the job from being empty.
  printf '%s\n' $repos >"$dir/consumers.txt"
  for repo in $repos; do
    key=${repo//\//__}
    clone "$repo" "$work/$key" || { failed+=("$repo"); continue; }
  done
  if [[ $revoke == true ]]; then
    gh api --method DELETE /installation/token >/dev/null
    echo "Revoked the token before the skills CLI runs."
  fi
  for repo in $repos; do
    key=${repo//\//__}
    [[ -d $work/$key ]] || continue
    echo "::group::prepare $repo"
    if (cd "$work/$key" && unset GH_TOKEN GITHUB_TOKEN &&
      bash "$here/scripts/update-pr.sh" --repo "$repo" --source "$source" --bump-pin --prepare "$dir/$key"); then
      echo "| \`$repo\` | prepared |" >>"$summary"
    else
      echo "::error title=$repo::The update failed. Open the log group of $repo."
      failed+=("$repo")
      rm -rf "${dir:?}/$key"
    fi
    echo "::endgroup::"
  done
}

publish() {
  local d repo key
  if [[ -n ${APP_SLUG:-} ]]; then
    BOT_NAME="$APP_SLUG[bot]"
    BOT_EMAIL="$(gh api "users/$APP_SLUG%5Bbot%5D" --jq .id)+$APP_SLUG[bot]@users.noreply.github.com"
    export BOT_NAME BOT_EMAIL
  fi
  for d in "$dir"/*/; do
    [[ -f $d/repo ]] || continue
    repo=$(cat "$d/repo")
    key=${repo//\//__}
    # The folder name and the repository must agree, and the owner must be this one.
    [[ $key == "$(basename "$d")" && ${repo%%/*} == "$owner" ]] || { echo "update-consumers: $d does not belong to $owner" >&2; failed+=("$d"); continue; }
    echo "::group::publish $repo"
    if clone "$repo" "$work/pub-$key" &&
      (cd "$work/pub-$key" && bash "$here/scripts/update-pr.sh" --repo "$repo" --source "$source" --bump-pin --publish "$d" "${pr_args[@]}"); then
      echo "| \`$repo\` | done |" >>"$summary"
    else
      echo "::error title=$repo::The pull request step failed. Open the log group of $repo."
      echo "| \`$repo\` | failed |" >>"$summary"
      failed+=("$repo")
    fi
    echo "::endgroup::"
  done
}

case $mode in
  prepare) prepare ;;
  publish) publish ;;
  both) prepare; publish ;;
esac
if ((${#failed[@]})); then
  echo "update-consumers: failed in ${failed[*]}" >&2
  exit 1
fi
