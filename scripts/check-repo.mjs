#!/usr/bin/env node
// Offline checks for the marketplace, the plugins and the upstream pins.
// Run: node scripts/check-repo.mjs
//
// - Each marketplace entry points at ./plugins/<name>, and that folder has a
//   plugin.json with the same name and a "license".
// - Each folder in plugins/ has a marketplace entry.
// - No plugin.json or marketplace entry sets "version", so users get each new commit.
// - Each skill folder has SKILL.md and a LICENSE. The SKILL.md frontmatter has
//   a "name" equal to the folder name and a "description".
// - Skill names are unique across the plugins.
// - No skill folder contains a symbolic link. The skills CLI hash skips them.
// - Each skill in upstream/sources.json has its folder in plugins/<plugin>/skills/
//   and each patch file it lists. Its "check" is "report" or not set.
//
// Exit status: 0 when all checks pass, 1 on an error.

import { existsSync, lstatSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];
const rel = (path) => relative(root, path);
const isDir = (path) => existsSync(path) && statSync(path).isDirectory();
const isFile = (path) => existsSync(path) && statSync(path).isFile();
const readJson = (path) => JSON.parse(readFileSync(path, "utf-8"));

const market = readJson(join(root, ".claude-plugin", "marketplace.json"));
const entries = new Map(market.plugins.map((entry) => [entry.name, entry]));

for (const [name, entry] of entries) {
  if (entry.source !== `./plugins/${name}`) errors.push(`${name}: source must be ./plugins/${name}`);
  const manifest = join(root, "plugins", name, ".claude-plugin", "plugin.json");
  if (!isFile(manifest)) {
    errors.push(`${name}: no ${rel(manifest)}`);
    continue;
  }
  const data = readJson(manifest);
  if (data.name !== name) errors.push(`${name}: plugin.json name is ${JSON.stringify(data.name)}`);
  if (!data.license) errors.push(`${name}: plugin.json has no "license"`);
  if ("version" in data || "version" in entry) errors.push(`${name}: remove version, so that each commit reaches users`);
}

// Return the lines between the first two "---" lines, or null.
function frontmatter(text) {
  const lines = text.split(/\r?\n/);
  if (lines[0] !== "---") return null;
  const end = lines.indexOf("---", 1);
  return end === -1 ? null : lines.slice(1, end).join("\n");
}

function symlinks(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    const stat = lstatSync(full);
    if (stat.isSymbolicLink()) return [full];
    return stat.isDirectory() ? symlinks(full) : [];
  });
}

const skillOwner = new Map();
const pluginsDir = join(root, "plugins");
for (const plugin of readdirSync(pluginsDir).sort()) {
  const folder = join(pluginsDir, plugin);
  if (!isDir(folder)) continue;
  if (!entries.has(plugin)) errors.push(`plugins/${plugin}: no entry in marketplace.json`);
  const skillsDir = join(folder, "skills");
  if (!isDir(skillsDir)) {
    errors.push(`plugins/${plugin}: no skills/ folder`);
    continue;
  }
  for (const skill of readdirSync(skillsDir).sort()) {
    const dir = join(skillsDir, skill);
    if (!isDir(dir)) continue;
    if (skillOwner.has(skill)) errors.push(`${rel(dir)}: the skill name is also in plugins/${skillOwner.get(skill)}`);
    else skillOwner.set(skill, plugin);
    const md = join(dir, "SKILL.md");
    if (!isFile(md)) {
      errors.push(`${rel(dir)}: no SKILL.md`);
      continue;
    }
    if (!isFile(join(dir, "LICENSE"))) errors.push(`${rel(dir)}: no LICENSE`);
    const front = frontmatter(readFileSync(md, "utf-8"));
    if (front === null) {
      errors.push(`${rel(md)}: no frontmatter`);
    } else {
      const match = front.match(/^name:\s*['"]?([\w.-]+)/m);
      if (!match || match[1] !== skill) errors.push(`${rel(md)}: name must be ${skill}`);
      if (!/^description:/m.test(front)) errors.push(`${rel(md)}: no description`);
    }
    const links = symlinks(dir);
    if (links.length > 0) errors.push(`${rel(dir)}: symbolic links are not allowed: ${relative(dir, links[0])}`);
  }
}

const sources = readJson(join(root, "upstream", "sources.json"));
for (const [name, src] of Object.entries(sources)) {
  const dir = join(pluginsDir, String(src.plugin), "skills", name);
  if (!isDir(dir)) errors.push(`upstream/sources.json: ${name} has no folder ${rel(dir)}`);
  for (const patch of src.patches ?? []) {
    const file = join(root, "upstream", "patches", name, patch);
    if (!isFile(file)) errors.push(`upstream/sources.json: ${name} lists a missing patch ${rel(file)}`);
  }
  if ("check" in src && src.check !== "report") {
    errors.push(`upstream/sources.json: ${name} has "check": ${JSON.stringify(src.check)}. Use "report" or remove it.`);
  }
}

if (errors.length > 0) {
  console.log(errors.join("\n"));
  process.exit(1);
}
console.log(`ok: ${entries.size} plugins, ${skillOwner.size} skills`);
