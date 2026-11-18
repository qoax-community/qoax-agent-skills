#!/usr/bin/env node
// Bump the modern-web-guidance and chrome-extensions skills to a newer
// release of GoogleChrome/modern-web-guidance, after static checks of its npm
// package. The script never runs the package: it reads npm metadata, the
// provenance attestation and the files in the tarball.
//
// 1. Pick the release: the highest vX.Y.Z tag upstream whose npm version is
//    at least --cooldown days old (default 7). npm lets a publisher unpublish
//    a version in its first 72 hours. With no --force, skip the bump while the
//    pinned version is less than --min-interval days old (default 28).
// 2. Gates. Each must pass:
//    - npm view: no dependencies of any kind and no scripts
//    - the tarball has the sha512 that npm gives as dist.integrity
//    - npm audit signatures verifies the registry signature and the
//      attestation, in a scratch project that installs with --ignore-scripts
//    - the SLSA provenance names the tarball digest, the repository
//      GoogleChrome/modern-web-guidance-src and .github/workflows/publish.yml,
//      and the signing certificate names the same workflow
//    - skill-version.txt in the tarball equals --skill-version in SKILL.md
//    - upstream has no NOTICE file at the root or in the two skill folders
// 3. Write the release, the commit and the npm data to upstream/sources.json,
//    run sync-upstream.mjs pull for both skills (the transform makes the local
//    changes), and change the version values in README.md.
// 4. Write the files that publish-pr.sh reads to --out: title, message and
//    body.md, with a static report of what changed in the npm package. Also
//    version, the new npm version.
//
// Usage: node bump-mwg.mjs [--version X.Y.Z] [--cooldown DAYS] [--min-interval DAYS]
//          [--force] [--check-only] [--out DIR]
// --check-only runs the gates for the release and changes nothing.
// Exit status: 0 when done or when there is nothing to bump (then --out has
// no files), 1 when a gate fails or on an error, 2 on bad usage.

import { execFileSync } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pkg = "modern-web-guidance";
const repo = "GoogleChrome/modern-web-guidance";
const srcRepo = "https://github.com/GoogleChrome/modern-web-guidance-src";
const workflow = ".github/workflows/publish.yml";
const day = 24 * 60 * 60 * 1000;

const args = process.argv.slice(2);
const opt = { cooldown: 7, minInterval: 28, force: false, checkOnly: false, version: null, out: null };
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--version") opt.version = args[++i];
  else if (arg === "--cooldown") opt.cooldown = Number(args[++i]);
  else if (arg === "--min-interval") opt.minInterval = Number(args[++i]);
  else if (arg === "--force") opt.force = true;
  else if (arg === "--check-only") opt.checkOnly = true;
  else if (arg === "--out") opt.out = args[++i];
  else {
    console.error(`bump-mwg: unknown argument: ${arg}`);
    process.exit(2);
  }
}
if (!(opt.cooldown >= 3) || !(opt.minInterval >= 0) || (opt.version && !/^\d+\.\d+\.\d+$/.test(opt.version))) {
  console.error("bump-mwg: --cooldown must be 3 days or more, --version must be X.Y.Z");
  process.exit(2);
}

const run = (cmd, cmdArgs, options = {}) =>
  execFileSync(cmd, cmdArgs, { encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"], ...options });
const npmJson = (...npmArgs) => JSON.parse(run("npm", [...npmArgs, "--json"]) || "null");
const parse = (v) => v.split(".").map(Number);
const compare = (a, b) => {
  const [x, y] = [parse(a), parse(b)];
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
};
const work = mkdtempSync(join(tmpdir(), "bump-mwg-"));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

const sourcesPath = join(root, "upstream", "sources.json");
const sources = JSON.parse(readFileSync(sourcesPath, "utf-8"));
const mwg = sources[pkg];
const ext = sources["chrome-extensions"];
const current = mwg.npm.version;

// 1. The release.
const times = npmJson("view", pkg, "time");
const tags = new Map();
for (const line of run("git", ["ls-remote", "--tags", `https://github.com/${repo}.git`, "refs/tags/v*"]).split("\n")) {
  const [sha, ref] = line.split("\t");
  const match = /^refs\/tags\/v(\d+\.\d+\.\d+)(\^\{\})?$/.exec(ref ?? "");
  if (match && (match[2] || !tags.has(match[1]))) tags.set(match[1], sha);
}
const now = Date.now();
const age = (version) => (now - Date.parse(times[version])) / day;
let version = opt.version;
if (!version) {
  const ready = Object.keys(times)
    .filter((v) => /^\d+\.\d+\.\d+$/.test(v) && compare(v, current) > 0 && tags.has(v) && age(v) >= opt.cooldown)
    .sort(compare);
  version = ready.pop();
  if (!version) {
    console.log(`No release of ${pkg} after ${current} is ${opt.cooldown} days old and has a tag.`);
    process.exit(0);
  }
  if (!opt.force && age(current) < opt.minInterval) {
    console.log(`${version} is ready, but the pin ${current} is ${Math.floor(age(current))} days old. The bump waits until ${opt.minInterval} days. Use --force to bump now.`);
    process.exit(0);
  }
}
if (!times[version]) throw new Error(`npm has no ${pkg}@${version}`);
if (!tags.has(version)) throw new Error(`${repo} has no tag v${version}`);
if (age(version) < opt.cooldown) throw new Error(`${pkg}@${version} is ${age(version).toFixed(1)} days old, less than the cooldown of ${opt.cooldown} days`);
const commit = tags.get(version);
console.log(`Release: ${pkg}@${version}, v${version} = ${commit}, published ${times[version]}`);

// 2. Gates.
const gates = [];
const gate = (name, ok, detail) => {
  gates.push({ name, ok, detail });
  console.log(`${ok ? "ok  " : "FAIL"} ${name}: ${detail}`);
};

const meta = npmJson("view", `${pkg}@${version}`);
const deps = ["dependencies", "optionalDependencies", "peerDependencies", "bundleDependencies", "bundledDependencies"]
  .filter((key) => meta[key] && Object.keys(meta[key]).length > 0);
gate("no dependencies", deps.length === 0, deps.length ? `has ${deps.join(", ")}` : "none");
const scripts = Object.keys(meta.scripts ?? {});
gate("no scripts", scripts.length === 0, scripts.length ? `has ${scripts.join(", ")}` : "none");

function pack(v, dir) {
  mkdirSync(dir, { recursive: true });
  const [{ filename }] = JSON.parse(run("npm", ["pack", "--ignore-scripts", "--json", `${pkg}@${v}`], { cwd: dir }));
  const tgz = join(dir, filename);
  run("tar", ["-xzf", tgz, "-C", dir]);
  return { tgz, files: join(dir, "package") };
}
const next = pack(version, join(work, "new"));
const integrity = `sha512-${createHash("sha512").update(readFileSync(next.tgz)).digest("base64")}`;
gate("tarball integrity", integrity === meta.dist?.integrity, integrity === meta.dist?.integrity ? integrity : `npm gives ${meta.dist?.integrity}, the tarball has ${integrity}`);

const project = join(work, "audit");
mkdirSync(project);
writeFileSync(join(project, "package.json"), '{"name":"audit","version":"0.0.0","private":true}\n');
run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--save-exact", `${pkg}@${version}`], { cwd: project });
let audit;
try {
  audit = { ok: true, out: run("npm", ["audit", "signatures"], { cwd: project }) };
} catch (error) {
  audit = { ok: false, out: `${error.stdout}${error.stderr}` };
}
const verified = /1 package has a verified attestation/.test(audit.out) && /1 package has a verified registry signature/.test(audit.out);
gate("npm audit signatures", audit.ok && verified, audit.ok && verified ? "registry signature and attestation verified" : audit.out.trim().split("\n").join(" "));

const attestations = await (await fetch(meta.dist?.attestations?.url ?? "https://registry.npmjs.org/-/npm/v1/attestations/none")).json().catch(() => ({}));
const slsa = (attestations.attestations ?? []).find((a) => a.predicateType === "https://slsa.dev/provenance/v1");
let provenance = "no SLSA provenance";
let provenanceOk = false;
if (slsa) {
  const statement = JSON.parse(Buffer.from(slsa.bundle.dsseEnvelope.payload, "base64").toString("utf-8"));
  const subject = statement.subject?.[0];
  const digest = Buffer.from(integrity.slice(7), "base64").toString("hex");
  const flow = statement.predicate?.buildDefinition?.externalParameters?.workflow ?? {};
  const material = slsa.bundle.verificationMaterial ?? {};
  const raw = material.certificate?.rawBytes ?? material.x509CertificateChain?.certificates?.[0]?.rawBytes;
  const san = raw ? new X509Certificate(Buffer.from(raw, "base64")).subjectAltName ?? "" : "";
  const wantSan = `URI:${srcRepo}/${workflow}@`;
  const problems = [];
  if (subject?.name !== `pkg:npm/${pkg}@${version}`) problems.push(`subject ${subject?.name}`);
  if (subject?.digest?.sha512 !== digest) problems.push("subject digest is not the tarball");
  if (flow.repository !== srcRepo) problems.push(`repository ${flow.repository}`);
  if (flow.path !== workflow) problems.push(`workflow ${flow.path}`);
  if (!san.startsWith(wantSan)) problems.push(`certificate ${san || "missing"}`);
  provenanceOk = problems.length === 0;
  provenance = provenanceOk ? `${flow.repository} ${flow.path} ${flow.ref}` : problems.join(", ");
}
gate("provenance", provenanceOk, provenance);

const rawUrl = (path) => `https://raw.githubusercontent.com/${repo}/${commit}/${path}`;
const upstreamSkill = await (await fetch(rawUrl("skills/modern-web-guidance/SKILL.md"))).text();
const wanted = /--skill-version (\S+)/.exec(upstreamSkill)?.[1];
const shipped = readFileSync(join(next.files, "skills", "modern-web-guidance", "skill-version.txt"), "utf-8").trim();
gate("skill version", Boolean(wanted) && wanted === shipped, `SKILL.md ${wanted}, tarball ${shipped}`);

// Only the trees: a blob-free fetch of the commit lists every path.
const tree = join(work, "tree");
run("git", ["init", "-q", tree]);
run("git", ["-C", tree, "fetch", "-q", "--depth", "1", "--filter=blob:none", `https://github.com/${repo}.git`, commit]);
const paths = run("git", ["-C", tree, "ls-tree", "-r", "--name-only", commit]).split("\n").filter(Boolean);
const notices = paths.filter((p) => /^(skills\/(modern-web-guidance|chrome-extensions)\/)?NOTICE[^/]*$/i.test(p));
gate("no upstream NOTICE", notices.length === 0, notices.length ? notices.join(", ") : "none");

const failed = gates.filter((g) => !g.ok);
const gateTable = ["| Gate | Result |", "| --- | --- |", ...gates.map((g) => `| ${g.name} | ${g.ok ? "ok" : "FAIL"}: ${g.detail.replaceAll("|", "\\|")} |`)].join("\n");
if (failed.length > 0) {
  console.error(`bump-mwg: ${failed.length} gate(s) failed. Do not bump to ${version}.`);
  process.exit(1);
}
if (opt.checkOnly) process.exit(0);

// 3. The change.
const old = { version: current, commit: mwg.commit, integrity: mwg.npm.integrity, skillVersion: /--skill-version (\S+)/.exec(readFileSync(join(root, "plugins", pkg, "skills", pkg, "SKILL.md"), "utf-8"))?.[1] };
// README values. Each must be found, so a reworded README fails here.
const readmePath = join(root, "README.md");
let readme = readFileSync(readmePath, "utf-8");
const skillDate = (value) => /^(\d{4})_(\d\d)_(\d\d)/.exec(value ?? "");
const [, y, m, d] = skillDate(wanted) ?? [];
const until = new Date(Date.UTC(Number(y), Number(m) - 1, Number(d)) + 60 * day).toISOString().slice(0, 10);
const replacements = [
  [new RegExp(`(\\| \`(?:modern-web-guidance|chrome-extensions)\` \\|.*\\| )\`${old.commit.slice(0, 7)}\``, "g"), `$1\`${commit.slice(0, 7)}\``, "the commit in the skills table"],
  [new RegExp(old.integrity.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&"), "g"), integrity, "the npm integrity"],
  [new RegExp(`(For\\s+)${old.version.replaceAll(".", "\\.")}(,\\s+the\\s+skill\\s+version\\s+starts\\s+with\\s+)\`\\d{4}_\\d\\d_\\d\\d\`(,\\s+so\\s+update\\s+before\\s+)\\d{4}-\\d\\d-\\d\\d`, "g"), `$1${version}$2\`${y}_${m}_${d}\`$3${until}`, "the 60-day sentence"],
  [new RegExp(`(?<=modern-web-guidance@|version\\s+|\`@|integrity\\s+of\\s+)${old.version.replaceAll(".", "\\.")}\\b`, "g"), version, "the pinned version"],
];
for (const [pattern, value, what] of replacements) {
  if (!pattern.test(readme)) throw new Error(`README.md: cannot find ${what}. Change it by hand and fix bump-mwg.mjs.`);
  pattern.lastIndex = 0;
  readme = readme.replace(pattern, value);
}
const extPrefix = "skills/chrome-extensions/";
const extFiles = paths.filter((p) => p.startsWith(extPrefix)).map((p) => p.slice(extPrefix.length)).sort();
const extAdded = extFiles.filter((f) => !ext.files.includes(f));
const extRemoved = ext.files.filter((f) => !extFiles.includes(f));
sources[pkg] = { ...mwg, release: `v${version}`, npm: { ...mwg.npm, version, integrity, published: times[version] } };
sources["chrome-extensions"] = { ...ext, release: `v${version}`, files: extFiles };
writeFileSync(sourcesPath, `${JSON.stringify(sources, null, 2)}\n`);
writeFileSync(readmePath, readme);
for (const name of [pkg, "chrome-extensions"]) {
  execFileSync("node", [join(root, "scripts", "sync-upstream.mjs"), "pull", name, commit], { stdio: ["ignore", "ignore", "inherit"] });
}

// 4. The report and the texts.
const previous = pack(old.version, join(work, "old"));
function list(dir) {
  const out = new Map();
  const walk = (d) => {
    for (const name of readdirSync(d)) {
      const full = join(d, name);
      if (statSync(full).isDirectory()) walk(full);
      else out.set(relative(dir, full), readFileSync(full));
    }
  };
  walk(dir);
  return out;
}
const a = list(previous.files);
const b = list(next.files);
const sha = (buf) => createHash("sha256").update(buf).digest("hex");
const added = [...b.keys()].filter((f) => !a.has(f)).sort();
const removed = [...a.keys()].filter((f) => !b.has(f)).sort();
const changed = [...b.keys()].filter((f) => a.has(f) && sha(a.get(f)) !== sha(b.get(f))).sort();
const size = (m) => [...m.values()].reduce((sum, buf) => sum + buf.length, 0);
const code = (f) => /\.(c|m)?js$/.test(f);
const hosts = (m) => {
  const found = new Set();
  for (const [f, buf] of m) if (code(f)) for (const match of buf.toString("utf-8").matchAll(/https?:\/\/([a-z0-9.-]+)/gi)) found.add(match[1].toLowerCase());
  return found;
};
const [hostsA, hostsB] = [hosts(a), hosts(b)];
const newHosts = [...hostsB].filter((h) => !hostsA.has(h)).sort();
const patterns = ["child_process", "spawn(", "exec(", "execSync(", "execFile", "fork(", "fetch(", "http.request", "https.request", "net.connect", "WebSocket", "XMLHttpRequest", "telemetry", "process.env"];
const count = (m, p) => [...m].filter(([f]) => code(f)).reduce((sum, [, buf]) => sum + buf.toString("utf-8").split(p).length - 1, 0);
const grew = patterns.map((p) => [p, count(a, p), count(b, p)]).filter(([, x, y2]) => y2 !== x);
const kb = (n) => `${(n / 1024).toFixed(1)} KiB`;
const fileLine = (label, files) => (files.length ? `- ${label} (${files.length}): ${files.slice(0, 30).map((f) => `\`${f}\``).join(", ")}${files.length > 30 ? ", …" : ""}` : `- ${label}: none`);
const report = [
  `Package ${pkg} ${old.version} → ${version}. Unpacked size ${kb(size(a))} → ${kb(size(b))} (${size(b) >= size(a) ? "+" : ""}${kb(size(b) - size(a))}). Files ${a.size} → ${b.size}.`,
  "",
  fileLine("Added", added),
  fileLine("Removed", removed),
  fileLine("Changed", changed.filter(code)),
  `- Changed files that are not code: ${changed.filter((f) => !code(f)).length}`,
  `- New hosts in code: ${newHosts.length ? newHosts.map((h) => `\`${h}\``).join(", ") : "none"}`,
  "",
  "| Pattern in code | Before | After |",
  "| --- | --- | --- |",
  ...(grew.length ? grew.map(([p, x, y2]) => `| \`${p}\` | ${x} | ${y2} |`) : ["| no change in any pattern | | |"]),
].join("\n");

if (opt.out) {
  mkdirSync(opt.out, { recursive: true });
  const title = `chore: update modern-web-guidance to v${version}`;
  writeFileSync(join(opt.out, "title"), `${title}\n`);
  writeFileSync(join(opt.out, "version"), `${version}\n`);
  writeFileSync(
    join(opt.out, "message"),
    [
      title,
      "",
      `Update the modern-web-guidance and chrome-extensions skills from`,
      `${repo} v${old.version} to v${version} (${commit.slice(0, 12)}).`,
      `The npm package passed the static gates of scripts/bump-mwg.mjs.`,
      extAdded.length || extRemoved.length ? `\nchrome-extensions files: ${extAdded.length} added, ${extRemoved.length} removed.` : "",
    ].join("\n").trim() + "\n",
  );
  writeFileSync(
    join(opt.out, "body.md"),
    `### Description
Update \`modern-web-guidance\` and \`chrome-extensions\` from [v${old.version}](https://github.com/${repo}/releases/tag/v${old.version}) to [v${version}](https://github.com/${repo}/releases/tag/v${version}) (\`${commit.slice(0, 12)}\`, [diff](https://github.com/${repo}/compare/${old.commit.slice(0, 12)}...${commit.slice(0, 12)})). npm published ${version} on ${times[version].slice(0, 10)}, ${Math.floor(age(version))} days ago. The skill version is \`${wanted}\`, so the 60-day limit is ${until}.

The transform \`upstream/transforms/modern-web-guidance.mjs\` made the local changes. chrome-extensions files: ${extAdded.length} added${extAdded.length ? ` (${extAdded.map((f) => `\`${f}\``).join(", ")})` : ""}, ${extRemoved.length} removed${extRemoved.length ? ` (${extRemoved.map((f) => `\`${f}\``).join(", ")})` : ""}.

Read the SKILL.md diff and the package report below before you merge. After the merge, the tag workflow makes the next patch release, and the release starts the update pull requests in the consumers.

### Referenced Issue
None.

### Type of Change
- [ ] Bug fix
- [ ] New feature / Infrastructure addition
- [ ] Documentation update

None of these: this is a dependency update.

### Breaking Changes
- [x] **No**, this change is fully backwards-compatible and safe to deploy independently.
- [ ] **Yes**, this change requires downstream updates, manual intervention, or downtime (explain below).

### Validation
Static gates on the npm package. The bot did not run the package.

${gateTable}

The workflow then ran \`check-repo.mjs\`, \`sync-upstream.mjs verify\` and \`self-test.sh\`, and CI runs them again on this pull request.

### Additional Context / Visuals
${report}
`,
  );
}
console.log(report);
