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
// --other-sources report|fail also checks the lock entries of the other
// sources, for example a skill that a repository adds from shadcn/ui. In the
// local check, a skill that the repository does not commit is not checked. In
// the upstream check, each other source needs its own checkout, given with
// --upstream-other KEY=DIR, or --fetch-other to clone each one. KEY is the
// source, or SOURCE#REF for an entry with a ref. With "report", a difference
// prints a warning and the exit status does not change.
//
// The hash rule is a copy of computeSkillFolderHash in skills@1.7.3
// (dist/cli.mjs): SHA-256 over every regular file in the skill folder, sorted
// with localeCompare on the relative path, as path then content. It skips
// .git, node_modules and symbolic links.
//
// Usage: node check-skills-lock.mjs [--root DIR] [--source OWNER/REPO]...
//          [--allow NAME]... [--no-claude-links] [--other-sources MODE]
//        node check-skills-lock.mjs [--root DIR] --source OWNER/REPO... --upstream DIR
//          [--other-sources MODE] [--upstream-other KEY=DIR]... [--fetch-other]
//        node check-skills-lock.mjs [--root DIR] --source OWNER/REPO... --names
// --upstream needs --source, because DIR is a checkout of one source.
// Each --source must match at least one lock entry.
// --names prints the names of the entries of the --source repositories.
// --fetch-other clones only the skill folders of each other GitHub source,
// with no history. Upstream content is data. This script never runs it.
// Exit status: 0 when all checks pass, 1 when a check fails, 2 on bad usage.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { lstat, readFile, readdir, readlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";

const args = process.argv.slice(2);
let root = process.cwd();
const sources = [];
const allowed = new Set();
let claudeLinks = true;
let upstream = null;
let otherSources = "off";
const upstreamOther = new Map();
let fetchOther = false;
let action = "check";
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--root") root = args[++i];
  else if (arg === "--source") sources.push(args[++i]);
  else if (arg === "--allow") allowed.add(args[++i]);
  else if (arg === "--no-claude-links") claudeLinks = false;
  else if (arg === "--upstream") upstream = args[++i];
  else if (arg === "--other-sources") otherSources = args[++i];
  else if (arg === "--upstream-other") {
    const value = args[++i] ?? "";
    const at = value.lastIndexOf("=");
    if (at < 1) {
      console.error(`check-skills-lock: --upstream-other needs KEY=DIR, not: ${value}`);
      process.exit(2);
    }
    upstreamOther.set(value.slice(0, at), value.slice(at + 1));
  } else if (arg === "--fetch-other") fetchOther = true;
  else if (arg === "--names") action = "names";
  else {
    console.error(`check-skills-lock: unknown argument: ${arg}`);
    process.exit(2);
  }
}
if (upstream !== null && (!upstream || sources.length === 0)) {
  console.error("check-skills-lock: --upstream needs a directory and at least one --source");
  process.exit(2);
}
if (!["off", "report", "fail"].includes(otherSources)) {
  console.error(`check-skills-lock: --other-sources must be off, report or fail, not: ${otherSources}`);
  process.exit(2);
}
if (action === "names" && sources.length === 0) {
  console.error("check-skills-lock: --names needs at least one --source");
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
// An entry of another source: with no --source, every entry is one of ours.
const isOther = (entry) => sources.length > 0 && !sources.includes(entry.source);
const others = otherSources === "off" ? [] : entries.filter(([, entry]) => isOther(entry));
const otherKey = (entry) => (entry.ref ? `${entry.source}#${entry.ref}` : entry.source);

let failures = 0;
let warnings = 0;
const fail = (name, message) => {
  failures++;
  console.log(`FAIL ${name}: ${message}`);
};
// A finding about a skill of another source. With "report", it does not
// change the exit status.
const otherFinding = (name, message) => {
  if (otherSources === "fail") return fail(name, message);
  warnings++;
  console.log(`warn ${name}: ${message}`);
  // On stderr, so that the job summary, which gets stdout, has no command.
  if (process.env.GITHUB_ACTIONS === "true") {
    console.error(`::warning title=Agent skill ${name}::${message.replaceAll("\n", " ")}`);
  }
};
const note = (name, message) => console.log(`skip ${name}: ${message}`);

// A source that no lock entry has would make the check pass with nothing
// checked, for example after a typo in the source input of the action.
for (const source of sources) {
  if (!entries.some(([, entry]) => entry.source === source)) {
    fail(`source ${source}`, "no entry in skills-lock.json has this source. Check the --source value or the source input of the action.");
  }
}

if (action === "names") {
  if (failures > 0) process.exit(1);
  for (const [name, entry] of entries) if (sources.includes(entry.source)) console.log(name);
  process.exit(0);
}

function finish(success) {
  if (warnings > 0) {
    console.log(`${warnings} skill(s) from other sources need attention. This does not fail the check.`);
  }
  if (failures > 0) {
    console.log(`${failures} check(s) failed.`);
    process.exit(1);
  }
  console.log(warnings > 0 ? "No check failed." : success);
  process.exit(0);
}

// Fetch one commit of a source without blobs, then check out only the skill
// folders. The checkout keeps the line endings that git stores, as the skills
// CLI gets them on Linux.
const temporary = [];
process.on("exit", () => {
  for (const dir of temporary) rmSync(dir, { recursive: true, force: true });
});
function fetchSource(source, ref, dirs) {
  const dir = mkdtempSync(join(tmpdir(), "agent-skills-other-"));
  temporary.push(dir);
  const git = (...gitArgs) =>
    execFileSync("git", gitArgs, {
      cwd: dir,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
  git("init", "-q");
  git("config", "core.autocrlf", "false");
  git("config", "core.eol", "lf");
  git("remote", "add", "origin", `https://github.com/${source.replace(/\.git$/, "")}.git`);
  git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", ref || "HEAD");
  git("sparse-checkout", "set", "--no-cone", ...dirs.map((d) => `/${d}/`));
  git("checkout", "-q", "FETCH_HEAD");
  return dir;
}

async function fetchOtherSources() {
  const groups = new Map();
  for (const [, entry] of others) {
    if (entry.sourceType !== "github" || !entry.skillPath) continue;
    const key = otherKey(entry);
    if (upstreamOther.has(key)) continue;
    const group = groups.get(key) ?? { entry, dirs: new Set() };
    group.dirs.add(dirname(entry.skillPath));
    groups.set(key, group);
  }
  for (const [key, { entry, dirs }] of groups) {
    try {
      upstreamOther.set(key, fetchSource(entry.source, entry.ref, [...dirs]));
    } catch (error) {
      console.log(`cannot fetch ${key}: ${String(error.stderr || error.message).trim().split("\n").pop()}`);
    }
  }
}

const updateCommand = (name) => `DISABLE_TELEMETRY=1 npx skills@1.7.3 update -p -y ${name}`;

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
  for (const [name, entry] of others) {
    const key = otherKey(entry);
    if (entry.sourceType !== "github" || !entry.skillPath) {
      note(name, `the source type is ${entry.sourceType ?? "unknown"}, so the upstream check cannot read ${entry.source}`);
      continue;
    }
    const checkout = upstreamOther.get(key);
    if (!checkout) {
      otherFinding(name, `there is no checkout of ${key}, so the upstream check did not compare ${name}`);
      continue;
    }
    const dir = join(checkout, dirname(entry.skillPath));
    const stat = await exists(dir);
    if (!stat || !stat.isDirectory()) {
      otherFinding(name, `${name} is no longer in ${key}. Remove it or find its new source.`);
      continue;
    }
    const actual = await skillFolderHash(dir);
    if (actual !== entry.computedHash) {
      otherFinding(name, `${name} is out of date with ${key}. Read the upstream change, then run: ${updateCommand(name)}`);
      continue;
    }
    console.log(`ok   ${name} ${actual.slice(0, 12)} (${key})`);
  }
  finish(`All agent skills match ${[...sources, ...new Set(others.map(([, entry]) => otherKey(entry)))].join(", ")}.`);
}

if (upstream !== null) {
  if (fetchOther) await fetchOtherSources();
  await checkUpstream();
}

for (const [name, entry] of entries) {
  if (isOther(entry)) continue;
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

// A skill of another source is in .agents/skills, or, when the CLI installed
// it for Claude Code only, a real folder in .claude/skills. A repository can
// also leave it out of git and install it in a bootstrap step.
for (const [name, entry] of others) {
  if (entry.sourceType === "node_modules" || entry.sourceType === "local") {
    note(name, `the source type is ${entry.sourceType}, so there is no copy to check`);
    continue;
  }
  let dir = join(skillsDir, name);
  let stat = await exists(dir);
  let shown = `.agents/skills/${name}`;
  if (!stat || !stat.isDirectory()) {
    dir = join(root, ".claude", "skills", name);
    stat = await exists(dir);
    shown = `.claude/skills/${name}`;
  }
  if (!stat || !stat.isDirectory()) {
    note(name, `the repository has no copy of ${name}, so the lock check did not compare it`);
    continue;
  }
  const actual = await skillFolderHash(dir);
  if (actual !== entry.computedHash) {
    otherFinding(name, `hash ${actual.slice(0, 12)} of ${shown} does not match the lock (${String(entry.computedHash).slice(0, 12)}). Do not edit vendored skills. To get the upstream copy again, run: ${updateCommand(name)}`);
    continue;
  }
  console.log(`ok   ${name} ${actual.slice(0, 12)} (${entry.source}, ${shown})`);
}

const onDisk = (await exists(skillsDir)) ? await readdir(skillsDir, { withFileTypes: true }) : [];
for (const dirent of onDisk) {
  if (!dirent.isDirectory()) continue;
  if (lock.skills?.[dirent.name] || allowed.has(dirent.name)) continue;
  fail(dirent.name, `.agents/skills/${dirent.name} has no entry in skills-lock.json`);
}

finish("All agent skills match skills-lock.json.");
