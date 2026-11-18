#!/usr/bin/env node
// Move each commit pin of an action in .github/workflows to its latest
// release. This is the bump that Dependabot opens as its own pull request.
// The skills update pull request does it too, so one pull request moves the
// skills and the action together.
//
// A pin is `uses: OWNER/REPO@<40 hex> # vX.Y.Z`. The script changes a pin when
// its commit is not the commit of the latest release, and the release in its
// comment is lower or missing. Pins by tag name or by branch stay as they are.
//
// Usage: node bump-action-pin.mjs [--root DIR] --source OWNER/REPO [--tag vX.Y.Z --commit SHA]
// Without --tag, the script reads the tags of https://github.com/OWNER/REPO.git
// and takes the highest vX.Y.Z tag that is not a pre-release.
// Output, only when a pin changed: lines from=vA.B.C, to=vX.Y.Z, commit=SHA
// and one file=PATH line for each changed file.
// Exit status: 0 when done, 1 on an error, 2 on bad usage.

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
let root = process.cwd();
let source = null;
let tag = null;
let commit = null;
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--root") root = args[++i];
  else if (arg === "--source") source = args[++i];
  else if (arg === "--tag") tag = args[++i];
  else if (arg === "--commit") commit = args[++i];
  else {
    console.error(`bump-action-pin: unknown argument: ${arg}`);
    process.exit(2);
  }
}
if (!source || !/^[\w.-]+\/[\w.-]+$/.test(source) || Boolean(tag) !== Boolean(commit)) {
  console.error("bump-action-pin: give --source OWNER/REPO, and --tag with --commit or neither");
  process.exit(2);
}

const version = (name) => {
  const match = /^v(\d+)\.(\d+)\.(\d+)$/.exec(name ?? "");
  return match ? match.slice(1).map(Number) : null;
};
const compare = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];

if (!tag) {
  let out;
  try {
    out = execFileSync("git", ["ls-remote", "--tags", `https://github.com/${source}.git`, "refs/tags/v*"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
  } catch (error) {
    console.error(`bump-action-pin: cannot read the tags of ${source}: ${String(error.stderr || error.message).trim()}`);
    process.exit(1);
  }
  // An annotated tag has a second line, NAME^{}, with the commit.
  const commits = new Map();
  for (const line of out.split("\n")) {
    const [sha, ref] = line.split("\t");
    if (!ref) continue;
    const name = ref.replace(/^refs\/tags\//, "").replace(/\^\{\}$/, "");
    if (!version(name)) continue;
    if (ref.endsWith("^{}") || !commits.has(name)) commits.set(name, sha);
  }
  const latest = [...commits.keys()].sort((a, b) => compare(version(a), version(b))).pop();
  if (!latest) {
    console.error(`bump-action-pin: ${source} has no vX.Y.Z tag`);
    process.exit(1);
  }
  tag = latest;
  commit = commits.get(latest);
}
if (!version(tag) || !/^[0-9a-f]{40}$/.test(commit)) {
  console.error(`bump-action-pin: bad release ${tag} ${commit}`);
  process.exit(2);
}

const escaped = source.replace(/[.\\]/g, "\\$&");
const pin = new RegExp(`(uses:\\s*["']?${escaped})@([0-9a-f]{40})(["']?)([ \\t]*#[ \\t]*(\\S+))?`, "g");
const workflows = join(root, ".github", "workflows");
let files = [];
try {
  files = readdirSync(workflows).filter((name) => /\.ya?ml$/.test(name)).sort();
} catch {
  process.exit(0);
}

let from = null;
const changed = [];
for (const name of files) {
  const path = join(workflows, name);
  const text = readFileSync(path, "utf-8");
  const next = text.replace(pin, (whole, head, sha, quote, _comment, label) => {
    if (sha === commit) return whole;
    const old = version(label);
    if (old && compare(old, version(tag)) >= 0) return whole;
    const shown = old ? label : sha.slice(0, 12);
    if (!from || (old && version(from) && compare(old, version(from)) < 0)) from = shown;
    return `${head}@${commit}${quote} # ${tag}`;
  });
  if (next !== text) {
    writeFileSync(path, next);
    changed.push(`.github/workflows/${name}`);
  }
}
if (changed.length > 0) {
  console.log(`from=${from}`);
  console.log(`to=${tag}`);
  console.log(`commit=${commit}`);
  for (const file of changed) console.log(`file=${file}`);
}
