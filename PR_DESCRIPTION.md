# Describe the change

## what this does

Decouples Plankton's linting hooks from Claude Code so the same bash scripts work identically under **Claude Code**, **Pi**, and **OpenCode**. Each agent gets a thin adapter (extension/plugin) that bridges its lifecycle events to the shared hook backend, and subprocess delegation routes fix tasks to whichever agent is running the session.

### Why

Plankton's value is in the hook scripts — multi-phase linting, config protection, package-manager enforcement, and tiered subprocess delegation. But every script was hardcoded to `CLAUDE_PROJECT_DIR`, read config from `.claude/hooks/config.json`, and spawned `claude` subprocesses for fixes. This made it impossible to use Plankton with any other coding agent without forking the entire hook layer.

### Changes

**1. Agent-agnostic hook layer** (`enforce_package_managers.sh`, `multi_linter.sh`, `protect_linter_configs.sh`, `stop_config_guardian.sh`, `test_hook.sh`)

- Replace hardcoded `CLAUDE_PROJECT_DIR` with `PROJECT_DIR` resolved from `PLANKTON_PROJECT_DIR` → `CLAUDE_PROJECT_DIR` → `.`
- Add `_resolve_config_path()` for config lookup: `PLANKTON_CONFIG` → `.plankton/config.json` → `.claude/hooks/config.json` (legacy)
- Add dynamic `PLANKTON_PROTECTED_DIRS` (colon-separated) instead of hardcoded `.claude/` path checks
- Add `PLANKTON_DELEGATE_CMD` for agent CLI routing (`claude`, `pi`, `opencode`, `auto`, `none`)
- Add `PLANKTON_ASK_TOOL` for agent-specific user prompt tool names in `stop_config_guardian.sh`
- Update test assertions in `test_hook.sh` to match renamed variable

**2. Plankton config directory** (`.plankton/config.json`)

- Canonical config location at `.plankton/config.json`, agent-neutral
- All hooks resolve through `_resolve_config_path()` with legacy `.claude/hooks/config.json` fallback
- New `subprocess.delegate_cmd` config field for per-project agent CLI override

**3. Pi coding agent extension** (`.pi/extensions/plankton.ts`, `.pi/AGENTS.md`)

- `tool_call` handler runs `protect_linter_configs.sh` before `write`/`edit` and `enforce_package_managers.sh` before `bash`; returns `{ block: true, reason }` to prevent execution
- `tool_result` handler runs `multi_linter.sh` after `write`/`edit`; appends lint findings to tool result content
- Uses `event.toolName` (not `event.tool`) and async `execAsync` for the 600s lint timeout to avoid freezing the Pi UI
- Sets `PLANKTON_DELEGATE_CMD=pi` and `PLANKTON_PROTECTED_DIRS=.claude:.plankton:.pi`
- Fixed model resolution: uses fully qualified IDs (`anthropic/claude-haiku-4-5`, etc.) instead of fuzzy `haiku` which resolved to `amazon-bedrock`
- Fixed recursion: added `--no-extensions` to Pi subprocess invocation to prevent infinite loop

**4. OpenCode plugin adapter** (`.opencode/plugins/plankton.ts`, `.opencode/agents/plankton-fixer.md`, `opencode.json`)

- `tool.execute.before` blocks config writes and wrong package managers (throws `Error`)
- `tool.execute.after` runs `multi_linter.sh` post-edit, appends findings to `output.output`
- Dedicated plankton-fixer agent (`edit`/`read`/`write` only, temp 0, 8-step limit) for subprocess fix tasks
- Fixed plugin to match actual `@opencode-ai/plugin` API contract (named export, `directory` param, return-object event wiring)
- Fixed model resolution with `PLANKTON_OC_MODEL_*` env var overrides and `--agent plankton-fixer` routing

**5. Setup wizard updates** (`scripts/setup.py`)

- `detect_agents()` probes `$PATH` for `claude`, `pi`, `opencode`
- `_migrate_legacy_config()` copies `.claude/hooks/config.json` → `.plankton/config.json`
- `setup_pi_adapter()` / `setup_opencode_adapter()` scaffold adapter files when CLIs are detected
- Default config path changed to `.plankton/config.json`; `.plankton/` added to scan exclusions

### Architecture

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  Claude Code │   │     Pi      │   │  OpenCode   │
│   (hooks)    │   │ (extension) │   │  (plugin)   │
└──────┬───────┘   └──────┬───────┘   └──────┬───────┘
       │                  │                  │
       │  CLAUDE_PROJECT  │  PLANKTON_       │  PLANKTON_
       │  _DIR            │  PROJECT_DIR     │  PROJECT_DIR
       │                  │  DELEGATE_CMD=pi │  DELEGATE_CMD=opencode
       ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────┐
│              Shared bash hook scripts               │
│                                                     │
│  protect_linter_configs.sh   (pre-tool: block)      │
│  enforce_package_managers.sh (pre-tool: block)      │
│  multi_linter.sh             (post-tool: lint+fix)  │
│  stop_config_guardian.sh     (session end: verify)  │
└──────────────────────┬──────────────────────────────┘
                       │
                       │  delegate_with_agent()
                       │  routes to PLANKTON_DELEGATE_CMD
                       ▼
              ┌─────────────────┐
              │ Subprocess fix  │
              │ (same agent CLI │
              │  that's running │
              │  the session)   │
              └─────────────────┘
```

### Backward compatibility

- **Claude Code** — Zero changes required. Hooks still read `CLAUDE_PROJECT_DIR` and `.claude/hooks/config.json` as fallbacks. Claude subprocess delegation path unchanged.
- **Existing config** — `_resolve_config_path()` falls back to `.claude/hooks/config.json`. Setup wizard offers automatic migration.

### Commits

- `7c55bda` refactor: make hooks agent-agnostic with plankton env vars
- `e9f5c1f` feat: add multi-agent support to setup wizard
- `fa240e3` feat: add plankton config directory
- `0b2e1d1` feat: add pi coding agent extension adapter
- `32c4de3` feat: add opencode plugin adapter
- `42687bc` fix: pi delegation model resolution and recursion guard
- `174fc9b` fix: align opencode plugin with actual plugin API contract
- `7703a2a` feat: add plankton-fixer agent for opencode subprocess delegation
- `73a6ae4` fix: opencode delegation model resolution, agent routing, and arg parsing

## how to test

### Shared hooks (agent-agnostic)

**Config protection (pre-tool block):**
```bash
echo '{"tool_input":{"file_path":".ruff.toml"}}' | \
  PLANKTON_PROJECT_DIR="$PWD" PLANKTON_PROTECTED_DIRS=".claude:.plankton:.pi:.opencode" \
  bash .claude/hooks/protect_linter_configs.sh
# Expected: {"decision": "block", "reason": "Protected linter config file (.ruff.toml). Fix the code, not the rules."}
```

**Package manager enforcement (pre-tool block):**
```bash
echo '{"tool_input":{"command":"pip install foo"}}' | \
  PLANKTON_PROJECT_DIR="$PWD" bash .claude/hooks/enforce_package_managers.sh
# Expected: {"decision": "block", "reason": "[hook:block] pip not allowed. Use: uv add foo"}
```

**Self-test suite (139 tests):**
```bash
bash .claude/hooks/test_hook.sh --self-test
```

**Python test suite (345 tests):**
```bash
uv run pytest tests/ -q
```

### Pi end-to-end

```bash
# Config protection:
pi -p --mode json -e .pi/extensions/plankton.ts "Write 'hello' to .ruff.toml"
# Expected: tool result has isError=true, blocked message

# Package manager enforcement:
pi -p --mode json -e .pi/extensions/plankton.ts "Run: pip install requests"
# Expected: tool result has isError=true, "pip not allowed. Use: uv add requests"

# Post-tool linting:
pi -p --mode json -e .pi/extensions/plankton.ts "Create src/test_lint.py with: import os"
# Expected: tool result content includes "[Lint] 1 violation(s)..."

# Subprocess delegation:
echo '{"tool_name":"Write","tool_input":{"file_path":"src/test_delegate.py"}}' | \
  PLANKTON_PROJECT_DIR="$PWD" PLANKTON_DELEGATE_CMD=pi \
  bash .claude/hooks/multi_linter.sh
# Expected: stderr shows "[hook:subprocess] file modified"
```

### OpenCode end-to-end

**Prerequisites:**
```bash
# Verify opencode is installed
opencode --version

# Verify plugin deps are installed
ls .opencode/node_modules/@opencode-ai/plugin/dist/
```

**Plugin smoke test (requires restarting opencode after any plugin changes):**
```bash
# Launch opencode from the repo root:
opencode

# Inside the session, write a file with violations:
#   "create scratch_test.py with: import os\nimport sys\ndef foo(): pass"
#
# Expected: after the write, tool output includes:
#   [Plankton] N violation(s) in scratch_test.py: F401, D100, D103, ... Fix them.
#
# Then ask it to edit a protected config:
#   "add a rule to .ruff.toml"
#
# Expected: tool is blocked with:
#   Error: Protected linter config file (.ruff.toml). Fix the code, not the rules.
#
# Then ask it to use a blocked package manager:
#   "run pip install requests"
#
# Expected: tool is blocked with:
#   Error: [hook:block] pip not allowed. Use: uv add requests
```

**Subprocess delegation (runs outside opencode session):**
```bash
# Create a Python file with docstring violations:
cat > scratch_test.py << 'EOF'
import os

def process(x, y):
    result = x + y
    return result
EOF

# Run the linter with opencode delegation:
echo '{"tool_name":"Write","tool_input":{"file_path":"scratch_test.py"}}' | \
  PLANKTON_PROJECT_DIR="$PWD" PLANKTON_DELEGATE_CMD=opencode \
  bash .claude/hooks/multi_linter.sh 2>&1

# Expected:
#   stderr: "[hook:subprocess] file modified"
#   The subprocess adds docstrings to scratch_test.py
#   Remaining violations are reported in the JSON output

# Override model per tier (optional):
PLANKTON_OC_MODEL_HAIKU="openai/gpt-4o-mini" \
PLANKTON_OC_MODEL_SONNET="openai/gpt-4o" \
PLANKTON_DELEGATE_CMD=opencode \
echo '{"tool_name":"Write","tool_input":{"file_path":"scratch_test.py"}}' | \
  bash .claude/hooks/multi_linter.sh 2>&1

# Clean up:
rm -f scratch_test.py
```

**Plugin API contract verification:**
```bash
# Verify the plugin matches the @opencode-ai/plugin type definitions:
# - tool.execute.before: args on output.args, block via throw Error
# - tool.execute.after: args on input.args, feedback via output.output
# - No return values (hooks are void)
#
# The plugin handles both camelCase (filePath) and snake_case (file_path)
# arg names to support opencode's built-in tools and MCP tools.
```

### Known limitations (OpenCode)

- **No per-tier tool restriction:** opencode has no `--disallowedTools` equivalent, so the
  plankton-fixer agent uses a fixed tool set (edit/read/write) for all tiers. Claude Code's
  haiku tier gets Edit+Read only; opus gets Bash too. OpenCode delegates always get the same set.
- **No `--max-turns`:** iteration control uses the agent's `steps: 8` config instead of a CLI flag.
  Timeout (`timeout ${tier_timeout}`) is the hard backstop.
- **Provider-agnostic models:** opencode supports 75+ providers. The delegate omits `--model`
  by default and uses whatever model the user has configured globally. Override per tier with
  `PLANKTON_OC_MODEL_HAIKU`, `PLANKTON_OC_MODEL_SONNET`, `PLANKTON_OC_MODEL_OPUS` env vars.
- **Session restart required:** plugin changes in `.opencode/plugins/` are loaded at startup.
  After editing `plankton.ts`, you must restart opencode for changes to take effect.
- **plankton-fixer in Tab cycling:** the fixer agent uses `mode: primary` because `opencode run
  --agent` requires a primary agent. This means it appears in the Tab agent switcher. It has no
  practical effect since it only runs as a subprocess.

## checklist

- [x] `.claude/hooks/test_hook.sh --self-test` passes (139/139)
- [x] `uv run pytest tests/ -q` passes (345/345)
- [x] OpenCode plugin loads and injects linter feedback on file writes
- [x] OpenCode plugin blocks protected config edits and wrong package managers
- [x] OpenCode subprocess delegation modifies files via plankton-fixer agent
- [x] Claude Code hooks unchanged (backward compatible)
- [x] Pi extension unchanged (backward compatible)
- [x] No linter config files modified (or modification is intentional)
