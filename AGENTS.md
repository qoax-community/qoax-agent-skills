# Agents

- Write prose with the `asd-ste100` skill in
  `plugins/asd-ste100/skills/asd-ste100`. Keep British spelling.
- Do not edit third-party skill files by hand. Use `scripts/sync-upstream.mjs`
  and put local changes in `upstream/patches/`.
- Each skill folder must have a `LICENSE` file. Do not add symbolic links under
  `plugins/`, because the skills CLI hash skips them.
- Do not add a `version` to the plugin manifests, so that users get each new
  commit.
- Before you open a pull request, run `node scripts/check-repo.mjs`,
  `node scripts/sync-upstream.mjs verify` and `sh scripts/self-test.sh`.
- Run `sh scripts/setup-hooks.sh` once after a clone.
