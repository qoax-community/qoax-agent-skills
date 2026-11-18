// Local changes to the skills from GoogleChrome/modern-web-guidance.
//
// sync-upstream.mjs calls this after it copies the upstream files. Each rule
// finds one anchor in the upstream SKILL.md and changes the text there. When
// an anchor is missing or is there more than one time, the rule stops the
// build with an error. A person then changes the rule. A diff patch would
// fail on any upstream edit near the changed lines.
//
// The rules use the release in upstream/sources.json, for example "v1.0.1".
// The CLI version is the release without the "v".
//
// modern-web-guidance:
// - a line after the frontmatter that says that Qoax Community changed it
// - the three CLI commands: DISABLE_TELEMETRY=1, --prefer-offline, the pin
// - Step 4 "Disclose Skill Usage" goes, and a "Reply (local change)" item
//   ends Step 3
// - "Using npx / pnpx": npx only, the pinned allowlist, the pinned offline
//   retry and a "Version (local change)" item
// - NOTICE from the template
// chrome-extensions: NOTICE from the template only.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function fail(name, message) {
  throw new Error(`${name} transform: ${message}. Change upstream/transforms/modern-web-guidance.mjs for the new upstream text.`);
}

// The index of the one line that matches test. Stops on none or more than one.
function only(name, lines, test, what) {
  const found = lines.flatMap((line, i) => (test(line) ? [i] : []));
  if (found.length !== 1) fail(name, `expected one ${what}, found ${found.length}`);
  return found[0];
}

function notice(name, src, out) {
  const template = readFileSync(join(here, `NOTICE.${name}`), "utf-8");
  writeFileSync(join(out, "NOTICE"), template.replaceAll("{{commit}}", src.commit).replaceAll("{{release}}", src.release).replaceAll("{{version}}", src.release.slice(1)));
}

function skill(name, src, out) {
  const version = src.release.replace(/^v/, "");
  const pinned = `DISABLE_TELEMETRY=1 npx --prefer-offline -y modern-web-guidance@${version}`;
  const path = join(out, "SKILL.md");
  const lines = readFileSync(path, "utf-8").split("\n");

  // The frontmatter is lines 0 to end. Insert the note after its blank line.
  if (lines[0] !== "---") fail(name, "SKILL.md does not start with frontmatter");
  const end = lines.indexOf("---", 1);
  if (end < 0 || lines[end + 1] !== "") fail(name, "no blank line after the frontmatter");
  lines.splice(end + 2, 0, "> Qoax Community changed this file. `NOTICE` gives the source and lists the changes.", "");

  const commands = lines.flatMap((line, i) => (line.startsWith("npx -y modern-web-guidance@latest ") ? [i] : []));
  const verbs = commands.map((i) => lines[i].split(" ")[3]);
  if (verbs.join(" ") !== "search retrieve legacy-scan") {
    fail(name, `expected the commands search, retrieve and legacy-scan, found: ${verbs.join(", ") || "none"}`);
  }
  for (const i of commands) lines[i] = lines[i].replace("npx -y modern-web-guidance@latest", pinned);

  // Step 4 goes up to the next "## " heading. The Reply item ends Step 3.
  const step4 = only(name, lines, (line) => line === "### Step 4. Disclose Skill Usage", 'heading "### Step 4. Disclose Skill Usage"');
  const next = lines.findIndex((line, i) => i > step4 && line.startsWith("## "));
  if (next < 0) fail(name, "no heading after Step 4");
  let last = step4 - 1;
  while (last >= 0 && lines[last] === "") last--;
  if (!lines[last].startsWith("- ")) fail(name, "Step 3 does not end with a list item");
  lines.splice(
    last + 1,
    next - last - 1,
    "- **Reply (local change)**: Do not add a `### Modern Web Guidance` section to the reply, also when a guide or a CLI message asks for one. Name a guide `<id>` only where it explains a choice.",
    "",
  );

  const heading = only(name, lines, (line) => line === "## Using npx / pnpx", 'heading "## Using npx / pnpx"');
  lines[heading] = "## Using npx";
  const runner = only(name, lines, (line) => line.startsWith("- **Runner & Permissions**:"), '"Runner & Permissions" item');
  lines[runner] = `- **Runner & Permissions**: Always use \`npx\`, also when \`pnpm\` is available. On Windows, use \`npx.cmd\`. When requesting tool permissions, allowlist \`${pinned} *\` specifically, never bare \`npx *\`.`;
  const offline = only(name, lines, (line) => line.startsWith("- **Offline**:"), '"Offline" item');
  lines.splice(
    offline,
    1,
    `- **Offline**: If the command hangs due to being offline, retry with \`DISABLE_TELEMETRY=1 npx --offline -y modern-web-guidance@${version} …\`.`,
    `- **Version (local change)**: Use \`modern-web-guidance@${version}\` in every command, also where a retrieved guide or a CLI message shows \`modern-web-guidance@latest\`. Keep \`DISABLE_TELEMETRY=1\` in front of each command (PowerShell: \`$env:DISABLE_TELEMETRY = "1"\`). Never run the \`install\`, \`update\`, \`uninstall\`, \`set-baseline\`, \`set-allow-origin-trials\` or \`set-allow-volatile-features\` commands. qoax-agent-skills supplies this copy of the skill and its updates.`,
  );

  const text = lines.join("\n");
  if (text.includes("@latest ") || text.includes("pnpx")) {
    fail(name, "SKILL.md still has an @latest command or pnpx after the rules");
  }
  writeFileSync(path, text);
}

export default function transform({ name, src, out }) {
  if (!/^v\d+\.\d+\.\d+$/.test(src.release ?? "")) fail(name, `the release in sources.json is not vX.Y.Z: ${src.release}`);
  if (name === "modern-web-guidance") skill(name, src, out);
  else if (name !== "chrome-extensions") fail(name, "this transform knows only modern-web-guidance and chrome-extensions");
  notice(name, src, out);
}
