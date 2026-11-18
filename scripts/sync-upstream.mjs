#!/usr/bin/env node
// Copy third-party skills from their upstream repositories.
//
// upstream/sources.json pins each third-party skill to one upstream commit.
// It also records the git tree id of the skill folder at that commit, so a
// check can see an upstream change without a full clone.
//
//   node scripts/sync-upstream.mjs check            Report skills whose upstream folder changed.
//   node scripts/sync-upstream.mjs pull NAME [SHA]  Copy NAME at SHA (default: upstream HEAD),
//                                                   apply the local patches, update sources.json.
//   node scripts/sync-upstream.mjs verify           Build each skill again at its pinned commit
//                                                   and compare the result with plugins/.
//
// pull and verify use the same build step: fetch the upstream commit, copy the
// listed files and the licence into a scratch folder, then apply the patches.
// A source with "transform": NAME then runs upstream/transforms/NAME.mjs on
// the folder. A transform finds its anchors in the text and fails when one is
// missing, so it survives upstream edits that break a diff patch.
//
// Exit status of check: 0 when nothing changed, 3 when an upstream changed, 1 on error.
// check only reports a change of a source with "check": "report". That change
// does not give exit status 3. Use it for an upstream that releases more often
// than we bump its pin.
// Exit status of verify: 0 when each skill is the same as its build, 1 on a difference or error.
// Upstream content is data. This script copies files and never runs them.

import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourcesPath = join(repoRoot, "upstream", "sources.json");
const sources = JSON.parse(readFileSync(sourcesPath, "utf-8"));
const base = process.env.UPSTREAM_GIT_BASE ?? "https://github.com/";
const transforms = {};
for (const src of Object.values(sources)) {
  if (src.transform && !transforms[src.transform]) {
    transforms[src.transform] = (await import(join(repoRoot, "upstream", "transforms", `${src.transform}.mjs`))).default;
  }
}

const git = (cwd, ...args) =>
  execFileSync("git", args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }).trim();

// Fetch one commit without blobs, then check out only the paths we need.
// The checkout keeps the line endings that git stores, as on Linux, also on a
// computer with core.autocrlf=true.
function fetchAt(src, ref, paths) {
  const dir = mkdtempSync(join(tmpdir(), "qoax-upstream-"));
  try {
    git(dir, "init", "-q");
    git(dir, "config", "core.autocrlf", "false");
    git(dir, "config", "core.eol", "lf");
    git(dir, "remote", "add", "origin", `${base}${src.repo}.git`);
    git(dir, "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", ref);
    git(dir, "sparse-checkout", "set", "--no-cone", ...paths);
    git(dir, "checkout", "-q", "FETCH_HEAD");
  } catch (error) {
    rmSync(dir, { recursive: true, force: true });
    throw error;
  }
  return dir;
}

function listFiles(dir, prefix = "") {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    const rel = prefix ? `${prefix}/${name}` : name;
    return statSync(full).isDirectory() ? listFiles(full, rel) : [rel];
  });
}

// Copy one file and keep its mode, so an executable script stays executable.
function copyFile(from, to) {
  mkdirSync(dirname(to), { recursive: true });
  copyFileSync(from, to);
  chmodSync(to, statSync(from).mode & 0o777);
}

const isExecutable = (path) => (statSync(path).mode & 0o111) !== 0;

const licencePathOf = (src) =>
  src.licence.startsWith("/") ? src.licence.slice(1) : `${src.path}/${src.licence}`;

// Fetch src at ref and make the skill folder in <dir>/out/<name>: the listed
// files, the licence as LICENSE, then the local patches. The caller removes dir.
function build(name, src, ref) {
  const licencePath = licencePathOf(src);
  const dir = fetchAt(src, ref, [`/${src.path}/`, `/${licencePath}`]);
  try {
    const commit = git(dir, "rev-parse", "FETCH_HEAD");
    const tree = git(dir, "rev-parse", `FETCH_HEAD:${src.path}`);
    const from = join(dir, src.path);
    const out = join(dir, "out", name);
    const upstreamFiles = listFiles(from);
    const dropped = upstreamFiles.filter((f) => !src.files.includes(f));
    const missing = src.files.filter((f) => !upstreamFiles.includes(f));
    if (missing.length > 0) throw new Error(`upstream no longer has: ${missing.join(", ")}`);
    for (const file of src.files) copyFile(join(from, file), join(out, file));
    copyFile(join(dir, licencePath), join(out, "LICENSE"));
    for (const patch of src.patches ?? []) {
      git(dir, "apply", `--directory=out/${name}`, join(repoRoot, "upstream", "patches", name, patch));
    }
    if (src.transform) transforms[src.transform]({ name, src: { ...src, commit }, out });
    return { dir, out, commit, tree, dropped };
  } catch (error) {
    rmSync(dir, { recursive: true, force: true });
    throw error;
  }
}

function check() {
  let changed = 0;
  for (const [name, src] of Object.entries(sources)) {
    const dir = fetchAt(src, "HEAD", [`/${src.path}/`]);
    try {
      const head = git(dir, "rev-parse", "FETCH_HEAD");
      const tree = git(dir, "rev-parse", `FETCH_HEAD:${src.path}`);
      if (tree === src.tree) {
        console.log(`same    ${name} (${src.repo} ${src.commit.slice(0, 7)})`);
      } else {
        const reportOnly = src.check === "report";
        if (!reportOnly) changed++;
        const label = reportOnly ? `${name} (report only, no failure)` : name;
        console.log(`changed ${label}: ${src.repo} ${src.commit.slice(0, 7)} -> ${head.slice(0, 7)}. Run: node scripts/sync-upstream.mjs pull ${name} ${head}`);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  process.exit(changed > 0 ? 3 : 0);
}

function pull(name, ref = "HEAD") {
  const src = sources[name];
  if (!src) throw new Error(`no source named ${name} in upstream/sources.json`);
  const { dir, out, commit, tree, dropped } = build(name, src, ref);
  try {
    const to = join(repoRoot, "plugins", src.plugin, "skills", name);
    rmSync(to, { recursive: true, force: true });
    for (const file of listFiles(out)) copyFile(join(out, file), join(to, file));
    sources[name] = { ...src, commit, tree };
    writeFileSync(sourcesPath, `${JSON.stringify(sources, null, 2)}\n`);
    console.log(`${name}: copied ${src.files.length} file(s) from ${src.repo} ${commit.slice(0, 7)}`);
    if (dropped.length > 0) console.log(`${name}: not copied (add to "files" to keep): ${dropped.join(", ")}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Compare a fresh build with the folder in plugins/: the same relative paths,
// the same bytes and the same executable bit.
function differences(want, have) {
  const wantFiles = listFiles(want);
  const haveFiles = existsSync(have) ? listFiles(have) : [];
  const found = [];
  for (const file of wantFiles) {
    if (!haveFiles.includes(file)) found.push([file, "missing"]);
    else if (!readFileSync(join(want, file)).equals(readFileSync(join(have, file)))) found.push([file, "content"]);
    else if (isExecutable(join(want, file)) !== isExecutable(join(have, file))) found.push([file, "mode"]);
  }
  for (const file of haveFiles) {
    if (!wantFiles.includes(file)) found.push([file, "extra"]);
  }
  return found;
}

function verify() {
  let failed = 0;
  for (const [name, src] of Object.entries(sources)) {
    const { dir, out } = build(name, src, src.commit);
    try {
      const found = differences(out, join(repoRoot, "plugins", src.plugin, "skills", name));
      if (found.length === 0) console.log(`ok ${name}`);
      else failed++;
      for (const [file, kind] of found) console.log(`differs ${name}: ${file} (${kind})`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  process.exit(failed > 0 ? 1 : 0);
}

const [command, ...rest] = process.argv.slice(2);
try {
  if (command === "check") check();
  else if (command === "verify") verify();
  else if (command === "pull" && rest[0]) pull(rest[0], rest[1]);
  else {
    console.error("usage: sync-upstream.mjs check | verify | pull NAME [SHA]");
    process.exit(2);
  }
} catch (error) {
  console.error(`sync-upstream: ${error.message}`);
  process.exit(1);
}
