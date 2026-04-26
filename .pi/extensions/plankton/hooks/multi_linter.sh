#!/bin/bash
# shellcheck disable=SC2310  # functions in if/|| is intentional throughout
# multi_linter.sh - Pi PostToolUse hook for multi-language linting
# Supports: Python (ruff+ty+flake8-pydantic+flake8-async), Elixir/Phoenix (mix format+Credo+Sobelow+compile warnings),
#           Shell (shellcheck+shfmt), YAML (yamllint), JSON (jaq/biome),
#           Dockerfile (hadolint), TOML (taplo), Markdown (markdownlint-cli2),
#           TypeScript/JS/CSS (biome+semgrep)
#
# Three-Phase Architecture:
#   Phase 1: Auto-format files (silent on success)
#   Phase 2: Collect unfixable violations as JSON
#   Phase 3: Delegate to Pi subprocess for fixes, then verify
#
# Dependencies:
#   Required: jaq (JSON parsing), ruff (Python), pi (subprocess delegation)
#   Optional: shellcheck, shfmt, yamllint, hadolint, taplo, markdownlint-cli2,
#             ty (type checking), flake8-pydantic, biome (TypeScript/JS/CSS),
#             semgrep (security scanning), sobelow (Phoenix security)
#
# Project configs: .ruff.toml, ty.toml, taplo.toml, .yamllint,
#                  .shellcheckrc, .hadolint.yaml, .markdownlint.jsonc,
#                  biome.json, .semgrep.yml, .formatter.exs, .credo.exs,
#                  .sobelow-conf, .sobelow-skips
#
# Exit Code Strategy:
#   0 - No issues or all issues fixed by delegation
#   2 - Issues remain after delegation attempt

set -euo pipefail

# Pi project dir (set by the extension, fallback to cwd for manual tests).
PROJECT_DIR="${PLANKTON_PROJECT_DIR:-.}"

# Pi is the only supported subprocess delegate.
PLANKTON_DELEGATE_CMD_FROM_ENV="${PLANKTON_DELEGATE_CMD:-}"
PLANKTON_DELEGATE_CMD="${PLANKTON_DELEGATE_CMD:-pi}"

# Config resolution: PLANKTON_CONFIG > .plankton/config.json
_resolve_config_path() {
  if [[ -n "${PLANKTON_CONFIG:-}" ]]; then
    echo "${PLANKTON_CONFIG}"
  elif [[ -f "${PROJECT_DIR}/.plankton/config.json" ]]; then
    echo "${PROJECT_DIR}/.plankton/config.json"
  else
    echo ""
  fi
}

# Ensure Python venv tools are discoverable (uv sync installs to .venv/bin/)
# On macOS tools are on PATH via brew; on Linux they're only in the venv.
if [[ -d "${PROJECT_DIR}/.venv/bin" ]]; then
  export PATH="${PROJECT_DIR}/.venv/bin:${PATH}"
fi

# Output JSON to stdout for Pi hook protocol.
# PostToolUse hooks should return {"continue":true,"systemMessage":"..."}.
# Called at meaningful exit points (post-linting) — early bail-outs skip this.
# shellcheck disable=SC2329  # Called at exit points (wiring in progress)
hook_json() {
  local msg="${1:-}"
  if [[ -n "${msg}" ]]; then
    # shellcheck disable=SC2016 # $m is a jaq variable, not shell
    jaq -n --arg m "${msg}" '{"continue":true,"systemMessage":$m}' 2>/dev/null || printf '{"continue":true}\n'
  else
    printf '{"continue":true}\n'
  fi
}

# Emit JSON and exit clean — ensures Pi always receives valid JSON.
# shellcheck disable=SC2329  # invoked indirectly
exit_json() {
  hook_json "${1:-}"
  exit 0
}

# Emit structured timing diagnostics to stderr and, optionally, to a file.
# Never writes to stdout. Fail-open by design.
hook_diag() {
  local line="[hook:timing] t=${SECONDS} $*"
  printf '%s\n' "${line}" >&2
  if [[ -n "${HOOK_TIMING_LOG_FILE:-}" ]]; then
    local _log_dir
    _log_dir=$(dirname "${HOOK_TIMING_LOG_FILE}")
    mkdir -p "${_log_dir}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${HOOK_TIMING_LOG_FILE}" 2>/dev/null || true
  fi
}

# Fail-open if jaq is not installed (required for JSON parsing)
if ! command -v jaq >/dev/null 2>&1; then
  echo "[hook] error: jaq is required but not found. Install: brew install jaq" >&2
  printf '{"continue":true}\n'
  exit 0
fi

# ============================================================================
# CONFIGURATION LOADING
# Session PID for temp file scoping (override with HOOK_SESSION_PID for testing)
SESSION_PID="${HOOK_SESSION_PID:-${PPID}}"
# ============================================================================

# Load configuration from config.json (falls back to all-enabled if missing)
load_config() {
  local config_file
  config_file=$(_resolve_config_path)
  if [[ -f "${config_file}" ]]; then
    CONFIG_JSON=$(cat "${config_file}")
  else
    CONFIG_JSON='{}'
  fi
}

# Check if a language is enabled (default: true when missing)
is_language_enabled() {
  local lang="$1"
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r ".languages.${lang}" 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Get security-linter exclusion patterns from config (defaults if not configured).
# Backward compatible: prefer security_linter_exclusions, fall back to legacy
# exclusions if present.
get_security_linter_exclusions() {
  local defaults='[".venv/","node_modules/",".git/"]'
  echo "${CONFIG_JSON}" | jaq -r ".security_linter_exclusions // .exclusions // ${defaults} | .[]" 2>/dev/null
}

get_bandit_config_file() {
  local config_file="${PROJECT_DIR}/pyproject.toml"
  if [[ -f "${config_file}" ]]; then
    printf '%s\n' "${config_file}"
  fi
}

run_bandit_json() {
  local target_file="$1"
  local bandit_config
  bandit_config=$(get_bandit_config_file)
  if [[ -n "${bandit_config}" ]]; then
    uv run bandit -c "${bandit_config}" -f json -q "${target_file}" 2>/dev/null || true
  else
    uv run bandit -f json -q "${target_file}" 2>/dev/null || true
  fi
}

# Detect and reject old flat config format
check_config_migration() {
  local has_old_timeout has_old_model_selection
  has_old_timeout=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.timeout // empty' 2>/dev/null) || true
  has_old_model_selection=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.model_selection // empty' 2>/dev/null) || true
  # Only error if old keys exist AND new tiers key does NOT exist
  local has_tiers
  has_tiers=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers // empty' 2>/dev/null) || true
  if [[ -n "${has_old_timeout}" || -n "${has_old_model_selection}" ]] && [[ -z "${has_tiers}" ]]; then
    echo "[hook:error] config.json uses deprecated flat subprocess format." >&2
    echo "[hook:error] Migrate to subprocess.tiers structure. See docs/specs/subprocess-permission-gap.md" >&2
    return 1
  fi
}

# Load model selection patterns from config (tier-based or legacy defaults)
load_model_patterns() {
  local default_haiku='E[0-9]+|W[0-9]+|F[0-9]+|B[0-9]+|S[0-9]+|T[0-9]+|N[0-9]+|UP[0-9]+|YTT[0-9]+|ANN[0-9]+|BLE[0-9]+|FBT[0-9]+|A[0-9]+|COM[0-9]+|DTZ[0-9]+|EM[0-9]+|EXE[0-9]+|ISC[0-9]+|ICN[0-9]+|G[0-9]+|INP[0-9]+|PIE[0-9]+|PYI[0-9]+|PT[0-9]+|Q[0-9]+|RSE[0-9]+|RET[0-9]+|SLF[0-9]+|SIM[0-9]+|TID[0-9]+|TCH[0-9]+|INT[0-9]+|ARG[0-9]+|PTH[0-9]+|TD[0-9]+|FIX[0-9]+|ERA[0-9]+|PD[0-9]+|PGH[0-9]+|PLC[0-9]+|PLE[0-9]+|PLW[0-9]+|TRY[0-9]+|FLY[0-9]+|NPY[0-9]+|AIR[0-9]+|PERF[0-9]+|FURB[0-9]+|LOG[0-9]+|RUF[0-9]+|SC[0-9]+|DL[0-9]+|I[0-9]+|MIX_FORMAT|SOBELOW|MIX_COMPILE|DEPS_AUDIT|XREF_[A-Z]+|LV_LIST_WITHOUT_STREAM|LV_MISSING_IMPL'
  local default_sonnet='C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+|Credo\.|Sobelow\.|LV_PUBSUB_NO_CONNECTED|LV_REPO_IN_LIVEVIEW|LV_GENERIC_EVENT_PARAMS|LV_UNUSED_ASSIGN'
  local default_opus='unresolved-attribute|type-assertion'

  # Read from tiers structure (preferred) or fall back to defaults
  HAIKU_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.patterns // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_CODE_PATTERN}" ]] && HAIKU_CODE_PATTERN="${default_haiku}"
  SONNET_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.patterns // empty' 2>/dev/null) || true
  [[ -z "${SONNET_CODE_PATTERN}" ]] && SONNET_CODE_PATTERN="${default_sonnet}"
  OPUS_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.patterns // empty' 2>/dev/null) || true
  [[ -z "${OPUS_CODE_PATTERN}" ]] && OPUS_CODE_PATTERN="${default_opus}"

  VOLUME_THRESHOLD=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.volume_threshold // empty' 2>/dev/null) || true
  [[ -z "${VOLUME_THRESHOLD}" ]] && VOLUME_THRESHOLD=5

  # Cross-tier overrides (env var takes precedence for timeout)
  GLOBAL_MODEL_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.global_model_override // empty' 2>/dev/null) || true
  MAX_TURNS_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.max_turns_override // empty' 2>/dev/null) || true
  TIMEOUT_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.timeout_override // empty' 2>/dev/null) || true
  [[ -n "${HOOK_SUBPROCESS_TIMEOUT:-}" ]] && TIMEOUT_OVERRIDE="${HOOK_SUBPROCESS_TIMEOUT}"

  # Per-tier max_turns and timeout
  HAIKU_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.max_turns // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_MAX_TURNS}" ]] && HAIKU_MAX_TURNS=10
  SONNET_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.max_turns // empty' 2>/dev/null) || true
  [[ -z "${SONNET_MAX_TURNS}" ]] && SONNET_MAX_TURNS=10
  OPUS_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.max_turns // empty' 2>/dev/null) || true
  [[ -z "${OPUS_MAX_TURNS}" ]] && OPUS_MAX_TURNS=15

  HAIKU_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.timeout // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_TIMEOUT}" ]] && HAIKU_TIMEOUT=120
  SONNET_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.timeout // empty' 2>/dev/null) || true
  [[ -z "${SONNET_TIMEOUT}" ]] && SONNET_TIMEOUT=300
  OPUS_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.timeout // empty' 2>/dev/null) || true
  [[ -z "${OPUS_TIMEOUT}" ]] && OPUS_TIMEOUT=600

  # Per-tier tool lists
  HAIKU_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.tools // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_TOOLS}" ]] && HAIKU_TOOLS="Edit,Read"
  SONNET_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.tools // empty' 2>/dev/null) || true
  [[ -z "${SONNET_TOOLS}" ]] && SONNET_TOOLS="Edit,Read"
  OPUS_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.tools // empty' 2>/dev/null) || true
  [[ -z "${OPUS_TOOLS}" ]] && OPUS_TOOLS="Edit,Read,Write"

  # Delegation command from config unless env var explicitly overrides.
  if [[ -z "${PLANKTON_DELEGATE_CMD_FROM_ENV}" ]]; then
    local _cfg_delegate
    _cfg_delegate=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.delegate_cmd // empty' 2>/dev/null) || true
    case "${_cfg_delegate}" in
      auto | clau"de" | open"code") PLANKTON_DELEGATE_CMD="pi" ;;
      pi | none) PLANKTON_DELEGATE_CMD="${_cfg_delegate}" ;;
      "") ;;
      *) PLANKTON_DELEGATE_CMD="${_cfg_delegate}" ;;
    esac
  fi

  readonly HAIKU_CODE_PATTERN SONNET_CODE_PATTERN OPUS_CODE_PATTERN VOLUME_THRESHOLD
  readonly GLOBAL_MODEL_OVERRIDE MAX_TURNS_OVERRIDE TIMEOUT_OVERRIDE
  readonly HAIKU_MAX_TURNS SONNET_MAX_TURNS OPUS_MAX_TURNS
  readonly HAIKU_TIMEOUT SONNET_TIMEOUT OPUS_TIMEOUT
  readonly HAIKU_TOOLS SONNET_TOOLS OPUS_TOOLS
}

# Check if auto-format phase is enabled (default: true)
is_auto_format_enabled() {
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.auto_format' 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Check if subprocess delegation is enabled (default: true)
is_subprocess_enabled() {
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.subprocess_delegation' 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Check if TypeScript is enabled (handles both legacy boolean and nested object)
is_typescript_enabled() {
  local ts_config
  ts_config=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript' 2>/dev/null)
  case "${ts_config}" in
    false | null) return 1 ;;
    true) return 0 ;;
    *) # nested object - check .enabled field
      local enabled
      enabled=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript.enabled // false' 2>/dev/null)
      [[ "${enabled}" != "false" ]]
      ;;
  esac
}

# Get a nested TS config value with default
get_ts_config() {
  local key="$1"
  local default="$2"
  echo "${CONFIG_JSON}" | jaq -r ".languages.typescript.${key} // \"${default}\"" 2>/dev/null
}

# Check if Elixir is enabled (supports both bool and nested object config)
is_elixir_enabled() {
  local ex_config
  ex_config=$(echo "${CONFIG_JSON}" | jaq -r '.languages.elixir' 2>/dev/null)
  case "${ex_config}" in
    false | null) return 1 ;;
    true) return 0 ;;
    *) # nested object - check .enabled field
      local enabled
      enabled=$(echo "${CONFIG_JSON}" | jaq -r '.languages.elixir.enabled // true' 2>/dev/null)
      [[ "${enabled}" != "false" ]]
      ;;
  esac
}

# Get a nested Elixir config value with default
get_elixir_config() {
  local key="$1"
  local default="$2"
  local ex_config
  ex_config=$(echo "${CONFIG_JSON}" | jaq -r '.languages.elixir' 2>/dev/null)
  case "${ex_config}" in
    true | false | null) echo "${default}" ;;
    *) echo "${CONFIG_JSON}" | jaq -r ".languages.elixir.${key} // \"${default}\"" 2>/dev/null ;;
  esac
}

# Detect Biome binary with session caching (D8)
detect_biome() {
  local cache_file="/tmp/.biome_path_${SESSION_PID}"

  # Check session cache first
  if [[ -f "${cache_file}" ]]; then
    local cached
    cached=$(cat "${cache_file}")
    if [[ -n "${cached}" ]]; then
      echo "${cached}"
      return 0
    fi
  fi

  local biome_cmd=""
  local js_runtime
  js_runtime=$(get_ts_config "js_runtime" "auto")

  if [[ "${js_runtime}" != "auto" ]]; then
    # Explicit runtime configured
    case "${js_runtime}" in
      npm) biome_cmd="npx biome" ;;
      pnpm) biome_cmd="pnpm exec biome" ;;
      bun) biome_cmd="bunx biome" ;;
      *) ;;
    esac
  else
    # Auto-detect: project-local -> PATH -> npx -> pnpm -> bunx
    if [[ -x "./node_modules/.bin/biome" ]]; then
      biome_cmd="$(cd . && pwd)/node_modules/.bin/biome"
    elif command -v biome >/dev/null 2>&1; then
      biome_cmd="biome"
    elif command -v npx >/dev/null 2>&1; then
      biome_cmd="npx biome"
    elif command -v pnpm >/dev/null 2>&1; then
      biome_cmd="pnpm exec biome"
    elif command -v bunx >/dev/null 2>&1; then
      biome_cmd="bunx biome"
    fi
  fi

  if [[ -n "${biome_cmd}" ]]; then
    echo "${biome_cmd}" >"${cache_file}"
    echo "${biome_cmd}"
    return 0
  fi

  return 1
}

# Detect Elixir/Phoenix Mix project root by walking up from the file path.
find_mix_project_root() {
  local fp="$1"
  local dir="${fp}"

  [[ -f "${fp}" ]] && dir=$(dirname "${fp}")

  while true; do
    if [[ -f "${dir}/mix.exs" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    if [[ "${dir}" == "${PROJECT_DIR}" ]] || [[ "${dir}" == "." ]] || [[ "${dir}" == "/" ]]; then
      break
    fi
    local parent
    parent=$(dirname "${dir}")
    [[ "${parent}" == "${dir}" ]] && break
    dir="${parent}"
  done

  if [[ -f "${PROJECT_DIR}/mix.exs" ]]; then
    printf '%s\n' "${PROJECT_DIR}"
    return 0
  fi

  return 1
}

elixir_mix_relpath() {
  local root="$1"
  local fp="$2"

  if [[ "${fp}" == "${root}/"* ]]; then
    printf '%s\n' "${fp#"${root}/"}"
  else
    printf '%s\n' "${fp}"
  fi
}

is_elixir_source_file() {
  case "$1" in
    *.ex | *.exs) return 0 ;;
    *) return 1 ;;
  esac
}

mix_task_available() {
  local root="$1"
  local task="$2"
  (cd "${root}" && mix help "${task}" >/dev/null 2>&1)
}

run_mix_format_file() {
  local root="$1"
  local rel_path="$2"
  (cd "${root}" && mix format "${rel_path}")
}

run_mix_format_check_file() {
  local root="$1"
  local rel_path="$2"
  (cd "${root}" && mix format --check-formatted "${rel_path}")
}

run_mix_credo_json() {
  local root="$1"
  local rel_path="$2"
  (cd "${root}" && mix credo --strict --format json "${rel_path}" 2>/dev/null || true)
}

# Run Sobelow security scanner on the whole Phoenix project (project-level tool)
run_sobelow_json() {
  local root="$1"
  (cd "${root}" && mix sobelow --format json --quiet 2>/dev/null || true)
}

# Run mix compile with warnings-as-errors and return warnings as JSON
run_mix_compile_warnings() {
  local root="$1"
  local rel_path="$2"
  local output
  output=$(cd "${root}" && mix compile --warnings-as-errors --force "${rel_path}" 2>&1 || true)
  # Parse warning lines: "lib/foo.ex:10: warning: ..."
  echo "${output}" | grep -E "^[^ ]+\.ex[s]?:[0-9]+:" || true
}


# Run mix deps.audit for hex package security vulnerabilities (session-scoped)
run_deps_audit() {
  local root="$1"
  (cd "${root}" && mix deps.audit 2>&1 || true)
}

# Run mix xref for cross-reference warnings (unreachable, deprecated)
run_xref_warnings() {
  local root="$1"
  local output=""
  local unreachable
  unreachable=$(cd "${root}" && mix xref unreachable 2>/dev/null || true)
  if [[ -n "${unreachable}" ]] && ! echo "${unreachable}" | grep -qi "no unreachable"; then
    output="${unreachable}"
  fi
  local deprecated
  deprecated=$(cd "${root}" && mix xref deprecated 2>/dev/null || true)
  if [[ -n "${deprecated}" ]] && ! echo "${deprecated}" | grep -qi "no deprecated"; then
    output="${output:+${output}
}${deprecated}"
  fi
  echo "${output}"
}

# Detect LiveView anti-patterns in Elixir source files.
# Returns JSON array of advisory violations.
# shellcheck disable=SC2016  # jaq uses $l/$m/$k/$cb variables, not shell
detect_liveview_antipatterns() {
  local fp="$1"
  local violations="[]"

  # Only check .ex files that use LiveView
  [[ "${fp}" != *.ex ]] && { echo "[]"; return; }
  grep -qE 'use\s+.*:live_view|use\s+.*LiveView' "${fp}" 2>/dev/null || { echo "[]"; return; }

  local file_content
  file_content=$(cat "${fp}" 2>/dev/null) || { echo "[]"; return; }

  local lv_enabled
  lv_enabled=$(get_elixir_config "liveview_checks" "true")
  [[ "${lv_enabled}" == "false" ]] && { echo "[]"; return; }

  # 1. PubSub.subscribe without connected?/1 guard
  if echo "${file_content}" | grep -qE 'PubSub\.subscribe|Phoenix\.PubSub\.subscribe'; then
    if ! echo "${file_content}" | grep -qE 'connected\?\('; then
      local sub_line
      sub_line=$(echo "${file_content}" | grep -nE 'PubSub\.subscribe|Phoenix\.PubSub\.subscribe' | head -1 | cut -d: -f1)
      [[ -z "${sub_line}" ]] && sub_line=1
      # shellcheck disable=SC2016
      local v
      v=$(jaq -n --arg l "${sub_line}" \
        '{line:($l|tonumber),column:1,code:"LV_PUBSUB_NO_CONNECTED",message:"PubSub.subscribe without connected?(socket) guard. Wrap in: if connected?(socket), do: Phoenix.PubSub.subscribe(...)",linter:"liveview-check"}') || true
      [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
    fi
  fi

  # 2. Assign with inline Repo/Ecto query (should be in context module)
  local repo_assign_lines
  repo_assign_lines=$(echo "${file_content}" | grep -nE '(assign|assign_new)\(.*Repo\.|[|]>\s*assign\(.*Repo\.' 2>/dev/null || true)
  if [[ -n "${repo_assign_lines}" ]]; then
    while IFS= read -r line; do
      local ln
      ln=$(echo "${line}" | cut -d: -f1)
      [[ -z "${ln}" ]] && continue
      # shellcheck disable=SC2016
      local v
      v=$(jaq -n --arg l "${ln}" \
        '{line:($l|tonumber),column:1,code:"LV_REPO_IN_LIVEVIEW",message:"Repo/Ecto query in LiveView assign. Move data access to a context module.",linter:"liveview-check"}') || true
      [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
    done <<< "${repo_assign_lines}"
  fi

  # 3. handle_event without pattern matching on params
  local generic_events
  generic_events=$(echo "${file_content}" | grep -nE 'def handle_event\([^,]+,\s*[a-z][a-z_0-9]*\s*,' 2>/dev/null || true)
  if [[ -n "${generic_events}" ]]; then
    while IFS= read -r line; do
      # Skip if the param is _ or _params (explicitly ignored)
      echo "${line}" | grep -qE 'def handle_event\([^,]+,\s*_[a-z_]*\s*,' && continue
      local ln
      ln=$(echo "${line}" | cut -d: -f1)
      [[ -z "${ln}" ]] && continue
      # shellcheck disable=SC2016
      local v
      v=$(jaq -n --arg l "${ln}" \
        '{line:($l|tonumber),column:1,code:"LV_GENERIC_EVENT_PARAMS",message:"handle_event/3 uses generic variable for params. Prefer pattern matching: def handle_event(\"name\", %{\"key\" => val}, socket)",linter:"liveview-check"}') || true
      [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
    done <<< "${generic_events}"
  fi

  # 4. Missing @impl true annotations on LiveView callbacks
  local callbacks=("def mount" "def handle_event" "def handle_info" "def handle_params" "def render")
  for cb in "${callbacks[@]}"; do
    local cb_lines
    cb_lines=$(echo "${file_content}" | grep -nE "^\s*${cb}\(" 2>/dev/null || true)
    if [[ -n "${cb_lines}" ]]; then
      while IFS= read -r line; do
        local ln
        ln=$(echo "${line}" | cut -d: -f1)
        [[ -z "${ln}" ]] && continue
        local prev_ln=$((ln - 1))
        [[ ${prev_ln} -lt 1 ]] && prev_ln=1
        local prev_line
        prev_line=$(sed -n "${prev_ln}p" "${fp}" 2>/dev/null || true)
        if ! echo "${prev_line}" | grep -qE '@impl\s+true'; then
          # shellcheck disable=SC2016
          local v
          v=$(jaq -n --arg l "${ln}" --arg cb "${cb}" \
            '{line:($l|tonumber),column:1,code:"LV_MISSING_IMPL",message:("Missing @impl true before " + $cb + ". Add annotation for LiveView callbacks."),linter:"liveview-check"}') || true
          [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
        fi
      done <<< "${cb_lines}"
    fi
  done

  # 5. List assigned directly without stream/3
  local list_assigns
  list_assigns=$(echo "${file_content}" | grep -nE 'assign\(.*,\s*:[a-z_]+,\s*(Enum\.|Enum\s|for\s|\[)' 2>/dev/null || true)
  if [[ -n "${list_assigns}" ]]; then
    while IFS= read -r line; do
      local ln
      ln=$(echo "${line}" | cut -d: -f1)
      [[ -z "${ln}" ]] && continue
      # shellcheck disable=SC2016
      local v
      v=$(jaq -n --arg l "${ln}" \
        '{line:($l|tonumber),column:1,code:"LV_LIST_WITHOUT_STREAM",message:"List assigned directly to socket. For large/frequently-updated lists, consider stream/3 to minimize diff payloads.",linter:"liveview-check"}') || true
      [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
    done <<< "${list_assigns}"
  fi

  # 6. Unused socket assigns (assign set but key not found in render/template)
  local assign_keys
  assign_keys=$(echo "${file_content}" | grep -oE 'assign\(:([a-z_]+)|assign\([^,]+,\s*:([a-z_]+)' | grep -oE ':[a-z_]+' | tr -d ':' | sort -u 2>/dev/null || true)
  if [[ -n "${assign_keys}" ]] && echo "${file_content}" | grep -qE 'def render\(assigns\)'; then
    local render_block
    render_block=$(echo "${file_content}" | sed -n '/def render(assigns)/,/^[[:space:]]*end$/p' 2>/dev/null || true)
    if [[ -n "${render_block}" ]]; then
      while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        if ! echo "${render_block}" | grep -qE "@${key}[^a-z_]|@${key}$"; then
          local assign_line
          assign_line=$(echo "${file_content}" | grep -nE "assign\(:${key}[,)]|assign\([^,]+,\s*:${key}[,)]" | head -1 | cut -d: -f1)
          [[ -z "${assign_line}" ]] && continue
          # shellcheck disable=SC2016
          local v
          v=$(jaq -n --arg l "${assign_line}" --arg k "${key}" \
            '{line:($l|tonumber),column:1,code:"LV_UNUSED_ASSIGN",message:("Socket assign :" + $k + " is set but not referenced in render/1. Remove or use it."),linter:"liveview-check"}') || true
          [[ -n "${v}" ]] && violations=$(echo "${violations}" "[${v}]" | jaq -s '.[0] + .[1]' 2>/dev/null) || true
        fi
      done <<< "${assign_keys}"
    fi
  fi

  echo "${violations}"
}

# Initialize configuration
load_config

# Master kill switch: hook_enabled=false in config.json disables all linting
if [[ "$(echo "${CONFIG_JSON}" | jaq -r '.hook_enabled' 2>/dev/null || true)" == "false" ]]; then
  exit_json
fi
check_config_migration || exit_json
load_model_patterns

# Read JSON input from stdin
input=$(cat)
tool_name=$(jaq -r '.tool_name // empty' <<<"${input}" 2>/dev/null) || tool_name=""
[[ -z "${tool_name}" ]] && tool_name="unknown"

# Track if any issues found
has_issues=false

# Collected violations for delegation (JSON array)
collected_violations="[]"

# File type for delegation
file_type=""

# Note: HOOK_SUBPROCESS_TIMEOUT env var is handled inside load_model_patterns

# Extract file path from tool_input
file_path=$(jaq -r '.tool_input?.file_path? // .tool_input?.notebook_path? // empty' <<<"${input}" 2>/dev/null) || file_path=""

# Skip if no file path or file doesn't exist
[[ -z "${file_path}" ]] && exit_json
[[ ! -f "${file_path}" ]] && exit_json

# ============================================================================
# PATH EXCLUSION FOR SECURITY LINTERS
# ============================================================================
# Matches common exclusion paths for tools like vulture/bandit.
# Used to skip security linters on test files, scripts, etc. where false
# positives are expected (e.g., intentional security patterns in tests).
is_excluded_from_security_linters() {
  local fp="$1"

  # Normalize absolute paths to relative (using PROJECT_DIR if available)
  if [[ -n "${PROJECT_DIR:-}" ]] && [[ "${fp}" == "${PROJECT_DIR}"/* ]]; then
    fp="${fp#"${PROJECT_DIR}"/}"
  fi

  local exclusion
  local exclusions
  exclusions=$(get_security_linter_exclusions || true)
  while IFS= read -r exclusion; do
    [[ -z "${exclusion}" ]] && continue
    if [[ "${fp}" == ${exclusion}* ]]; then
      return 0
    fi
  done <<<"${exclusions}"
  return 1
}

# ============================================================================
# DELEGATION FUNCTIONS
# ============================================================================

_delegate_pi() {
  local fp="$1" prompt="$2" model="$3" tier_tools="$4" tier_max_turns="$5" tier_timeout="$6"

  local pi_cmd=""
  command -v pi >/dev/null 2>&1 && pi_cmd="pi"
  [[ -z "${pi_cmd}" ]] && { echo "[hook:error] pi binary not found" >&2; return 0; }

  local pi_model
  local anthropic_family="clau""de"
  case "${model}" in
    haiku)  pi_model="anthropic/${anthropic_family}-haiku-4-5" ;;
    sonnet) pi_model="anthropic/${anthropic_family}-sonnet-4-5" ;;
    opus)   pi_model="anthropic/${anthropic_family}-opus-4" ;;
    *)      pi_model="${model}" ;;
  esac

  # Map allowed tools: Pi's Edit,Read,Write -> Pi's edit,read,write
  local pi_tools
  pi_tools=$(echo "${tier_tools}" | tr '[:upper:]' '[:lower:]')

  local timeout_cmd=""
  command -v timeout >/dev/null 2>&1 && timeout_cmd="timeout ${tier_timeout}"

  local file_hash_before=""
  [[ -f "${fp}" ]] && file_hash_before=$(cksum "${fp}" 2>/dev/null || true)

  local subprocess_exit=0
  ${timeout_cmd} "${pi_cmd}" -p "${prompt}" \
    --tools "${pi_tools}" \
    --model "${pi_model}" \
    --no-session \
    --no-extensions \
    "@${fp}" >/dev/null 2>&1 || subprocess_exit=$?

  local file_hash_after=""
  [[ -f "${fp}" ]] && file_hash_after=$(cksum "${fp}" 2>/dev/null || true)
  [[ "${file_hash_before}" != "${file_hash_after}" ]] && echo "[hook:subprocess] file modified" >&2 || echo "[hook:subprocess] file unchanged" >&2

  if [[ "${subprocess_exit}" -ne 0 ]]; then
    echo "[hook:warning] pi subprocess failed (exit ${subprocess_exit})" >&2
  fi
}


delegate_with_agent() {
  local fp="$1" prompt="$2" model="$3" tier_tools="$4" tier_max_turns="$5" tier_timeout="$6"
  local delegate_cmd="${PLANKTON_DELEGATE_CMD}"

  case "${delegate_cmd}" in
    pi) _delegate_pi "$@" ;;
    none)
      echo "[hook:info] subprocess delegation disabled" >&2
      return 0
      ;;
    *)
      echo "[hook:error] unknown delegate_cmd '${delegate_cmd}' (Pi-only Plankton supports: pi, none)" >&2
      return 1
      ;;
  esac
}

# Spawn Pi subprocess to fix violations
spawn_fix_subprocess() {
  local fp="$1"
  local violations_json="$2"
  local ftype="$3"

  # Filter violations for docstring-specialized branch (BUG-7 fix)
  # If Python file has real D### docstring codes, narrow to D-only subset.
  # Non-D violations are handled by the rerun loop after docstrings are fixed.
  local prompt_violations_json="${violations_json}"
  if [[ "${ftype}" == "python" ]] && echo "${violations_json}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    prompt_violations_json=$(echo "${violations_json}" | jaq -c '[.[] | select(.code | test("^D[0-9]+$"))]' 2>/dev/null) || prompt_violations_json="${violations_json}"
  fi

  # Compute prompt-side count and codes once (used for logs and model selection)
  local prompt_count prompt_codes
  prompt_count=$(echo "${prompt_violations_json}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
  prompt_codes=$(echo "${prompt_violations_json}" | jaq -r '[.[].code] | sort | unique | join(",")' 2>/dev/null || echo "")
  hook_diag "phase=delegate_plan tool=${tool_name} file=${fp} ftype=${ftype} count=${prompt_count} codes=${prompt_codes}"

  # Model selection based on violation complexity
  local count="${prompt_count}"

  local model=""
  local tier_max_turns=""
  local tier_timeout=""
  local tier_tools=""

  # Global model override skips all tier selection
  if [[ -n "${GLOBAL_MODEL_OVERRIDE}" ]]; then
    model="${GLOBAL_MODEL_OVERRIDE}"
  else
    # Check for opus-level codes
    local has_opus_codes="false"
    # shellcheck disable=SC2016 # jaq uses $pattern, not shell
    if echo "${prompt_violations_json}" | jaq -e --arg pattern "${OPUS_CODE_PATTERN}" '[.[] | select(.code | test($pattern))] | length > 0' >/dev/null 2>&1; then
      has_opus_codes="true"
    fi

    # Check for sonnet-level codes
    local has_sonnet_codes="false"
    # shellcheck disable=SC2016 # jaq uses $pattern, not shell
    if echo "${prompt_violations_json}" | jaq -e --arg pattern "${SONNET_CODE_PATTERN}" '[.[] | select(.code | test($pattern))] | length > 0' >/dev/null 2>&1; then
      has_sonnet_codes="true"
    fi

    # Select model: haiku (default) -> sonnet -> opus (complex or >threshold)
    model="haiku"
    if [[ "${has_sonnet_codes}" == "true" ]]; then
      model="sonnet"
    fi
    if [[ "${has_opus_codes}" == "true" ]] || [[ "${count}" -gt "${VOLUME_THRESHOLD}" ]]; then
      model="opus"
    fi
  fi

  # Warn about violation codes that don't match any tier pattern
  if [[ "${model}" == "haiku" ]] && [[ -z "${GLOBAL_MODEL_OVERRIDE}" ]]; then
    local unmatched_codes
    unmatched_codes=$(echo "${prompt_violations_json}" | jaq -r '.[].code' 2>/dev/null | sort -u) || true
    while IFS= read -r code; do
      [[ -z "${code}" ]] && continue
      local matched="false"
      if echo "${code}" | grep -qE "^(${HAIKU_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if echo "${code}" | grep -qE "^(${SONNET_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if echo "${code}" | grep -qE "^(${OPUS_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if [[ "${matched}" == "false" ]]; then
        echo "[hook:warning] unmatched pattern '${code}', defaulting to haiku" >&2
      fi
    done <<<"${unmatched_codes}"
  fi

  # Resolve per-tier settings
  case "${model}" in
    opus)
      tier_max_turns="${OPUS_MAX_TURNS}"
      tier_timeout="${OPUS_TIMEOUT}"
      tier_tools="${OPUS_TOOLS}"
      ;;
    sonnet)
      tier_max_turns="${SONNET_MAX_TURNS}"
      tier_timeout="${SONNET_TIMEOUT}"
      tier_tools="${SONNET_TOOLS}"
      ;;
    *)
      tier_max_turns="${HAIKU_MAX_TURNS}"
      tier_timeout="${HAIKU_TIMEOUT}"
      tier_tools="${HAIKU_TOOLS}"
      ;;
  esac

  # Apply cross-tier overrides
  [[ -n "${MAX_TURNS_OVERRIDE}" ]] && tier_max_turns="${MAX_TURNS_OVERRIDE}"
  [[ -n "${TIMEOUT_OVERRIDE}" ]] && tier_timeout="${TIMEOUT_OVERRIDE}"

  # Debug output for testing model selection
  if [[ "${HOOK_DEBUG_MODEL:-}" == "1" ]]; then
    echo "[hook:model] ${model} (count=${count}, opus_codes=${has_opus_codes:-n/a}, sonnet_codes=${has_sonnet_codes:-n/a})" >&2
  fi

  # Build prompt for subprocess (file-type specific for better fixes)
  local prompt
  if [[ "${ftype}" == "markdown" ]]; then
    # Markdown-specific prompt with semantic fix strategies
    prompt="You are a markdown fixer. Fix ALL violations in ${fp}.

VIOLATIONS:
${prompt_violations_json}

MARKDOWN FIX STRATEGIES:
- MD013 (line length >80): SHORTEN content, don't wrap. Examples:
  - 'Skip delegation, report violations directly' -> 'Skip delegation, report directly'
  - 'Refactor to early returns, extract Config class' -> 'Refactor to early returns'
  - Remove redundant words: 'in order to' -> 'to', 'that is' -> ''
- MD060 (table style): Add spaces around ALL pipes in separator rows:
  - WRONG: |--------|------|
  - RIGHT: | ------ | ---- |
- Tables: When shortening, preserve meaning. Abbreviate consistently.

RULES:
1. Use targeted Edit operations - fix specific lines, never rewrite entire file
2. For tables: edit the ENTIRE row in one Edit to keep columns consistent
3. The hook pipeline will auto-format and re-run validation after your edits


Be concise. No explanations in the file."
  elif [[ "${ftype}" == "python" ]] && echo "${prompt_violations_json}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    # Python with docstring violations - specialized prompt
    # __init__.py-specific D100 hint (conditional)
    local init_hint=""
    if [[ "$(basename "${fp}")" == "__init__.py" ]]; then
      init_hint=$'\n- For __init__.py: D100 needs module docstring at top of file. Keep minimal (one-line).'
    fi
    prompt="You are a docstring fixer. Fix ALL docstring violations in ${fp}.

VIOLATIONS:
${prompt_violations_json}

DOCSTRING FIX STRATEGIES:
- D401 (imperative mood): Change 'Returns the value' -> 'Return the value', 'Gets data' -> 'Get data'
- D417 (missing Args): Add Args section with parameter descriptions from function signature
- D205 (blank line): Add blank line after one-line summary
- D400/D415 (trailing punctuation): Add period at end of first line
- D301 (backslash): Use raw docstring r\"\"\" for regex patterns
- D100/D104 (module/package): Add module-level docstring at file start${init_hint}
- D107 (__init__): Add docstring explaining initialization parameters

RULES:
1. Use targeted Edit operations - fix specific docstrings, never rewrite entire file
2. Preserve existing docstring content, only fix the specific violation
3. Follow Google docstring style (Args:, Returns:, Raises:)
4. The hook pipeline will auto-format and re-run validation after your edits


Be concise. Fix docstrings only, do not refactor code."
  elif [[ "${ftype}" == "elixir" ]]; then
    # Elixir/Phoenix-specific prompt with fix strategies
    prompt="You are an Elixir/Phoenix code quality fixer. Fix ALL violations in ${fp}.

VIOLATIONS:
${prompt_violations_json}

ELIXIR FIX STRATEGIES:
- Credo.Check.Readability.*: Fix naming conventions, alias ordering, pipe chains, module doc
- Credo.Check.Refactor.*: Extract functions, reduce nesting, simplify conditionals
- Credo.Check.Warning.*: Fix unused returns, unsafe operations, IO.inspect leftovers
- Credo.Check.Design.*: Reduce function arity, tag TODOs, avoid aliasing core modules
- SOBELOW_*: Phoenix security fixes (CSRF tokens, parameterized queries, safe redirects)
- MIX_FORMAT: Code was not formatted per project .formatter.exs
- MIX_COMPILE: Fix compiler warnings (unused vars, undefined functions, spec mismatches)
- LV_PUBSUB_NO_CONNECTED: Wrap PubSub.subscribe in 'if connected?(socket), do:' guard
- LV_REPO_IN_LIVEVIEW: Move Repo/Ecto queries to a context module, call context from LiveView
- LV_GENERIC_EVENT_PARAMS: Pattern match on params map instead of binding to generic variable
- LV_MISSING_IMPL: Add @impl true annotation above LiveView callbacks (mount, render, handle_*)
- LV_LIST_WITHOUT_STREAM: Replace assign(:key, list) with stream(:key, list) for large lists
- LV_UNUSED_ASSIGN: Remove unused assign or reference it in the template with @key
- DEPS_AUDIT: Update vulnerable dependency versions in mix.exs
- XREF_UNREACHABLE: Remove unreachable function calls or fix module references
- XREF_DEPRECATED: Replace deprecated function calls with their modern equivalents

RULES:
1. Use targeted Edit operations - fix specific functions/lines, never rewrite entire file
2. Follow Elixir conventions: pipe operator for transforms, pattern matching over conditionals
3. Keep context boundaries: LiveViews call contexts, contexts call Repo
4. The hook pipeline will run mix format and re-validate after your edits
5. If a violation cannot be fixed without major refactoring, explain why

Be concise. Do not add explanatory comments. Do not refactor beyond what is needed."
  else
    # Generic prompt for other file types
    prompt="You are a code quality fixer. Fix ALL violations listed below in ${fp}.

VIOLATIONS:
${prompt_violations_json}

RULES:
1. Use targeted Edit operations only - never rewrite the entire file
2. Fix each violation at its reported line/column
3. The hook pipeline will auto-format and re-run validation after your edits

4. If a violation cannot be fixed, explain why

Do not add comments explaining fixes. Do not refactor beyond what's needed."
  fi

  # Dispatch to agent-specific delegate
  echo "[hook:subprocess] model=${model} tools=${tier_tools} max_turns=${tier_max_turns} timeout=${tier_timeout}" >&2
  local delegate_started=${SECONDS}
  hook_diag "phase=delegate_start tool=${tool_name} file=${fp} ftype=${ftype} model=${model} max_turns=${tier_max_turns} timeout=${tier_timeout} allowed_tools=${tier_tools} count=${prompt_count} codes=${prompt_codes}"

  delegate_with_agent "${fp}" "${prompt}" "${model}" "${tier_tools}" "${tier_max_turns}" "${tier_timeout}"

  local delegate_duration=$((SECONDS - delegate_started))
  hook_diag "phase=delegate_end tool=${tool_name} file=${fp} ftype=${ftype} model=${model} duration_s=${delegate_duration}"
}

# Re-run Phase 1 auto-fix for a file type
rerun_phase1() {
  local fp="$1"
  local ftype="$2"

  case "${ftype}" in
    python)
      command -v ruff >/dev/null 2>&1 && {
        ruff format --quiet "${fp}" >/dev/null 2>&1 || true
        ruff check --fix --quiet "${fp}" >/dev/null 2>&1 || true
      }
      ;;
    shell)
      command -v shfmt >/dev/null 2>&1 && {
        shfmt -w -i 2 -ci -bn "${fp}" 2>/dev/null || true
      }
      ;;
    elixir)
      if command -v mix >/dev/null 2>&1; then
        local mix_root
        mix_root=$(find_mix_project_root "${fp}" 2>/dev/null) || mix_root=""
        if [[ -n "${mix_root}" ]]; then
          local rel_path
          rel_path=$(elixir_mix_relpath "${mix_root}" "${fp}")
          run_mix_format_file "${mix_root}" "${rel_path}" >/dev/null 2>&1 || true
        fi
      fi
      ;;
    toml)
      command -v taplo >/dev/null 2>&1 && {
        RUST_LOG=error taplo fmt "${fp}" 2>/dev/null || true
      }
      ;;
    markdown)
      command -v markdownlint-cli2 >/dev/null 2>&1 && {
        markdownlint-cli2 --no-globs --fix "${fp}" 2>/dev/null || true
      }
      ;;
    json)
      # Re-validate and format if valid
      # Use Biome if TS enabled and available (D6), fallback to jaq pretty-print
      if jaq empty "${fp}" 2>/dev/null; then
        local json_done=false
        if is_typescript_enabled; then
          local _biome_cmd
          _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
          if [[ -n "${_biome_cmd}" ]]; then
            ${_biome_cmd} format --write "${fp}" >/dev/null 2>&1 && json_done=true
          fi
        fi
        if [[ "${json_done}" == "false" ]]; then
          local tmp_file
          tmp_file=$(mktemp) || return
          if jaq '.' "${fp}" >"${tmp_file}" 2>/dev/null; then
            if ! cmp -s "${fp}" "${tmp_file}"; then
              mv "${tmp_file}" "${fp}"
            else
              rm -f "${tmp_file}"
            fi
          else
            rm -f "${tmp_file}"
          fi
        fi
      fi
      ;;
    typescript)
      local _biome_cmd
      _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
      if [[ -n "${_biome_cmd}" ]]; then
        local _unsafe_flag=""
        local _unsafe
        _unsafe=$(get_ts_config "biome_unsafe_autofix" "false")
        [[ "${_unsafe}" == "true" ]] && _unsafe_flag="--unsafe"
        local rel_path
        rel_path=$(_biome_relpath "${fp}")
        if [[ -n "${_unsafe_flag}" ]]; then
          (cd "${PROJECT_DIR}" && ${_biome_cmd} check --write "${_unsafe_flag}" "${rel_path}") >/dev/null 2>&1 || true
        else
          (cd "${PROJECT_DIR}" && ${_biome_cmd} check --write "${rel_path}") >/dev/null 2>&1 || true
        fi
      fi
      ;;
    *) ;; # No Phase 1 for yaml, dockerfile
  esac
}

# Re-run Phase 2 and return violation count
rerun_phase2() {
  local fp="$1"
  local ftype="$2"
  local count=0
  RERUN_PHASE2_RAW=""
  RERUN_PHASE2_COUNT=0
  RERUN_PHASE2_CODES=""

  case "${ftype}" in
    python)
      local all_codes=""

      # Ruff violations
      local v
      v=$(ruff check --preview --output-format=json "${fp}" 2>/dev/null) || true
      count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
      RERUN_PHASE2_RAW="${v}"
      local ruff_codes
      # shellcheck disable=SC2016
      ruff_codes=$(echo "${v}" | jaq -r '[.[].code // empty] | unique | join(", ")' 2>/dev/null) || ruff_codes=""
      [[ -n "${ruff_codes}" ]] && all_codes="${ruff_codes}"

      # ty violations (uv run for project venv)
      if command -v uv >/dev/null 2>&1; then
        local ty_out
        ty_out=$(uv run ty check --output-format gitlab "${fp}" 2>/dev/null) || true
        local ty_count
        ty_count=$(echo "${ty_out}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        count=$((count + ty_count))
        local ty_codes=""
        if [[ "${ty_count}" -gt 0 ]]; then
          # shellcheck disable=SC2016
          ty_codes=$(echo "${ty_out}" | jaq -r '[.[].check_name // empty] | unique | join(", ")' 2>/dev/null) || ty_codes=""
          [[ -z "${ty_codes}" ]] && ty_codes=$(echo "${ty_out}" | grep -oE '\[[a-z-]+\]' | tr -d '[]' | sort -u | paste -sd ', ' -) || true
        fi
        [[ -n "${ty_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${ty_codes}"
      fi

      # flake8-pydantic violations (uv run for project venv)
      if command -v uv >/dev/null 2>&1; then
        local pyd_out
        pyd_out=$(uv run flake8 --select=PYD "${fp}" 2>/dev/null || true)
        if [[ -n "${pyd_out}" ]]; then
          local pyd_count
          pyd_count=$(echo "${pyd_out}" | wc -l | tr -d ' ')
          count=$((count + pyd_count))
          local pyd_codes=""
          pyd_codes=$(echo "${pyd_out}" | grep -oE 'PYD[0-9]+' | sort -u | paste -sd ', ' -) || pyd_codes=""
          [[ -n "${pyd_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${pyd_codes}"
        fi
      fi

      # vulture violations
      if command -v uv >/dev/null 2>&1; then
        local vulture_out
        vulture_out=$(uv run vulture "${fp}" --min-confidence 80 2>/dev/null || true)
        if [[ -n "${vulture_out}" ]]; then
          local vulture_count
          vulture_count=$(echo "${vulture_out}" | wc -l | tr -d ' ')
          count=$((count + vulture_count))
          [[ -n "${vulture_out}" ]] && all_codes="${all_codes:+${all_codes}, }unused-code"
        fi
      fi

      # bandit violations
      if command -v uv >/dev/null 2>&1; then
        local bandit_out
        bandit_out=$(run_bandit_json "${fp}")
        local bandit_count
        bandit_count=$(echo "${bandit_out}" | jaq '.results | length // 0' 2>/dev/null | head -n1 || echo "0")
        count=$((count + bandit_count))
        local bandit_codes=""
        if [[ "${bandit_count}" -gt 0 ]]; then
          # shellcheck disable=SC2016
          bandit_codes=$(echo "${bandit_out}" | jaq -r '[.results[].test_id // empty] | unique | join(", ")' 2>/dev/null) || bandit_codes=""
        fi
        [[ -n "${bandit_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${bandit_codes}"
      fi

      # flake8-async violations
      if command -v uv >/dev/null 2>&1; then
        local async_out
        async_out=$(uv run flake8 --select=ASYNC "${fp}" 2>/dev/null || true)
        if [[ -n "${async_out}" ]]; then
          local async_count
          async_count=$(echo "${async_out}" | wc -l | tr -d ' ')
          count=$((count + async_count))
          local async_codes=""
          async_codes=$(echo "${async_out}" | grep -oE 'ASYNC[0-9]+' | sort -u | paste -sd ', ' -) || async_codes=""
          [[ -n "${async_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${async_codes}"
        fi
      fi

      RERUN_PHASE2_CODES="${all_codes}"
      ;;
    shell)
      if command -v shellcheck >/dev/null 2>&1; then
        local v
        v=$(shellcheck -f json "${fp}" 2>/dev/null) || true
        count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    elixir)
      local all_codes=""
      if command -v mix >/dev/null 2>&1; then
        local mix_root
        mix_root=$(find_mix_project_root "${fp}" 2>/dev/null) || mix_root=""
        if [[ -n "${mix_root}" ]]; then
          local rel_path
          rel_path=$(elixir_mix_relpath "${mix_root}" "${fp}")

          local format_out=""
          local format_rc=0
          format_out=$(run_mix_format_check_file "${mix_root}" "${rel_path}" 2>&1) || format_rc=$?
          if [[ ${format_rc} -ne 0 ]]; then
            count=$((count + 1))
            RERUN_PHASE2_RAW="${format_out}"
            all_codes="MIX_FORMAT"
          fi

          local credo_enabled
          credo_enabled=$(get_elixir_config "credo" "true")
          if [[ "${credo_enabled}" != "false" ]] && is_elixir_source_file "${fp}" && mix_task_available "${mix_root}" "credo"; then
            local credo_out
            credo_out=$(run_mix_credo_json "${mix_root}" "${rel_path}")
            local credo_count
            credo_count=$(echo "${credo_out}" | jaq '.explanations | length // 0' 2>/dev/null | head -n1 || echo "0")
            count=$((count + credo_count))
            if [[ "${credo_count}" -gt 0 ]]; then
              local credo_codes=""
              credo_codes=$(echo "${credo_out}" | jaq -r '[.explanations[]?.check // empty] | unique | join(", ")' 2>/dev/null) || credo_codes=""
              [[ -n "${credo_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${credo_codes}"
              RERUN_PHASE2_RAW="${credo_out}"
            fi
          fi

          # Sobelow recount (project-level, only if previously triggered)
          local sobelow_enabled
          sobelow_enabled=$(get_elixir_config "sobelow" "true")
          if [[ "${sobelow_enabled}" != "false" ]] && mix_task_available "${mix_root}" "sobelow"; then
            local sobelow_out
            sobelow_out=$(run_sobelow_json "${mix_root}")
            local sobelow_count
            sobelow_count=$(echo "${sobelow_out}" | jaq '.findings | length // 0' 2>/dev/null | head -n1 || echo "0")
            count=$((count + sobelow_count))
            if [[ "${sobelow_count}" -gt 0 ]]; then
              all_codes="${all_codes:+${all_codes}, }SOBELOW"
            fi
          fi

          # Compile warnings recount
          local compile_warnings_enabled
          compile_warnings_enabled=$(get_elixir_config "mix_compile_warnings" "false")
          if [[ "${compile_warnings_enabled}" == "true" ]] && is_elixir_source_file "${fp}"; then
            local compile_out
            compile_out=$(run_mix_compile_warnings "${mix_root}" "${rel_path}")
            if [[ -n "${compile_out}" ]]; then
              local compile_count
              compile_count=$(echo "${compile_out}" | wc -l | tr -d ' ')
              count=$((count + compile_count))
              [[ "${compile_count}" -gt 0 ]] && all_codes="${all_codes:+${all_codes}, }MIX_COMPILE"
            fi
          fi
        fi
      fi

      # LiveView anti-pattern recount
      if is_elixir_source_file "${fp}"; then
        local lv_recount
        lv_recount=$(detect_liveview_antipatterns "${fp}")
        if [[ -n "${lv_recount}" ]] && [[ "${lv_recount}" != "[]" ]]; then
          local lv_count
          lv_count=$(echo "${lv_recount}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
          count=$((count + lv_count))
          local lv_codes
          lv_codes=$(echo "${lv_recount}" | jaq -r '[.[].code] | unique | join(", ")' 2>/dev/null) || lv_codes=""
          [[ -n "${lv_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${lv_codes}"
        fi
      fi
      RERUN_PHASE2_CODES="${all_codes}"
      ;;
    yaml)
      if command -v yamllint >/dev/null 2>&1; then
        local v
        v=$(yamllint -f parsable "${fp}" 2>/dev/null || true)
        [[ -n "${v}" ]] && count=$(echo "${v}" | wc -l | tr -d ' ')
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    json)
      # Check syntax only
      if ! jaq empty "${fp}" 2>/dev/null; then
        count=1
      fi
      ;;
    toml)
      if command -v taplo >/dev/null 2>&1; then
        local v
        v=$(RUST_LOG=error taplo check "${fp}" 2>&1) || true
        [[ -n "${v}" ]] && count=1
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    markdown)
      if command -v markdownlint-cli2 >/dev/null 2>&1; then
        local v
        v=$(markdownlint-cli2 --no-globs "${fp}" 2>&1 || true)
        if [[ -n "${v}" ]] && ! echo "${v}" | grep -q "Summary: 0 error"; then
          count=$(echo "${v}" | grep -c ":" || echo "1")
        fi
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    dockerfile)
      if command -v hadolint >/dev/null 2>&1; then
        local v
        v=$(hadolint --no-color -f json "${fp}" 2>/dev/null) || true
        count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    typescript)
      local _biome_cmd
      _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
      if [[ -n "${_biome_cmd}" ]]; then
        local biome_out
        local rel_path
        rel_path=$(_biome_relpath "${fp}")
        biome_out=$( (cd "${PROJECT_DIR}" && ${_biome_cmd} lint --reporter=json "${rel_path}") 2>/dev/null || true)
        if [[ -n "${biome_out}" ]]; then
          count=$(echo "${biome_out}" | jaq '[(.diagnostics // [])[] |
            select(.severity == "error" or .severity == "warning")] | length' 2>/dev/null | head -n1 || echo "0")
        fi
        RERUN_PHASE2_RAW="${biome_out}"
      fi
      ;;
    *) ;; # Unknown file type
  esac

  RERUN_PHASE2_COUNT="${count}"
}

# Extract violation codes from RERUN_PHASE2_RAW for directive messages.
# Sets global VIOLATION_CODES (comma-separated string).
extract_violation_codes() {
  local ftype="$1"
  VIOLATION_CODES=""

  if [[ -z "${RERUN_PHASE2_RAW:-}" ]] && [[ -z "${RERUN_PHASE2_CODES:-}" ]]; then
    return
  fi

  case "${ftype}" in
    python)
      if [[ -n "${RERUN_PHASE2_CODES:-}" ]]; then
        VIOLATION_CODES="${RERUN_PHASE2_CODES}"
      else
        # shellcheck disable=SC2016 # jaq uses $var, not shell
        VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[].code] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      fi
      ;;
    shell)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[] | "SC" + (.code | tostring)] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    elixir)
      if [[ -n "${RERUN_PHASE2_CODES:-}" ]]; then
        VIOLATION_CODES="${RERUN_PHASE2_CODES}"
      fi
      ;;
    markdown)
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | grep -oE 'MD[0-9]+(/[a-z-]+)?' | sort -u | paste -sd ', ' -) || VIOLATION_CODES=""
      ;;
    yaml)
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | grep -oE '\([^)]+\)' | tr -d '()' | sort -u | paste -sd ', ' -) || VIOLATION_CODES=""
      ;;
    dockerfile)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[].code] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    toml)
      VIOLATION_CODES="TOML_SYNTAX"
      ;;
    typescript)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[(.diagnostics // [])[] | .category // empty] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    *) ;;
  esac
}

# ============================================================================
# TYPESCRIPT HANDLER
# ============================================================================

# Semgrep session-scoped helper (D2, D11)
_handle_semgrep_session() {
  local fp="$1"
  local semgrep_enabled
  semgrep_enabled=$(get_ts_config "semgrep" "true")
  [[ "${semgrep_enabled}" == "false" ]] && return

  local session_file="/tmp/.semgrep_session_${SESSION_PID}"
  echo "${fp}" >>"${session_file}" 2>/dev/null || true

  if [[ -f "${session_file}" ]]; then
    local file_count
    file_count=$(wc -l <"${session_file}" 2>/dev/null | tr -d ' ')
    if [[ "${file_count}" -ge 3 ]] && [[ ! -f "${session_file}.done" ]]; then
      touch "${session_file}.done"
      if command -v semgrep >/dev/null 2>&1 && [[ -f "${PROJECT_DIR}/.semgrep.yml" ]]; then
        local semgrep_files
        semgrep_files=$(sort -u "${session_file}" | tr '\n' ' ') || semgrep_files=""
        local semgrep_result
        # shellcheck disable=SC2086  # Intentional word splitting for file list
        semgrep_result=$(semgrep --json --config "${PROJECT_DIR}/.semgrep.yml" \
          ${semgrep_files} 2>/dev/null || true)
        if [[ -n "${semgrep_result}" ]]; then
          local finding_count
          finding_count=$(echo "${semgrep_result}" | jaq '.results | length' 2>/dev/null | head -n1 || echo "0")
          if [[ "${finding_count}" -gt 0 ]]; then
            {
              echo ""
              echo "[hook:advisory] Semgrep: ${finding_count} security finding(s)"
              echo "Run 'semgrep --config .semgrep.yml' for details."
              echo ""
            } >&2
          fi
        fi
      fi
    fi
  fi
}

# jscpd session-scoped helper for TypeScript (D17)
_handle_jscpd_ts_session() {
  local fp="$1"
  local session_file="/tmp/.jscpd_ts_session_${SESSION_PID}"
  echo "${fp}" >>"${session_file}" 2>/dev/null || true

  if [[ -f "${session_file}" ]]; then
    local file_count
    file_count=$(wc -l <"${session_file}" 2>/dev/null | tr -d ' ')
    if [[ "${file_count}" -ge 3 ]] && [[ ! -f "${session_file}.done" ]]; then
      touch "${session_file}.done"
      if command -v npx >/dev/null 2>&1; then
        local jscpd_result
        jscpd_result=$(npx jscpd --config .jscpd.json --reporters json \
          --silent 2>/dev/null || true)
        if [[ -n "${jscpd_result}" ]]; then
          local clone_count
          clone_count=$(echo "${jscpd_result}" \
            | jaq -r 'if .statistics then .statistics.total.clones else if .statistic then .statistic.total.clones else 0 end end' 2>/dev/null || echo "0")
          if [[ "${clone_count}" -gt 0 ]]; then
            {
              echo ""
              echo "[hook:advisory] Duplicate code detected (TS/JS)"
              echo "Clone pairs found: ${clone_count}"
              echo "Run 'npx jscpd --config .jscpd.json' for details."
              echo ""
            } >&2
          fi
        fi
      fi
    fi
  fi
}

# Nursery mismatch validation (D9)
_validate_nursery_config() {
  local biome_cmd="$1"
  local biome_json="${PROJECT_DIR}/biome.json"
  [[ ! -f "${biome_json}" ]] && return

  local config_nursery
  config_nursery=$(get_ts_config "biome_nursery" "warn")
  local biome_nursery
  biome_nursery=$(jaq -r '.linter.rules.nursery // "off"' "${biome_json}" 2>/dev/null || echo "")

  # Object-valued nursery is fully controlled by biome.json — string comparison not applicable
  [[ "${biome_nursery}" == "{"* || "${biome_nursery}" == "["* ]] && return
  # Normalize: biome.json uses severity strings, config.json uses warn/error/off
  if [[ -n "${biome_nursery}" ]] && [[ "${biome_nursery}" != "null" ]] \
    && [[ "${config_nursery}" != "${biome_nursery}" ]]; then
    echo "[hook:warning] config.json biome_nursery='${config_nursery}' but biome.json nursery='${biome_nursery}' — behavior follows biome.json" >&2
  fi
}

# Biome project-domain rules (nursery) require relative paths (biome 2.3.x).
# Convert absolute path to relative for biome invocations.
_biome_relpath() {
  local abs="$1"
  local base="${PROJECT_DIR}"
  if [[ "${abs}" == "${base}/"* ]]; then
    echo "${abs#"${base}/"}"
  else
    echo "[hook:warning] file outside project root, biome project rules may not apply" >&2
    echo "${abs}"
  fi
}

# Main TypeScript handler (D1, D4, D7, D9-D11)
handle_typescript() {
  local fp="$1"
  local ext="${fp##*.}"
  local _merged

  # Detect Biome
  local biome_cmd
  biome_cmd=$(detect_biome 2>/dev/null) || biome_cmd=""

  # SFC handling (D4): .vue/.svelte/.astro -> Semgrep only, skip Biome
  case "${ext}" in
    vue | svelte | astro)
      local sfc_warned="/tmp/.sfc_warned_${ext}_${SESSION_PID}"
      if [[ ! -f "${sfc_warned}" ]]; then
        touch "${sfc_warned}"
        if ! command -v semgrep >/dev/null 2>&1; then
          echo "[hook:warning] No linter available for .${ext} files. Install semgrep for security scanning: brew install semgrep" >&2
        fi
      fi
      # Run Semgrep session tracking only for SFC files
      _handle_semgrep_session "${fp}"
      return
      ;;
    *) ;;
  esac

  # Biome required for non-SFC TS/JS/CSS files
  if [[ -z "${biome_cmd}" ]]; then
    echo "[hook:warning] biome not found. Install: npm i -D @biomejs/biome" >&2
    return
  fi

  # One-time nursery config validation per session
  local nursery_checked="/tmp/.nursery_checked_${SESSION_PID}"
  if [[ ! -f "${nursery_checked}" ]]; then
    touch "${nursery_checked}"
    _validate_nursery_config "${biome_cmd}"
  fi

  # Phase 1: Auto-format (silent) (D1, D10)
  if is_auto_format_enabled; then
    local unsafe_config
    unsafe_config=$(get_ts_config "biome_unsafe_autofix" "false")
    local rel_path
    rel_path=$(_biome_relpath "${fp}")
    if [[ "${unsafe_config}" == "true" ]]; then
      (cd "${PROJECT_DIR}" && ${biome_cmd} check --write --unsafe "${rel_path}") >/dev/null 2>&1 || true
    else
      (cd "${PROJECT_DIR}" && ${biome_cmd} check --write "${rel_path}") >/dev/null 2>&1 || true
    fi
  fi

  # Phase 2a: Biome lint (blocking) (D1, D3)
  # D3: When oxlint enabled, skip 3 overlapping nursery rules
  local biome_lint_args=("lint" "--reporter=json")
  local oxlint_enabled
  oxlint_enabled=$(get_ts_config "oxlint_tsgolint" "false")
  if [[ "${oxlint_enabled}" == "true" ]]; then
    biome_lint_args+=("--skip=nursery/noFloatingPromises")
    biome_lint_args+=("--skip=nursery/noMisusedPromises")
    biome_lint_args+=("--skip=nursery/useAwaitThenable")
  fi
  local biome_output
  local rel_path_lint
  rel_path_lint=$(_biome_relpath "${fp}")
  biome_output=$( (cd "${PROJECT_DIR}" && ${biome_cmd} "${biome_lint_args[@]}" "${rel_path_lint}") 2>/dev/null || true)

  if [[ -n "${biome_output}" ]]; then
    local diag_count
    diag_count=$(echo "${biome_output}" | jaq '.diagnostics | length' 2>/dev/null | head -n1 || echo "0")

    if [[ "${diag_count}" -gt 0 ]]; then
      # Convert Biome diagnostics to standard format
      # Biome uses byte offsets in span; convert to line/column via sourceCode
      local biome_violations
      biome_violations=$(echo "${biome_output}" | jaq '[(.diagnostics // [])[] |
        select(.severity == "error" or .severity == "warning") |
        select(.location.span != null) |
        {
          line: ((.location.sourceCode[0:.location.span[0]] // "") | split("\n") | length),
          column: (((.location.sourceCode[0:.location.span[0]] // "") | split("\n") | last | length) + 1),
          code: .category,
          message: .description,
          linter: "biome"
        }]' 2>/dev/null) || biome_violations="[]"

      if [[ "${biome_violations}" != "[]" ]] && [[ -n "${biome_violations}" ]]; then
        _merged=$(echo "${collected_violations}" "${biome_violations}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi

      # Phase 2b: Nursery advisory count (D9)
      local nursery_mode
      nursery_mode=$(get_ts_config "biome_nursery" "warn")
      if [[ "${nursery_mode}" == "warn" ]]; then
        local nursery_count
        nursery_count=$(echo "${biome_output}" | jaq '[(.diagnostics // [])[] |
          select(.category | startswith("lint/nursery/"))] | length' 2>/dev/null | head -n1 || echo "0")
        if [[ "${nursery_count}" -gt 0 ]]; then
          echo "[hook:advisory] Biome nursery: ${nursery_count} diagnostic(s)" >&2
        fi
      fi
    fi
  fi

  # Phase 2c: Semgrep session-scoped (D2, D11) — CSS excluded per ADR D4
  [[ "${ext}" != "css" ]] && _handle_semgrep_session "${fp}"

  # Phase 2d: jscpd session-scoped (D17)
  _handle_jscpd_ts_session "${fp}"
}

# Determine file type for delegation
# NOTE: .github/workflows/*.yml files are handled as generic YAML (yamllint only).
# Full GitHub Actions validation (actionlint, check-jsonschema) runs at commit-time
# via pre-commit, not here. Rationale: workflow files are rarely edited during
# Pi sessions; yamllint covers syntax; specialized validation at commit-time.
case "${file_path}" in
  *.py) file_type="python" ;;
  *.ex | *.exs | *.heex | *.leex | *.eex) file_type="elixir" ;;
  *.sh | *.bash) file_type="shell" ;;
  *.yml | *.yaml) file_type="yaml" ;;
  *.json) file_type="json" ;;
  *.toml) file_type="toml" ;;
  *.md | *.mdx) file_type="markdown" ;;
  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.css) file_type="typescript" ;;
  *.vue | *.svelte | *.astro) file_type="typescript" ;;
  Dockerfile | Dockerfile.* | */Dockerfile | */Dockerfile.* | *.dockerfile | *.Dockerfile) file_type="dockerfile" ;;
  *.ipynb) exit_json ;; # Notebook — no cell-level linting
  *) exit_json ;;       # Unsupported
esac

# Determine file type and run appropriate linter
case "${file_path}" in
  *.py)
    is_language_enabled "python" || exit_json

    # Python: Phase 1 - Auto-format and auto-fix (silent)
    if is_auto_format_enabled && command -v ruff >/dev/null 2>&1; then
      # Format code (spacing, quotes, line length) - suppress all output
      ruff format --quiet "${file_path}" >/dev/null 2>&1 || true
      # Auto-fix linting issues (unused imports, sorting, blank lines) - suppress all output
      ruff check --fix --quiet "${file_path}" >/dev/null 2>&1 || true
    fi

    # Python: Phase 2 - Collect unfixable issues per pyproject.toml config
    # Note: No --select override - pyproject.toml is single source of truth
    ruff_violations=$(ruff check --preview --output-format=json "${file_path}" 2>/dev/null || true)
    if [[ -n "${ruff_violations}" ]] && [[ "${ruff_violations}" != "[]" ]]; then
      # Convert raw ruff JSON to unified {line,column,code,message,linter} schema
      ruff_converted=$(echo "${ruff_violations}" | jaq '[.[] | {
        line: .location.row,
        column: .location.column,
        code: .code,
        message: .message,
        linter: "ruff"
      }]' 2>/dev/null) || ruff_converted="[]"
      if [[ -n "${ruff_converted}" ]] && [[ "${ruff_converted}" != "[]" ]]; then
        _merged=$(echo "${collected_violations}" "${ruff_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Python: Phase 2b - Type checking with ty (complementary to ruff)
    # NOTE: Line numbers may differ from source due to ruff format running
    # first. This is expected - the location still helps identify the issue.
    # Uses uv run to leverage project's venv (thin wrapper principle)
    if command -v uv >/dev/null 2>&1; then
      ty_output=$(uv run ty check --output-format gitlab "${file_path}" \
        2>/dev/null || true)
      if [[ -n "${ty_output}" ]] && [[ "${ty_output}" != "[]" ]]; then
        # Convert ty gitlab format to standard format and merge
        ty_converted=$(echo "${ty_output}" | jaq '[.[] | {
          line: .location.positions.begin.line,
          column: .location.positions.begin.column,
          code: .check_name,
          message: .description,
          linter: "ty"
        }]' 2>/dev/null) || ty_converted="[]"
        _merged=$(echo "${collected_violations}" "${ty_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Python: Phase 2c - Duplicate detection (advisory, session-scoped)
    # Only runs once per session after 3+ Python files modified
    jscpd_session="/tmp/.jscpd_session_${SESSION_PID}"
    echo "${file_path}" >>"${jscpd_session}" 2>/dev/null || true

    if [[ -f "${jscpd_session}" ]]; then
      jscpd_count=$(wc -l <"${jscpd_session}" 2>/dev/null | tr -d ' ')
      if [[ "${jscpd_count}" -ge 3 ]] && [[ ! -f "${jscpd_session}.done" ]]; then
        touch "${jscpd_session}.done"
        if command -v npx >/dev/null 2>&1; then
          jscpd_result=$(npx jscpd --config .jscpd.json --reporters json \
            --silent 2>/dev/null || true)
          if [[ -n "${jscpd_result}" ]]; then
            # jscpd 4.0.7+ uses .statistics; older versions use .statistic (fallback chain)
            clone_count=$(echo "${jscpd_result}" \
              | jaq -r 'if .statistics then .statistics.total.clones else if .statistic then .statistic.total.clones else 0 end end' 2>/dev/null || echo "0")
            if [[ "${clone_count}" -gt 0 ]]; then
              {
                echo ""
                echo "[hook:advisory] Duplicate code detected"
                echo "Clone pairs found: ${clone_count}"
                echo ""
                echo "Run 'npx jscpd --config .jscpd.json' for details."
                echo ""
              } >&2
              # Advisory only - does NOT set has_issues=true
            fi
          fi
        fi
      fi
    fi

    # Python: Phase 2d - Pydantic model linting with flake8-pydantic
    # Note: Uses .flake8 config for per-file-ignores
    # Uses uv run to leverage project's venv (thin wrapper principle)
    if command -v uv >/dev/null 2>&1; then
      pydantic_output=$(uv run flake8 --select=PYD "${file_path}" 2>/dev/null || true)
      if [[ -n "${pydantic_output}" ]]; then
        # Convert flake8 output to JSON format (file:line:col: CODE message)
        # shellcheck disable=SC2016
        pyd_json=$(echo "${pydantic_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          code=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: ([A-Z0-9]+) .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: [A-Z0-9]+ (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"flake8-pydantic"}'
        done | jaq -s '.') || pyd_json="[]"
        if [[ -n "${pyd_json}" ]]; then
          _merged=$(echo "${collected_violations}" "${pyd_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2e - Dead code detection with vulture
    # Detects unused functions, variables, classes. Config in pyproject.toml [tool.vulture].
    # Skip excluded paths (tests, scripts, etc.) to avoid false positives
    _excluded_vulture=false
    # shellcheck disable=SC2310  # Intentionally capturing return value, not propagating errors
    is_excluded_from_security_linters "${file_path}" && _vulture_rc=0 || _vulture_rc=$?
    if [[ ${_vulture_rc} -eq 0 ]]; then _excluded_vulture=true; fi
    if ! "${_excluded_vulture}" && command -v uv >/dev/null 2>&1; then
      vulture_output=$(uv run vulture "${file_path}" --min-confidence 80 2>/dev/null || true)
      if [[ -n "${vulture_output}" ]]; then
        # Convert vulture output to JSON (file:line: message pattern)
        # shellcheck disable=SC2016
        vulture_json=$(echo "${vulture_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+): .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+: (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg m "${msg}" \
            '{line:($l|tonumber),column:1,code:"VULTURE",message:$m,linter:"vulture"}'
        done | jaq -s '.') || vulture_json="[]"
        if [[ -n "${vulture_json}" ]] && [[ "${vulture_json}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${vulture_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2f - Security scanning with bandit
    # Detects common security issues (hardcoded passwords, SQL injection, etc.)
    # Skip excluded paths (tests, scripts, etc.) to avoid false positives
    _excluded_bandit=false
    # shellcheck disable=SC2310  # Intentionally capturing return value, not propagating errors
    is_excluded_from_security_linters "${file_path}" && _bandit_rc=0 || _bandit_rc=$?
    if [[ ${_bandit_rc} -eq 0 ]]; then _excluded_bandit=true; fi
    if ! "${_excluded_bandit}" && command -v uv >/dev/null 2>&1; then
      bandit_output=$(run_bandit_json "${file_path}")
      bandit_results=$(echo "${bandit_output}" | jaq '.results // []' 2>/dev/null) || bandit_results="[]"
      if [[ "${bandit_results}" != "[]" ]] && [[ "${bandit_results}" != "null" ]]; then
        # Convert bandit JSON to standard format
        bandit_converted=$(echo "${bandit_results}" | jaq '[.[] | {
          line: .line_number,
          column: (.col_offset // 1),
          code: .test_id,
          message: .issue_text,
          linter: "bandit"
        }]' 2>/dev/null) || bandit_converted="[]"
        if [[ -n "${bandit_converted}" ]] && [[ "${bandit_converted}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${bandit_converted}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2g - Async pattern linting with flake8-async
    # Detects missing await checkpoints, timeout parameter issues, etc.
    if command -v uv >/dev/null 2>&1; then
      async_output=$(uv run flake8 --select=ASYNC "${file_path}" 2>/dev/null || true)
      if [[ -n "${async_output}" ]]; then
        # shellcheck disable=SC2016
        async_json=$(echo "${async_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          code=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: ([A-Z0-9]+) .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: [A-Z0-9]+ (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" \
            --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"flake8-async"}'
        done | jaq -s '.') || async_json="[]"
        if [[ -n "${async_json}" ]]; then
          _merged=$(echo "${collected_violations}" \
            "${async_json}" | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;

  *.ex | *.exs | *.heex | *.leex | *.eex)
    is_elixir_enabled || exit_json

    mix_root=$(find_mix_project_root "${file_path}" 2>/dev/null || true)
    mix_rel_path=""
    [[ -n "${mix_root}" ]] && mix_rel_path=$(elixir_mix_relpath "${mix_root}" "${file_path}")

    if is_auto_format_enabled && command -v mix >/dev/null 2>&1 && [[ -n "${mix_root}" ]]; then
      mix_format_output=""
      mix_format_rc=0
      mix_format_output=$(run_mix_format_file "${mix_root}" "${mix_rel_path}" 2>&1) || mix_format_rc=$?
      if [[ ${mix_format_rc} -ne 0 ]]; then
        [[ -z "${mix_format_output}" ]] && mix_format_output="mix format failed for ${mix_rel_path}"
        # shellcheck disable=SC2016 # jaq uses $m, not shell
        mix_format_violation=$(jaq -n --arg m "${mix_format_output}" \
          '[{line:1,column:1,code:"MIX_FORMAT",message:$m,linter:"mix format"}]') || mix_format_violation="[]"
        _merged=$(echo "${collected_violations}" "${mix_format_violation}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    credo_enabled=$(get_elixir_config "credo" "true")
    if [[ "${credo_enabled}" != "false" ]] && is_elixir_source_file "${file_path}" && command -v mix >/dev/null 2>&1 \
      && [[ -n "${mix_root}" ]] && mix_task_available "${mix_root}" "credo"; then
      credo_output=$(run_mix_credo_json "${mix_root}" "${mix_rel_path}")
      credo_converted=$(echo "${credo_output}" | jaq '[.explanations[]? | {
        line: (.line_no // 1),
        column: (.column // 1),
        code: (.check // "Credo"),
        message: .message,
        linter: "credo"
      }]' 2>/dev/null) || credo_converted="[]"
      if [[ -n "${credo_converted}" ]] && [[ "${credo_converted}" != "[]" ]]; then
        _merged=$(echo "${collected_violations}" "${credo_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Phoenix: Sobelow security scanner (session-scoped, runs once per session)
    sobelow_enabled=$(get_elixir_config "sobelow" "true")
    if [[ "${sobelow_enabled}" != "false" ]] && command -v mix >/dev/null 2>&1 \
      && [[ -n "${mix_root}" ]] && mix_task_available "${mix_root}" "sobelow"; then
      sobelow_session="/tmp/.sobelow_session_${SESSION_PID}"
      echo "${file_path}" >>"${sobelow_session}" 2>/dev/null || true
      sobelow_file_count=$(wc -l <"${sobelow_session}" 2>/dev/null | tr -d ' ') || sobelow_file_count="0"
      # Run sobelow on first Elixir file edit per session (project-level scanner)
      if [[ "${sobelow_file_count}" -le 1 ]]; then
        sobelow_output=$(run_sobelow_json "${mix_root}")
        if [[ -n "${sobelow_output}" ]]; then
          sobelow_converted=$(echo "${sobelow_output}" | jaq '[.findings[]? | {
            line: (.line // 1),
            column: 1,
            code: ("SOBELOW_" + (.type // "unknown")),
            message: (.message // .description // "Security finding"),
            linter: "sobelow"
          }]' 2>/dev/null) || sobelow_converted="[]"
          if [[ -n "${sobelow_converted}" ]] && [[ "${sobelow_converted}" != "[]" ]]; then
            _merged=$(echo "${collected_violations}" "${sobelow_converted}" \
              | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
            [[ -n "${_merged}" ]] && collected_violations="${_merged}"
            has_issues=true
          fi
        fi
      fi
    fi

    # Phoenix: mix compile warnings (opt-in)
    compile_warnings_enabled=$(get_elixir_config "mix_compile_warnings" "false")
    if [[ "${compile_warnings_enabled}" == "true" ]] && is_elixir_source_file "${file_path}" \
      && command -v mix >/dev/null 2>&1 && [[ -n "${mix_root}" ]]; then
      compile_output=$(run_mix_compile_warnings "${mix_root}" "${mix_rel_path}")
      if [[ -n "${compile_output}" ]]; then
        compile_violations=$(echo "${compile_output}" | while IFS= read -r line; do
          w_line=""
          w_msg=""
          w_line=$(echo "${line}" | grep -oE ':[0-9]+:' | head -1 | tr -d ':') || w_line="1"
          w_msg="${line#*:[0-9]*: }"
          [[ -z "${w_line}" ]] && w_line="1"
          # shellcheck disable=SC2016
          jaq -n --arg l "${w_line}" --arg m "${w_msg}" \
            '{line:($l|tonumber),column:1,code:"MIX_COMPILE",message:$m,linter:"mix compile"}'
        done | jaq -s '.' 2>/dev/null) || compile_violations="[]"
        if [[ -n "${compile_violations}" ]] && [[ "${compile_violations}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${compile_violations}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
          has_issues=true
        fi
      fi
    fi

    # Phoenix: LiveView anti-pattern detection (advisory)
    if is_elixir_source_file "${file_path}"; then
      lv_violations=$(detect_liveview_antipatterns "${file_path}")
      if [[ -n "${lv_violations}" ]] && [[ "${lv_violations}" != "[]" ]]; then
        _merged=$(echo "${collected_violations}" "${lv_violations}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Phoenix: mix deps.audit (session-scoped, runs once per session)
    deps_audit_enabled=$(get_elixir_config "deps_audit" "true")
    if [[ "${deps_audit_enabled}" != "false" ]] && command -v mix >/dev/null 2>&1 \
      && [[ -n "${mix_root}" ]]; then
      deps_audit_session="/tmp/.deps_audit_session_${SESSION_PID}"
      if [[ ! -f "${deps_audit_session}" ]]; then
        touch "${deps_audit_session}" 2>/dev/null || true
        audit_output=$(run_deps_audit "${mix_root}")
        if [[ -n "${audit_output}" ]] && echo "${audit_output}" | grep -qiE "vulnerab|advisory|warning"; then
          # shellcheck disable=SC2016
          audit_violation=$(jaq -n --arg m "${audit_output}" \
            '[{line:1,column:1,code:"DEPS_AUDIT",message:$m,linter:"mix deps.audit"}]') || audit_violation="[]"
          _merged=$(echo "${collected_violations}" "${audit_violation}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
          has_issues=true
        fi
      fi
    fi

    # Phoenix: mix xref warnings (session-scoped, runs once per session)
    xref_enabled=$(get_elixir_config "xref_warnings" "true")
    if [[ "${xref_enabled}" != "false" ]] && command -v mix >/dev/null 2>&1 \
      && [[ -n "${mix_root}" ]]; then
      xref_session="/tmp/.xref_session_${SESSION_PID}"
      if [[ ! -f "${xref_session}" ]]; then
        touch "${xref_session}" 2>/dev/null || true
        xref_output=$(run_xref_warnings "${mix_root}")
        if [[ -n "${xref_output}" ]]; then
          xref_violations
          # shellcheck disable=SC2016
          xref_violations=$(echo "${xref_output}" | while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            _x_file=$(echo "${line}" | cut -d: -f1 2>/dev/null) || _x_file=""
            x_line=$(echo "${line}" | grep -oE ':[0-9]+:' | head -1 | tr -d ':' 2>/dev/null) || x_line="1"
            [[ -z "${x_line}" ]] && x_line="1"
            x_msg="${line}"
            if echo "${line}" | grep -qi "unreachable"; then
              x_code="XREF_UNREACHABLE"
            elif echo "${line}" | grep -qi "deprecated"; then
              x_code="XREF_DEPRECATED"
            else
              x_code="XREF_WARNING"
            fi
            jaq -n --arg l "${x_line}" --arg m "${x_msg}" --arg c "${x_code}" \
              '{line:($l|tonumber),column:1,code:$c,message:$m,linter:"mix xref"}'
          done | jaq -s '.' 2>/dev/null) || xref_violations="[]"
          if [[ -n "${xref_violations}" ]] && [[ "${xref_violations}" != "[]" ]]; then
            _merged=$(echo "${collected_violations}" "${xref_violations}" \
              | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
            [[ -n "${_merged}" ]] && collected_violations="${_merged}"
            has_issues=true
          fi
        fi
      fi
    fi
    ;;

  *.sh | *.bash)
    is_language_enabled "shell" || exit_json

    # Shell: Phase 1 - Auto-format with shfmt
    if is_auto_format_enabled && command -v shfmt >/dev/null 2>&1; then
      # Format shell script (indentation, spacing)
      # Using -i 2 for 2-space indent, -ci for case indent, -bn for binary ops
      shfmt -w -i 2 -ci -bn "${file_path}" 2>/dev/null || true
    fi

    # Shell: Phase 2 - Collect semantic issues with ShellCheck
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck_output=$(shellcheck -f json "${file_path}" 2>/dev/null || true)
      if [[ -n "${shellcheck_output}" ]] && [[ "${shellcheck_output}" != "[]" ]]; then
        # Convert shellcheck JSON to standard format and merge
        sc_converted=$(echo "${shellcheck_output}" | jaq '[.[] | {
          line: .line,
          column: .column,
          code: ("SC" + (.code | tostring)),
          message: .message,
          linter: "shellcheck"
        }]' 2>/dev/null) || sc_converted="[]"
        _merged=$(echo "${collected_violations}" "${sc_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.yml | *.yaml)
    is_language_enabled "yaml" || exit_json

    # YAML: yamllint - collect all issues
    if command -v yamllint >/dev/null 2>&1; then
      yamllint_output=$(yamllint -f parsable "${file_path}" 2>/dev/null || true)
      if [[ -n "${yamllint_output}" ]]; then
        # Convert yamllint parsable format to JSON (file:line:col: [level] message (code))
        # shellcheck disable=SC2016
        yaml_json=$(echo "${yamllint_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          msg=$(echo "${line}" | sed -E 's/.*\[[a-z]+\] ([^(]+).*/\1/' | sed 's/ *$//')
          code=$(echo "${line}" | sed -E 's/.*\(([^)]+)\).*/\1/' || echo "unknown")
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"yamllint"}'
        done | jaq -s '.') || yaml_json="[]"
        if [[ -n "${yaml_json}" ]]; then
          _merged=$(echo "${collected_violations}" "${yaml_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;

  *.json)
    is_language_enabled "json" || exit_json

    # JSON: Phase 1 - Validate syntax first
    json_error=$(jaq empty "${file_path}" 2>&1) || true
    if [[ -n "${json_error}" ]]; then
      # Collect JSON syntax error
      # shellcheck disable=SC2016 # $m is a jaq variable, not shell
      json_violation=$(jaq -n --arg m "${json_error}" \
        '[{line:1,column:1,code:"JSON_SYNTAX",message:$m,linter:"jaq"}]') || json_violation="[]"
      _merged=$(echo "${collected_violations}" "${json_violation}" \
        | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
      [[ -n "${_merged}" ]] && collected_violations="${_merged}"
      has_issues=true
    else
      # JSON: Phase 2 - Auto-format valid JSON
      # Use Biome if TS enabled and available (D6), fallback to jaq pretty-print
      if is_auto_format_enabled; then
        json_formatted=false
        if is_typescript_enabled; then
          _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
          if [[ -n "${_biome_cmd}" ]]; then
            ${_biome_cmd} format --write "${file_path}" >/dev/null 2>&1 && json_formatted=true
          fi
        fi
        if [[ "${json_formatted}" == "false" ]]; then
          tmp_file=$(mktemp) || true
          if [[ -n "${tmp_file}" ]] && jaq '.' "${file_path}" >"${tmp_file}" 2>/dev/null; then
            if ! cmp -s "${file_path}" "${tmp_file}"; then
              mv "${tmp_file}" "${file_path}"
            else
              rm -f "${tmp_file}"
            fi
          else
            rm -f "${tmp_file}" 2>/dev/null || true
          fi
        fi
      fi
    fi
    ;;

  Dockerfile | Dockerfile.* | */Dockerfile | */Dockerfile.* | *.dockerfile | *.Dockerfile)
    is_language_enabled "dockerfile" || exit_json

    # Dockerfile: hadolint - collect all issues
    # Requires hadolint >= 2.12.0 for disable-ignore-pragma support
    if command -v hadolint >/dev/null 2>&1; then
      # Version check (warn if too old, don't block)
      hadolint_version=$(hadolint --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) || hadolint_version=""
      if [[ -n "${hadolint_version}" ]]; then
        major="${hadolint_version%%.*}"
        minor="${hadolint_version#*.}"
        if [[ "${major}" -lt 2 ]] || { [[ "${major}" -eq 2 ]] && [[ "${minor}" -lt 12 ]]; }; then
          echo "[hook:warning] hadolint ${hadolint_version} < 2.12.0 (some features may not work)" >&2
        fi
      fi
      hadolint_output=$(hadolint --no-color -f json "${file_path}" 2>/dev/null || true)
      if [[ -n "${hadolint_output}" ]] && [[ "${hadolint_output}" != "[]" ]]; then
        # Convert hadolint JSON to standard format and merge
        hl_converted=$(echo "${hadolint_output}" | jaq '[.[] | {
          line: .line,
          column: .column,
          code: .code,
          message: .message,
          linter: "hadolint"
        }]' 2>/dev/null) || hl_converted="[]"
        _merged=$(echo "${collected_violations}" "${hl_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.toml)
    is_language_enabled "toml" || exit_json

    # NOTE: taplo.toml include pattern limits validation to project files.
    # Files outside project directory are silently excluded (known design).
    # TOML: Phase 1 - Auto-format
    if is_auto_format_enabled && command -v taplo >/dev/null 2>&1; then
      # Format TOML in-place (fixes spacing, alignment)
      RUST_LOG=error taplo fmt "${file_path}" 2>/dev/null || true
    fi

    if command -v taplo >/dev/null 2>&1; then
      # TOML: Phase 2 - Check for syntax errors (can't be auto-fixed)
      taplo_check=$(RUST_LOG=error taplo check "${file_path}" 2>&1) || true
      if [[ -n "${taplo_check}" ]]; then
        # Collect TOML syntax error
        # shellcheck disable=SC2016
        toml_violation=$(jaq -n --arg m "${taplo_check}" \
          '[{line:1,column:1,code:"TOML_SYNTAX",message:$m,linter:"taplo"}]') || toml_violation="[]"
        _merged=$(echo "${collected_violations}" "${toml_violation}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.css | *.vue | *.svelte | *.astro)
    is_typescript_enabled || exit_json
    handle_typescript "${file_path}"
    ;;

  *.md | *.mdx)
    is_language_enabled "markdown" || exit_json

    # Markdown: Phase 1 - Auto-fix what we can
    if command -v markdownlint-cli2 >/dev/null 2>&1; then
      # --no-globs: Disable config globs, lint only the specific file
      # Without this, markdownlint merges globs from .markdownlint-cli2.jsonc
      # noBanner+noProgress in .markdownlint-cli2.jsonc suppress verbose output
      # Phase 1: Auto-fix (silently fixes what it can, outputs only unfixable issues)
      if is_auto_format_enabled; then
        markdownlint-cli2 --no-globs --fix "${file_path}" >/dev/null 2>&1 || true
      fi

      # Phase 2: Collect remaining unfixable issues for delegation
      markdownlint_output=$(markdownlint-cli2 --no-globs "${file_path}" 2>&1 || true)

      # Count remaining violations (lines matching file:line pattern)
      # grep -c exits 1 on no matches but still outputs 0, so use || true to ignore exit code
      violation_count=$(echo "${markdownlint_output}" | grep -cE "^[^:]+:[0-9]+" || true)
      [[ -z "${violation_count}" ]] && violation_count=0

      # Only collect if there are actual errors
      if [[ -n "${markdownlint_output}" ]] && ! echo "${markdownlint_output}" | grep -q "Summary: 0 error"; then
        # Convert markdownlint output to JSON (file:line:col MD### message)
        # shellcheck disable=SC2016
        md_json=$(echo "${markdownlint_output}" | grep -E "^[^:]+:[0-9]+" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/[^:]+:([0-9]+).*/\1/')
          code=$(echo "${line}" | sed -E 's/.*[[:space:]](MD[0-9]+).*/\1/' || echo "MD000")
          msg=$(echo "${line}" | sed -E 's/.*MD[0-9]+[^[:alnum:]]*(.+)/\1/' | sed 's/^ *//')
          jaq -n --arg l "${line_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:1,code:$cd,message:$m,linter:"markdownlint"}'
        done | jaq -s '.') || md_json="[]"
        if [[ -n "${md_json}" ]] && [[ "${md_json}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${md_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;
  *)
    # Unsupported file type - no linting available
    ;;
esac

# ============================================================================
# DELEGATION AND EXIT LOGIC
# ============================================================================

# If no issues, exit clean
if [[ "${has_issues}" = false ]]; then
  exit_json
fi

# Calculate model selection for debugging/testing
# This runs before HOOK_SKIP_SUBPROCESS check so tests can verify model selection
if [[ "${HOOK_DEBUG_MODEL:-}" == "1" ]]; then
  # Align with real delegation: filter to D-only subset for Python docstring cases
  debug_violations_json="${collected_violations}"
  if [[ "${file_type}" == "python" ]] && echo "${collected_violations}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    debug_violations_json=$(echo "${collected_violations}" | jaq -c '[.[] | select(.code | test("^D[0-9]+$"))]' 2>/dev/null) || debug_violations_json="${collected_violations}"
  fi

  count=$(echo "${debug_violations_json}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")

  debug_has_opus_codes="false"
  # shellcheck disable=SC2016 # jaq uses $pattern, not shell
  if echo "${debug_violations_json}" | jaq -e --arg pattern "${OPUS_CODE_PATTERN}" '[.[] | select(.code | test($pattern))] | length > 0' >/dev/null 2>&1; then
    debug_has_opus_codes="true"
  fi

  debug_has_sonnet_codes="false"
  # shellcheck disable=SC2016 # jaq uses $pattern, not shell
  if echo "${debug_violations_json}" | jaq -e --arg pattern "${SONNET_CODE_PATTERN}" '[.[] | select(.code | test($pattern))] | length > 0' >/dev/null 2>&1; then
    debug_has_sonnet_codes="true"
  fi

  debug_model="haiku"
  if [[ "${debug_has_sonnet_codes}" == "true" ]]; then
    debug_model="sonnet"
  fi
  if [[ "${debug_has_opus_codes}" == "true" ]] || [[ "${count}" -gt "${VOLUME_THRESHOLD}" ]]; then
    debug_model="opus"
  fi

  echo "[hook:model] ${debug_model}" >&2
fi

# Testing mode: skip subprocess and report violations directly
# Usage: HOOK_SKIP_SUBPROCESS=1 ./multi_linter.sh
if [[ "${HOOK_SKIP_SUBPROCESS:-}" == "1" ]]; then
  skip_count=$(echo "${collected_violations}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
  if [[ "${skip_count}" -eq 0 ]]; then
    exit_json
  fi
  echo "[hook] ${collected_violations}" >&2
  exit 2
fi

# Delegate to subprocess to fix violations
if is_subprocess_enabled && [[ -z "${HOOK_SKIP_SUBPROCESS:-}" ]]; then
  spawn_fix_subprocess "${file_path}" "${collected_violations}" "${file_type}"
fi

# Verify: re-run Phase 1 + Phase 2
_verify_started=${SECONDS}
hook_diag "phase=verify_start tool=${tool_name} file=${file_path} ftype=${file_type}"

_p1_started=${SECONDS}
hook_diag "phase=rerun_phase1_start tool=${tool_name} file=${file_path} ftype=${file_type}"
rerun_phase1 "${file_path}" "${file_type}"
hook_diag "phase=rerun_phase1_end tool=${tool_name} file=${file_path} ftype=${file_type} duration_s=$((SECONDS - _p1_started))"

_p2_started=${SECONDS}
hook_diag "phase=rerun_phase2_start tool=${tool_name} file=${file_path} ftype=${file_type}"
rerun_phase2 "${file_path}" "${file_type}"
_remaining_codes=$(echo "${RERUN_PHASE2_RAW:-[]}" | jaq -r '[.[].code] | sort | unique | join(",")' 2>/dev/null || echo "")
[[ -z "${_remaining_codes}" && -n "${RERUN_PHASE2_CODES:-}" ]] && _remaining_codes="${RERUN_PHASE2_CODES}"
hook_diag "phase=rerun_phase2_end tool=${tool_name} file=${file_path} ftype=${file_type} duration_s=$((SECONDS - _p2_started)) remaining_count=${RERUN_PHASE2_COUNT} remaining_codes=${_remaining_codes}"

remaining="${RERUN_PHASE2_COUNT}"
hook_diag "phase=verify_end tool=${tool_name} file=${file_path} ftype=${file_type} remaining_count=${remaining} remaining_codes=${_remaining_codes} duration_s=$((SECONDS - _verify_started))"

if [[ "${remaining}" -eq 0 ]]; then
  hook_diag "phase=resolved tool=${tool_name} file=${file_path} ftype=${file_type} remaining=0"
  exit_json "Phase 3 resolved all violations."
else
  extract_violation_codes "${file_type}"
  _base_name=$(basename "${file_path}")
  if [[ -n "${VIOLATION_CODES}" ]]; then
    hook_json "${remaining} violation(s) in ${_base_name}: ${VIOLATION_CODES}. Fix them."
  else
    hook_json "${remaining} violation(s) in ${_base_name}. Fix them."
  fi
  hook_diag "phase=feedback_loop tool=${tool_name} file=${file_path} ftype=${file_type} remaining_count=${remaining} remaining_codes=${VIOLATION_CODES:-}"
  echo "[hook:feedback-loop] delivered ${remaining} for ${file_path}" >&2
  exit 2
fi
