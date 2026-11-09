#!/bin/sh
# Build one zip file for each plugin from a release tag, for the claude.ai
# upload. The zip has the files of plugins/<name> at the tag. Its plugin.json
# gets "version" from the tag, so the organisation settings show which release
# is live. The plugin.json files in the repository keep no version, so that
# Claude Code users of the marketplace get each commit.
#
# Usage: sh scripts/build-zips.sh vX.Y.Z [OUTDIR]   (OUTDIR defaults to dist)
set -eu
tag=${1:-}
out=${2:-dist}
case $tag in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: build-zips.sh vX.Y.Z [OUTDIR]" >&2; exit 2 ;;
esac
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "build-zips: no tag $tag" >&2
  exit 2
fi
version=${tag#v}
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Add "version" after "name" in a plugin.json: node -e "$set_version" IN OUT VERSION
set_version='
const fs = require("fs");
const [file, out, version] = process.argv.slice(1);
const { name, ...rest } = JSON.parse(fs.readFileSync(file, "utf-8"));
if (!name) throw new Error(`${file}: no name`);
fs.writeFileSync(out, JSON.stringify({ name, version, ...rest }, null, 2) + "\n");
'

manifest=.claude-plugin/plugin.json
for name in $(git ls-tree -d --name-only "$tag:plugins"); do
  git show "$tag:plugins/$name/$manifest" >"$work/in.json"
  node -e "$set_version" "$work/in.json" "$work/out.json" "$version"
  blob=$(git hash-object -w "$work/out.json")
  # Build the tree in a temporary index, so the checkout does not change.
  rm -f "$work/index"
  GIT_INDEX_FILE=$work/index git read-tree "$tag:plugins/$name"
  GIT_INDEX_FILE=$work/index git update-index --cacheinfo "100644,$blob,$manifest"
  tree=$(GIT_INDEX_FILE=$work/index git write-tree)
  git archive --format=zip -o "$out/$name.zip" "$tree"
  echo "$out/$name.zip: $name $version"
done
