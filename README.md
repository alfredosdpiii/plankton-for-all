# Plankton

Plankton is a Pi-exclusive code-quality extension. It runs project-local bash
hooks through a safe TypeScript extension, blocks protected linter config edits,
enforces package-manager choices, and reports lint feedback after file writes.

## What is included

- Project extension: `.pi/extensions/plankton/`
- Runtime hooks: `.plankton/hooks/`
- Hook tests and fixtures: `.plankton/test/`
- Configuration: `.plankton/config.json`
- Optional subprocess isolation settings: `.plankton/subprocess-settings.json`

Pi is the only supported agent target. Other agent adapters have been removed.

## Quick start

```bash
bash scripts/setup.sh
pi
```

For another project:

```bash
bash /path/to/plankton-for-all/scripts/install-plankton.sh /path/to/project
cd /path/to/project
pi
```

## Pi extension behavior

The extension discovers `.plankton/config.json` by walking upward from Pi's
current working directory. If no config is found, it stays in no-op mode.

During Pi tool execution:

- `write` / `edit` preflight runs `protect_linter_configs.sh`.
- `bash` preflight runs `enforce_package_managers.sh`.
- Successful `write` / `edit` results run `multi_linter.sh`.
- Hook processes run in their own POSIX process group and are terminated as a
  group on timeout or abort.
- Project hooks are preferred; bundled hooks in the extension are the fallback.

## Commands

Use these Pi slash commands:

```text
/plankton-status          Show config, hook paths, package managers, stats
/plankton-lint <file>     Run linting manually for one file
/plankton-toggle <lang>   Toggle a language in .plankton/config.json
```

## Tools

The extension registers two LLM-callable tools:

- `plankton_lint({ path })` returns a compact summary and `systemMessage`.
- `plankton_config({ action, key, value })` safely reads or updates whitelisted
  configuration keys.

## Configuration

`.plankton/config.json` controls language toggles, protected files, subprocess
settings, duplication thresholds, and package-manager enforcement.

Important defaults:

```json
{
  "tested_version": "2.1.50",
  "subprocess": {
    "settings_file": ".plankton/subprocess-settings.json",
    "delegate_cmd": "pi"
  },
  "package_managers": {
    "python": "uv",
    "javascript": "bun"
  }
}
```

Legacy delegate values are coerced at read time: `auto` and removed agent names
become `pi`; unknown values become `none`.

## Verification

```bash
bunx tsc --project tsconfig.extensions.json
bash .plankton/test/test_hook.sh --self-test
uv run pytest
```

Useful direct hook checks:

```bash
printf '%s' '{"tool_input":{"file_path":".ruff.toml"}}' \
  | PLANKTON_PROJECT_DIR="$PWD" bash .plankton/hooks/protect_linter_configs.sh

printf '%s' '{"tool_input":{"command":"pip install requests"}}' \
  | PLANKTON_PROJECT_DIR="$PWD" bash .plankton/hooks/enforce_package_managers.sh
```

## Global install

Copy the extension directory into Pi's global extension directory:

```bash
mkdir -p ~/.pi/agent/extensions
cp -a .pi/extensions/plankton ~/.pi/agent/extensions/plankton
pi
```

The bundled hooks allow the global extension to operate in projects that have a
`.plankton/config.json` but no project-local `.plankton/hooks/` directory.
