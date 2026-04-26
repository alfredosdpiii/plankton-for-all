# Plankton for All

Plankton for All is a fork of the original
[`alexfazio/plankton`](https://github.com/alexfazio/plankton) project. The
original proved the useful idea: Pi can enforce code quality from inside the
agent loop. This fork keeps that idea, but changes the product direction toward
a Pi-first package that can bootstrap itself in any project and keep runtime
linting, Git hooks, and correction subprocesses consistent.

This is not the upstream `alexfazio/plankton` repository. It is a maintained fork
for the `alfredosdpiii/plankton-for-all` workflow.

## Why this fork exists

We forked because the workflow needed more than a checked-in project hook setup:

- Installable Pi package metadata for `pi install` and project-local installs.
- Automatic `.plankton/` initialization in projects that do not already have it.
- Managed Git `pre-commit` and `commit-msg` hooks for commit-time enforcement.
- Pi-only subprocess delegation with a configurable correction model.
- Package-manager guardrails (`uv` for Python, `bun` for JavaScript).
- False-preserving config reads so explicit `false` toggles stay disabled.
- Elixir/Phoenix coverage, including Credo, Sobelow, compile warnings,
  dependency audit, xref warnings, and LiveView pattern checks.
- Regression tests for hook behavior, auto-init, Git hooks, package metadata,
  and config toggles.

## What it does

Plankton is a Pi extension that runs local Bash hooks around Pi tool calls:

- Before `write` and `edit`, it blocks edits to protected linter config files.
- Before `bash`, it blocks disallowed package-manager commands.
- After successful `write` and `edit`, it lints the changed file.
- When violations remain, it can ask a Pi correction subprocess to fix them.
- It reports lint feedback directly in the tool result.

The extension prefers project-local hooks in `.plankton/hooks/`. If a project
has only the package extension, bundled hooks from `.pi/extensions/plankton/hooks/`
are used as the fallback.

## Install as a Pi package

Install globally for all Pi sessions:

```bash
pi install git:github.com/alfredosdpiii/plankton-for-all
```

Install for one project and commit `.pi/settings.json` for a team:

```bash
pi install -l git:github.com/alfredosdpiii/plankton-for-all
```

Try a local checkout without adding it to settings:

```bash
pi -e /path/to/plankton-for-all
```

The package manifest lives in `package.json` under `pi.extensions`. The package
contains the TypeScript extension plus bundled hook scripts.

## Repository-local install

To copy this checkout directly into another project:

```bash
bash /path/to/plankton-for-all/scripts/install-plankton.sh /path/to/project
cd /path/to/project
pi
```

For this repository's own development tools:

```bash
bash scripts/setup.sh
```

`scripts/setup.sh` installs common local lint binaries such as `jaq`, `ruff`,
`uv`, `shellcheck`, `shfmt`, `hadolint`, `taplo`, and `bun` when missing.

## Auto initialization

When the extension starts in a recognizable project without `.plankton/`, it
creates a project-local setup:

- `.plankton/config.json`
- `.plankton/hooks/*.sh`
- `.plankton/subprocess-settings.json`
- `.git/hooks/pre-commit` and `.git/hooks/commit-msg` when the project is a Git
  repository and those hooks are absent or already Plankton-managed

Recognized project markers include `.git`, `package.json`, `pyproject.toml`,
`uv.lock`, `mix.exs`, `Cargo.toml`, `go.mod`, `deno.json`, `bun.lock`,
`pnpm-lock.yaml`, `yarn.lock`, and `package-lock.json`.

Plankton does not overwrite existing custom Git hooks. Set
`PLANKTON_GIT_HOOKS=0` to bypass managed Git hooks temporarily.

## Commands

Use these Pi slash commands:

```text
/plankton-status                       Show config, hooks, package managers, stats
/plankton-lint <file>                  Run linting manually for one file
/plankton-toggle <lang>                Toggle a language in .plankton/config.json
/plankton-correction <provider/model>  Set the correction subprocess model
```

Example:

```text
/plankton-correction gpt-5.4-mini
```

## LLM-callable tools

The extension registers these tools for the assistant:

- `plankton_lint({ path })`: run linting for one project file and return a
  compact summary.
- `plankton_config({ action, key, value })`: safely read or update whitelisted
  config keys. The `correction_model` key maps to
  `subprocess.correction_model`.

## Configuration

The main config file is `.plankton/config.json`.

Important defaults in this fork:

```json
{
  "tested_version": "2.1.50",
  "subprocess": {
    "settings_file": ".plankton/subprocess-settings.json",
    "delegate_cmd": "pi",
    "correction_model": "gpt-5.4-mini"
  },
  "package_managers": {
    "python": "uv",
    "javascript": "bun"
  }
}
```

`subprocess.correction_model` is passed to Pi as `--model` for automatic
correction subprocesses. Set it to any model string Pi accepts. If it is omitted,
Plankton falls back to tiered model selection. The older
`subprocess.global_model_override` key is still honored as a fallback.

The environment variable `PLANKTON_CORRECTION_MODEL` overrides config for one
run.

Legacy delegate values are normalized at read time: `auto` and removed agent
names become `pi`; unknown values become `none`.

## Language coverage

Current hook coverage includes:

- Python: ruff, ty, flake8-async, flake8-pydantic, vulture, bandit.
- TypeScript/JavaScript/CSS: Biome, Semgrep, optional project-scoped tools.
- Elixir/Phoenix: mix format, Credo, Sobelow, compile warnings, deps audit,
  xref warnings, LiveView pattern checks.
- Shell: shellcheck and shfmt.
- YAML, JSON, TOML, Dockerfile, and Markdown checks.

Many tools are fail-open when the binary is not installed, so a project can start
with only core dependencies and add language-specific tools over time.

## Git hooks

Auto-init and `scripts/install-plankton.sh` install managed Git hooks when safe:

- `pre-commit` runs deterministic Plankton checks on staged files.
- `commit-msg` blocks AI attribution boilerplate such as `Co-Authored-By`,
  `generated by`, or `AI assistant`.

The managed hooks delegate to `.plankton/hooks/git_pre_commit.sh` and
`.plankton/hooks/git_commit_msg.sh`.

## Verification

Run the main verification suite:

```bash
bun run test
```

Equivalent expanded commands:

```bash
bunx tsc --noEmit
bash .plankton/test/test_auto_init.sh
bash .plankton/test/test_hook.sh --self-test
uv run pytest
```

Package dry-run:

```bash
npm pack --dry-run
```

Useful direct hook checks:

```bash
printf '%s' '{"tool_input":{"file_path":".ruff.toml"}}' \
  | PLANKTON_PROJECT_DIR="$PWD" bash .plankton/hooks/protect_linter_configs.sh

printf '%s' '{"tool_input":{"command":"pip install requests"}}' \
  | PLANKTON_PROJECT_DIR="$PWD" bash .plankton/hooks/enforce_package_managers.sh

bash .plankton/hooks/git_pre_commit.sh
```

## Manual global install

Prefer `pi install`, but a manual global install also works:

```bash
mkdir -p ~/.pi/agent/extensions
cp -a .pi/extensions/plankton ~/.pi/agent/extensions/plankton
pi
```
