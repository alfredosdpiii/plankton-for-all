#!/usr/bin/env bash
# install-plankton.sh - Install Plankton linting enforcement into a Pi project.
#
# Usage:
#   bash /path/to/plankton-for-all/scripts/install-plankton.sh /path/to/target-project
#   bash /path/to/plankton-for-all/scripts/install-plankton.sh .

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANKTON_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${1:-.}"

if [[ ! -d "${TARGET}" ]]; then
  echo "error: target directory does not exist: ${TARGET}" >&2
  echo "usage: $0 /path/to/target-project" >&2
  exit 1
fi

TARGET="$(cd "${TARGET}" && pwd)"

if [[ "${TARGET}" == "${PLANKTON_ROOT}" ]]; then
  echo "error: target is the plankton source repo itself" >&2
  exit 1
fi

echo "Installing Plankton into: ${TARGET}"
echo "Source: ${PLANKTON_ROOT}"
echo ""

mkdir -p "${TARGET}/.pi/extensions" "${TARGET}/.plankton/hooks" "${TARGET}/.plankton/test"

cp -a "${PLANKTON_ROOT}/.pi/extensions/plankton" "${TARGET}/.pi/extensions/"
echo "  .pi/extensions/plankton/"

for hook in multi_linter.sh protect_linter_configs.sh enforce_package_managers.sh; do
  cp "${PLANKTON_ROOT}/.plankton/hooks/${hook}" "${TARGET}/.plankton/hooks/${hook}"
  chmod +x "${TARGET}/.plankton/hooks/${hook}"
  echo "  .plankton/hooks/${hook}"
done

cp -a "${PLANKTON_ROOT}/.plankton/test/." "${TARGET}/.plankton/test/"
chmod +x "${TARGET}/.plankton/test"/*.sh 2>/dev/null || true
echo "  .plankton/test/"

CONFIG_FILE="${TARGET}/.plankton/config.json"
if [[ -f "${CONFIG_FILE}" ]]; then
  echo "  .plankton/config.json already exists (skipped)"
else
  cp "${PLANKTON_ROOT}/.plankton/config.json" "${CONFIG_FILE}"
  echo "  .plankton/config.json"
fi

AGENTS_FILE="${TARGET}/.pi/AGENTS.md"
PLANKTON_MARKER="# Plankton Linting Agent"
read -r -d '' PLANKTON_AGENTS_CONTENT <<'EOF' || true
# Plankton Linting Agent

This project uses Plankton for Pi-native multi-language linting. The extension at
`.pi/extensions/plankton/` runs linting hooks after file edits and blocks
modifications to protected config files.

- Fix code issues reported by Plankton instead of weakening linter configs.
- Use `uv` for Python package work.
- Use `bun` for JavaScript package work.
- Configuration lives in `.plankton/config.json`.

## Elixir/Phoenix enforcement

Phoenix projects get additional checks beyond `mix format`:

- **Credo** (`credo: true`): Static code analysis for consistency, design,
  readability, and refactoring opportunities. Runs per file.
- **Sobelow** (`sobelow: true`): Phoenix-specific security scanner. Catches XSS,
  SQL injection, CSRF bypass, hardcoded secrets, directory traversal. Runs once
  per session on first Elixir file edit (project-level scan).
- **Compile warnings** (`mix_compile_warnings: false`): Runs `mix compile
  --warnings-as-errors`. Catches unused variables, missing functions, deprecated
  calls. Off by default (can be slow on large projects).

Elixir config is structured like TypeScript:
```json
"elixir": {
  "enabled": true,
  "credo": true,
  "sobelow": true,
  "mix_compile_warnings": false
}
```
EOF

if [[ -f "${AGENTS_FILE}" ]]; then
  if grep -qF "${PLANKTON_MARKER}" "${AGENTS_FILE}"; then
    echo "  .pi/AGENTS.md already has Plankton section (skipped)"
  else
    printf '\n\n%s\n' "${PLANKTON_AGENTS_CONTENT}" >>"${AGENTS_FILE}"
    echo "  .pi/AGENTS.md (appended Plankton section)"
  fi
else
  mkdir -p "$(dirname "${AGENTS_FILE}")"
  printf '%s\n' "${PLANKTON_AGENTS_CONTENT}" >"${AGENTS_FILE}"
  echo "  .pi/AGENTS.md (created)"
fi

echo ""
echo "Checking core tools:"
for tool in jaq uv ruff bun; do
  if command -v "${tool}" >/dev/null 2>&1; then
    echo "  ok ${tool}"
  else
    echo "  missing ${tool}"
  fi
done

echo ""
echo "Done. Run 'pi' from the target project. Test with: bash .plankton/test/test_hook.sh --self-test"
