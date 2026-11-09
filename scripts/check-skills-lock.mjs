#!/usr/bin/env node
// Check the agent skills in a repository against its skills-lock.json.
//
// The skills CLI (skills@1.7.3) writes computedHash when it installs a skill,
// but `npx skills update` compares only the upstream hash with the lock. It
// never reads the local files, so a hand edit in .agents/skills stays hidden.
// This script reads the local files and finds that edit.
//
// With --upstream DIR, the script compares the lock with a checkout of the
// source repository instead, and skips the local checks. It then finds a skill
// that changed or left the source after the last update.
//
// The hash rule is a copy of computeSkillFolderHash in skills@1.7.3
// (dist/cli.mjs): SHA-256 over every regular file in the skill folder, sorted
// with localeCompare on the relative path, as path then content. It skips
// .git, node_modules and symbolic links.
//
// Usage: node check-skills-lock.mjs [--root DIR] [--source OWNER/REPO]...
//          [--allow NAME]... [--no-claude-links]
//        node check-skills-lock.mjs [--root DIR] --source OWNER/REPO... --upstream DIR
// --upstream needs --source, because DIR is a checkout of one source.
// Each --source must match at least one lock entry.
// Exit status: 0 when all checks pass, 1 when a check fails, 2 on bad usage.

import { createHash } from "node:crypto";
import { lstat, readFile, readdir, readlink } from "node:fs/promises";
import { dirname, join, relative } from "node:path";

const args = process.argv.slice(2);
let root = process.cwd();
const sources = [];
const allowed = new Set();
let claudeLinks = true;
let upstream = null;
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--root") root = args[++i];
  else if (arg === "--source") sources.push(args[++i]);
  else if (arg === "--allow") allowed.add(args[++i]);
  else if (arg === "--no-claude-links") claudeLinks = false;
  else if (arg === "--upstream") upstream = args[++i];
  else {
    console.error(`check-skills-lock: unknown argument: ${arg}`);
    process.exit(2);
  }
}
if (upstream !== null && (!upstream || sources.length === 0)) {
  console.error("check-skills-lock: --upstream needs a directory and at least one --source");
  process.exit(2);
}

async function collectFiles(baseDir, currentDir, results) {
  const entries = await readdir(currentDir, { withFileTypes: true });
  await Promise.all(
    entries.map(async (entry) => {
      const fullPath = join(currentDir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === ".git" || entry.name === "node_modules") return;
        await collectFiles(baseDir, fullPath, results);
      } else if (entry.isFile()) {
        const relativePath = relative(baseDir, fullPath).split("\\").join("/");
        results.push({ relativePath, content: await readFile(fullPath) });
      }
    }),
  );
}

async function skillFolderHash(dir) {
  const files = [];
  await collectFiles(dir, dir, files);
  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  const hash = createHash("sha256");
  for (const file of files) {
    hash.update(file.relativePath);
    hash.update(file.content);
  }
  return hash.digest("hex");
}

async function exists(path) {
  try {
    return await lstat(path);
  } catch {
    return null;
  }
}

const lockPath = join(root, "skills-lock.json");
let lock;
try {
  lock = JSON.parse(await readFile(lockPath, "utf-8"));
} catch (error) {
  console.error(`check-skills-lock: cannot read ${lockPath}: ${error.message}`);
  process.exit(1);
}

const skillsDir = join(root, ".agents", "skills");
const entries = Object.entries(lock.skills ?? {});
let failures = 0;
const fail = (name, message) => {
  failures++;
  console.log(`FAIL ${name}: ${message}`);
};

// A source that no lock entry has would make the check pass with nothing
// checked, for example after a typo in the source input of the action.
for (const source of sources) {
  if (!entries.some(([, entry]) => entry.source === source)) {
    fail(`source ${source}`, "no entry in skills-lock.json has this source. Check the --source value or the source input of the action.");
  }
}

// Compare each lock entry with the skill folder in a checkout of its source.
// The skills CLI takes the hash on the source folder, so the two must match.
async function checkUpstream() {
  for (const [name, entry] of entries) {
    if (!sources.includes(entry.source)) continue;
    if (!entry.skillPath) {
      fail(name, `the lock entry has no skillPath`);
      continue;
    }
    const dir = join(upstream, dirname(entry.skillPath));
    const stat = await exists(dir);
    if (!stat || !stat.isDirectory()) {
      fail(name, `${name} is no longer in ${entry.source}. Run: DISABLE_TELEMETRY=1 npx skills@1.7.3 remove ${name}`);
      continue;
    }
    const actual = await skillFolderHash(dir);
    if (actual !== entry.computedHash) {
      fail(name, `${name} is out of date. Run: DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y`);
      continue;
    }
    console.log(`ok   ${name} ${actual.slice(0, 12)} (${entry.source})`);
  }
  if (failures > 0) {
    console.log(`${failures} check(s) failed.`);
    process.exit(1);
  }
  console.log(`All agent skills match ${sources.join(", ")}.`);
  process.exit(0);
}

if (upstream !== null) await checkUpstream();

for (const [name, entry] of entries) {
  if (sources.length > 0 && !sources.includes(entry.source)) continue;
  if (entry.sourceType === "node_modules") continue;
  const dir = join(skillsDir, name);
  const stat = await exists(dir);
  if (!stat || !stat.isDirectory()) {
    fail(name, `.agents/skills/${name} is missing`);
    continue;
  }
  const actual = await skillFolderHash(dir);
  if (actual !== entry.computedHash) {
    fail(name, `hash ${actual.slice(0, 12)} does not match the lock (${String(entry.computedHash).slice(0, 12)}). Do not edit vendored skills. Change them in ${entry.source} and run: DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y`);
    continue;
  }
  const before = failures;
  if (claudeLinks) {
    const link = join(root, ".claude", "skills", name);
    const linkStat = await exists(link);
    const want = `../../.agents/skills/${name}`;
    if (!linkStat) fail(name, `.claude/skills/${name} is missing`);
    else if (!linkStat.isSymbolicLink()) fail(name, `.claude/skills/${name} is not a symbolic link`);
    else if ((await readlink(link)) !== want) fail(name, `.claude/skills/${name} does not point to ${want}`);
  }
  if (failures === before) console.log(`ok   ${name} ${actual.slice(0, 12)} (${entry.source})`);
}

const onDisk = (await exists(skillsDir)) ? await readdir(skillsDir, { withFileTypes: true }) : [];
for (const dirent of onDisk) {
  if (!dirent.isDirectory()) continue;
  if (lock.skills?.[dirent.name] || allowed.has(dirent.name)) continue;
  fail(dirent.name, `.agents/skills/${dirent.name} has no entry in skills-lock.json`);
}

if (failures > 0) {
  console.log(`${failures} check(s) failed.`);
  process.exit(1);
}
console.log("All agent skills match skills-lock.json.");
