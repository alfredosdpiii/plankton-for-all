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
loose_dir="${tmp_dir}/loose"
mkdir -p "${nested_dir}" "${loose_dir}"
printf '{"name":"plankton-auto-init-fixture"}\n' >"${fixture_root}/package.json"

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

const [, , modulePath, fixtureRoot, nestedDir, looseDir] = process.argv;
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

const rawConfig = JSON.parse(await readFile(configPath, "utf8"));
assert(rawConfig.languages?.typescript?.semgrep === true, "default TypeScript semgrep should be enabled");
assert(rawConfig.languages?.elixir?.credo === true, "default Elixir Credo should be enabled");
assert(rawConfig.subprocess?.delegate_cmd === "pi", "default delegate should be pi");

const { config } = await mod.loadPlanktonConfig(initialized);
assert(config.subprocess?.settings_file === ".plankton/subprocess-settings.json", "config loader should preserve settings file");

mod.clearContextCache();
const existing = await mod.resolvePlanktonContext(nestedDir);
assert(existing.noOp === false, "existing config should stay active");
assert(existing.initialized === false, "existing config should not be marked newly initialized");

mod.clearContextCache();
const loose = await mod.resolvePlanktonContext(looseDir);
assert(loose.noOp === true, "directory without project markers should stay inactive");
assert(!(await exists(join(looseDir, ".plankton"))), "loose directory should not get .plankton");

console.log("PASS auto-init creates .plankton only for recognized projects");
EOF

bun "${runner}" \
  "${PROJECT_DIR}/.pi/extensions/plankton/config.ts" \
  "${fixture_root}" \
  "${nested_dir}" \
  "${loose_dir}"
