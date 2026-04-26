#!/bin/bash
# test_auto_init.sh - Regression tests for automatic .plankton initialization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

if ! command -v bun >/dev/null 2>&1; then
  echo "[skip] bun not installed - skipping auto-init TypeScript test"
  exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

fixture_root="${tmp_dir}/project"
nested_dir="${fixture_root}/apps/demo"
custom_root="${tmp_dir}/project-custom-hook"
custom_nested_dir="${custom_root}/apps/demo"
loose_dir="${tmp_dir}/loose"
mkdir -p "${nested_dir}" "${custom_nested_dir}" "${loose_dir}" "${fixture_root}/.git/hooks" "${custom_root}/.git/hooks"
printf '{"name":"plankton-auto-init-fixture"}\n' >"${fixture_root}/package.json"
printf '{"name":"plankton-custom-hook-fixture"}\n' >"${custom_root}/package.json"
printf '#!/usr/bin/env bash\necho custom-pre-commit\n' >"${custom_root}/.git/hooks/pre-commit"
chmod +x "${custom_root}/.git/hooks/pre-commit"

runner="${tmp_dir}/test-auto-init.mjs"
cat >"${runner}" <<'EOF'
import { access, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const [, , modulePath, fixtureRoot, nestedDir, customRoot, customNestedDir, looseDir] = process.argv;
const mod = await import(pathToFileURL(modulePath).href);

mod.clearContextCache();
const initialized = await mod.resolvePlanktonContext(nestedDir);
assert(initialized.noOp === false, "project marker should enable Plankton");
assert(initialized.initialized === true, "first lookup should auto-initialize");
assert(initialized.root === resolve(fixtureRoot), `expected root ${fixtureRoot}, got ${initialized.root}`);
assert(initialized.configPath === join(resolve(fixtureRoot), ".plankton", "config.json"), "config path should be project-local");

const configPath = join(fixtureRoot, ".plankton", "config.json");
const settingsPath = join(fixtureRoot, ".plankton", "subprocess-settings.json");
const hooksDir = join(fixtureRoot, ".plankton", "hooks");
assert(await exists(configPath), "config.json should be written");
assert(await exists(settingsPath), "subprocess-settings.json should be written");
assert(await exists(join(hooksDir, "multi_linter.sh")), "multi_linter hook should be copied");
assert(await exists(join(hooksDir, "protect_linter_configs.sh")), "protect hook should be copied");
assert(await exists(join(hooksDir, "enforce_package_managers.sh")), "package-manager hook should be copied");
assert(await exists(join(hooksDir, "git_pre_commit.sh")), "Git pre-commit runner should be copied");
assert(await exists(join(hooksDir, "git_commit_msg.sh")), "Git commit-msg runner should be copied");

const preCommitHook = join(fixtureRoot, ".git", "hooks", "pre-commit");
const commitMsgHook = join(fixtureRoot, ".git", "hooks", "commit-msg");
assert(await exists(preCommitHook), "Git pre-commit wrapper should be installed");
assert(await exists(commitMsgHook), "Git commit-msg wrapper should be installed");
assert((await readFile(preCommitHook, "utf8")).includes("Plankton-managed Git hook"), "pre-commit wrapper should be Plankton-managed");
assert((await readFile(commitMsgHook, "utf8")).includes("Plankton-managed Git hook"), "commit-msg wrapper should be Plankton-managed");
assert(initialized.gitHooksInstalled?.includes("pre-commit"), "context should report pre-commit hook installation");
assert(initialized.gitHooksInstalled?.includes("commit-msg"), "context should report commit-msg hook installation");

const rawConfig = JSON.parse(await readFile(configPath, "utf8"));
assert(rawConfig.languages?.typescript?.semgrep === true, "default TypeScript semgrep should be enabled");
assert(rawConfig.languages?.elixir?.credo === true, "default Elixir Credo should be enabled");
assert(rawConfig.subprocess?.delegate_cmd === "pi", "default delegate should be pi");
assert(rawConfig.subprocess?.correction_model === "gpt-5.4-mini", "default correction model should be configured");

const { config } = await mod.loadPlanktonConfig(initialized);
assert(config.subprocess?.settings_file === ".plankton/subprocess-settings.json", "config loader should preserve settings file");

mod.clearContextCache();
const existing = await mod.resolvePlanktonContext(nestedDir);
assert(existing.noOp === false, "existing config should stay active");
assert(existing.initialized === false, "existing config should not be marked newly initialized");

mod.clearContextCache();
const custom = await mod.resolvePlanktonContext(customNestedDir);
assert(custom.initialized === true, "custom-hook fixture should auto-initialize");
assert(custom.gitHooksSkipped?.includes("pre-commit"), "existing custom pre-commit should be reported as skipped");
assert(custom.gitHooksInstalled?.includes("commit-msg"), "missing commit-msg should still be installed");
const customPreCommit = await readFile(join(customRoot, ".git", "hooks", "pre-commit"), "utf8");
assert(customPreCommit.includes("custom-pre-commit"), "existing custom pre-commit should not be overwritten");

mod.clearContextCache();
const loose = await mod.resolvePlanktonContext(looseDir);
assert(loose.noOp === true, "directory without project markers should stay inactive");
assert(!(await exists(join(looseDir, ".plankton"))), "loose directory should not get .plankton");

console.log("PASS auto-init creates .plankton and Git hooks only for recognized projects");
EOF

bun "${runner}" \
  "${PROJECT_DIR}/.pi/extensions/plankton/config.ts" \
  "${fixture_root}" \
  "${nested_dir}" \
  "${custom_root}" \
  "${custom_nested_dir}" \
  "${loose_dir}"
