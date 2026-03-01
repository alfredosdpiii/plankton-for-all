#!/bin/bash
# enforce_package_managers.sh - Claude Code PreToolUse hook (Bash matcher)
# Blocks legacy package managers and suggests project-preferred alternatives.
#   python:     pip/pip3/python -m pip/python -m venv/poetry/pipenv  → uv
#   javascript: npm/npx/yarn/pnpm                                    → bun
#
# Output: JSON per PreToolUse spec (always exit 0)
#   {"decision": "approve"}
#   {"decision": "block", "reason": "[hook:block] <tool> is not allowed. Use: <replacement>"}

set -euo pipefail

# Session-level bypass (HOOK_SKIP_PM=1 claude ...)
if [[ "${HOOK_SKIP_PM:-0}" == "1" ]]; then
  echo '{"decision": "approve"}'; exit 0
fi

input=$(cat)

# Extract command string; fail-open if jaq missing or input malformed
cmd=$(jaq -r '.tool_input?.command? // empty' <<<"${input}" 2>/dev/null) || {
  echo '{"decision": "approve"}'; exit 0
}
[[ -z "${cmd}" ]] && { echo '{"decision": "approve"}'; exit 0; }

# Strip heredoc content from cmd to avoid false positives.
# Heredoc bodies contain data (not commands) — PM enforcement
# should not match tool names found only inside heredoc text.
if [[ "${cmd}" == *'<<'* ]]; then
  cmd=$(printf '%s\n' "${cmd}" | awk '
    BEGIN { skip = 0 }
    skip {
      t = $0; gsub(/^[[:space:]]+/, "", t)
      if (t == delim) { skip = 0 }
      next
    }
    /<</ {
      s = $0; sub(/.*<<-?[[:space:]]*/, "", s)
      sub(/^["\047]/, "", s); sub(/["\047].*/, "", s)
      sub(/[[:space:]].*/, "", s)
      if (s != "") {
        delim = s; skip = 1
        sub(/[[:space:]]*<<.*/, "", $0)
        if ($0 != "") print
        next
      }
    }
    { print }
  ')
fi


config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"

# get_pm_enforcement(lang) — reads .package_managers.<lang> from config
# Returns "uv", "uv:warn", "bun", "bun:warn", or "false"
get_pm_enforcement() {
  local lang="$1"
  jaq -r ".package_managers.${lang} // false" \
    "${config_file}" 2>/dev/null || echo "false"
}

# parse_pm_config(value) — splits value into mode+tool
# false     → "off"
# *:warn    → "warn:<tool>"
# *         → "block:<tool>"
parse_pm_config() {
  local value="$1"
  case "${value}" in
    false) echo "off" ;;
    *:warn) echo "warn:${value%:warn}" ;;
    *) echo "block:${value}" ;;
  esac
}

# is_allowed_subcommand(tool, subcmd) — checks allowlist in config
# Returns 0 if subcmd is in the allowed list, 1 otherwise
is_allowed_subcommand() {
  local tool="$1"
  local subcmd="$2"
  local allowed
  while IFS= read -r allowed; do
    [[ "${subcmd}" == "${allowed}" ]] && return 0
  done < <(jaq -r ".package_managers.allowed_subcommands.${tool} // [] | .[]" \
    "${config_file}" 2>/dev/null || true)
  return 1
}

# compute_replacement_message(tool, subcmd) — maps tool:subcmd to replacement
compute_replacement_message() {
  local tool="$1"
  local subcmd="${2:-}"

  case "${tool}:${subcmd}" in
    pip:install|pip3:install)
      if echo "${cmd}" | grep -qE '[[:space:]]-r([[:space:]]|[^[:space:]-])'; then
        local req_file
        req_file=$(echo "${cmd}" | sed -nE \
          's/.*[[:space:]]-r[[:space:]]*([^[:space:]-][^[:space:]]*).*/\1/p')
        echo "uv pip install -r ${req_file:-requirements.txt}"
      elif echo "${cmd}" | grep -qE ' -e '; then
        echo "uv pip install -e ."
      else
        local pkgs
        pkgs=$(echo "${cmd}" | sed -nE 's/.*pip3?[[:space:]]+install[[:space:]]+([^-].*)/\1/p' | \
          sed 's/[[:space:]]*$//')
        if [[ -n "${pkgs}" ]]; then
          echo "uv add ${pkgs}"
        else
          echo "uv add <packages>"
        fi
      fi
      ;;
    pip:uninstall|pip3:uninstall)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*pip3?[[:space:]]+uninstall[[:space:]]+([^-].*)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv remove ${pkgs}"
      else
        echo "uv remove <packages>"
      fi
      ;;
    pip:freeze|pip3:freeze) echo "uv pip freeze" ;;
    pip:list|pip3:list)     echo "uv pip list" ;;
    pip:*|pip3:*)           echo "uv <equivalent>" ;;
    "python -m pip":*)      echo "uv add <packages>" ;;
    "python -m venv":*)
      local venv_dir
      venv_dir=$(echo "${cmd}" | sed -nE 's/.*python3?[[:space:]]+-m[[:space:]]+venv[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${venv_dir}" ]]; then
        echo "uv venv ${venv_dir}"
      else
        echo "uv venv"
      fi
      ;;
    poetry:add)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*poetry[[:space:]]+add[[:space:]]+(.+)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv add ${pkgs}"
      else
        echo "uv add <packages>"
      fi
      ;;
    poetry:install)   echo "uv sync" ;;
    poetry:run)
      local run_cmd
      run_cmd=$(echo "${cmd}" | sed -nE 's/.*poetry[[:space:]]+run[[:space:]]+(.+)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${run_cmd}" ]]; then
        echo "uv run ${run_cmd}"
      else
        echo "uv run <cmd>"
      fi
      ;;
    poetry:lock)      echo "uv lock" ;;
    poetry:*)         echo "uv <equivalent>" ;;
    pipenv:install)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*pipenv[[:space:]]+install[[:space:]]+([^-].*)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv add ${pkgs}"
      else
        echo "uv sync"
      fi
      ;;
    pipenv:run)
      local run_cmd
      run_cmd=$(echo "${cmd}" | sed -nE 's/.*pipenv[[:space:]]+run[[:space:]]+(.+)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${run_cmd}" ]]; then
        echo "uv run ${run_cmd}"
      else
        echo "uv run <cmd>"
      fi
      ;;
    pipenv:*)         echo "uv <equivalent>" ;;
    npm:install|npm:i|npm:ci)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*npm[[:space:]]+(install|i|ci)[[:space:]]+([^-].*)/\2/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun install"
      fi
      ;;
    npm:run)
      local script
      script=$(echo "${cmd}" | sed -nE 's/.*npm[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    npm:test)         echo "bun test" ;;
    npm:start)        echo "bun run start" ;;
    npm:exec)         echo "bunx <pkg>" ;;
    npm:init)         echo "bun init" ;;
    npm:uninstall|npm:remove)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*npm[[:space:]]+(uninstall|remove)[[:space:]]+([^-].*)/\2/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    npm:*)            echo "bun <equivalent>" ;;
    npx:*)
      local pkg
      pkg=$(echo "${cmd}" | sed -E 's/.*npx[[:space:]]+//' | \
        tr ' ' '\n' | grep -v '^-' | head -1)
      if [[ -n "${pkg}" ]]; then
        echo "bunx ${pkg}"
      else
        echo "bunx <pkg>"
      fi
      ;;
    yarn:add)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*yarn[[:space:]]+add[[:space:]]+([^-].*)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun add <packages>"
      fi
      ;;
    yarn:install)     echo "bun install" ;;
    yarn:run)
      local script
      script=$(echo "${cmd}" | sed -nE 's/.*yarn[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    yarn:remove)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*yarn[[:space:]]+remove[[:space:]]+([^-].*)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    yarn:*)           echo "bun <equivalent>" ;;
    pnpm:add)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*pnpm[[:space:]]+add[[:space:]]+([^-].*)/\1/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun add <packages>"
      fi
      ;;
    pnpm:install)     echo "bun install" ;;
    pnpm:run)
      local script
      script=$(echo "${cmd}" | sed -nE 's/.*pnpm[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    pnpm:remove)
      local pkgs
      pkgs=$(echo "${cmd}" | sed -nE 's/.*pnpm[[:space:]]+(remove|uninstall)[[:space:]]+([^-].*)/\2/p' | \
        sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    pnpm:*)           echo "bun <equivalent>" ;;
    *)                echo "use the project-preferred tool" ;;
  esac
}

# check_replacement_tool(tool, install_hint) — warns once per session if tool missing
check_replacement_tool() {
  local tool="$1"
  local install_hint="$2"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    local marker="/tmp/.pm_warn_${tool}_${HOOK_GUARD_PID:-${PPID}}"
    if [[ ! -f "${marker}" ]]; then
      echo "[hook:warning] ${tool} not found — blocked but replacement unavailable. Install: ${install_hint}" >&2
      touch "${marker}" 2>/dev/null || true
    fi
  fi
}

# approve() — log if debug/log, output approve JSON, exit 0
approve() {
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='approve'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | approve | | | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi
  echo '{"decision": "approve"}'
  exit 0
}

# block(tool, subcmd) — compute replacement, output block JSON, exit 0
block() {
  local tool="$1"
  local subcmd="${2:-}"
  local replacement
  replacement=$(compute_replacement_message "${tool}" "${subcmd}")
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='block', tool='${tool}', subcmd='${subcmd}'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | block | ${tool} | ${subcmd} | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi
  echo "{\"decision\": \"block\", \"reason\": \"[hook:block] ${tool} is not allowed. Use: ${replacement}\"}"
  exit 0
}

# warn(tool, subcmd) — compute replacement, output approve JSON + advisory to stderr, exit 0
warn() {
  local tool="$1"
  local subcmd="${2:-}"
  local replacement
  replacement=$(compute_replacement_message "${tool}" "${subcmd}")
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='warn', tool='${tool}', subcmd='${subcmd}'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | warn | ${tool} | ${subcmd} | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi
  echo '{"decision": "approve"}'
  echo "[hook:advisory] ${tool} detected. Prefer: ${replacement}" >&2
  exit 0
}

# enforce(mode, tool, subcmd) — dispatches to warn or block based on mode
enforce() {
  local mode="$1"
  local tool="$2"
  local subcmd="${3:-}"
  if [[ "${mode}" == "warn" ]]; then
    warn "${tool}" "${subcmd}"
  else
    block "${tool}" "${subcmd}"
  fi
}

# ============================================================
# Python enforcement
# pip/python-m family: elif chain (uv pip passthrough + python -m pip download allowlist reuse)
# poetry/pipenv: independent blocks (catches "pip diag && poetry add" compounds)
# ============================================================

WB_START='(^|[^a-zA-Z0-9_])'
WB_END='([^a-zA-Z0-9_]|$)'

py_raw=$(get_pm_enforcement "python")
py_parsed=$(parse_pm_config "${py_raw}")
py_mode="${py_parsed%%:*}"   # off / warn / block

if [[ "${py_mode}" != "off" ]]; then

  # Elif chain: uv pip passthrough + pip/python-m family
  # (elif required: "uv pip" contains "pip"; python -m pip download allowlist reused via fallthrough)
  if   [[ "${cmd}" =~ ${WB_START}uv[[:space:]]+pip ]]; then
    approve   # uv pip passthrough — exits

  elif [[ "${cmd}" =~ ${WB_START}pip3?[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "pip" "${subcmd}"; then
      check_replacement_tool "uv" "brew install uv"
      enforce "${py_mode}" "pip" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}pip3?[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}pip3?${WB_END} ]]; then
    check_replacement_tool "uv" "brew install uv"
    enforce "${py_mode}" "pip"
  elif [[ "${cmd}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+pip${WB_END} ]]; then
    check_replacement_tool "uv" "brew install uv"
    enforce "${py_mode}" "python -m pip"
  elif [[ "${cmd}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+venv${WB_END} ]]; then
    check_replacement_tool "uv" "brew install uv"
    enforce "${py_mode}" "python -m venv"
  fi

  # Independent: poetry (now catches "pip --version && poetry add" compounds)
  if   [[ "${cmd}" =~ ${WB_START}poetry[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "poetry" "${subcmd}"; then
      check_replacement_tool "uv" "brew install uv"
      enforce "${py_mode}" "poetry" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}poetry[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}poetry${WB_END} ]]; then
    check_replacement_tool "uv" "brew install uv"
    enforce "${py_mode}" "poetry"
  fi

  # Independent: pipenv (now catches "pip --version && pipenv install" compounds)
  if   [[ "${cmd}" =~ ${WB_START}pipenv[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "pipenv" "${subcmd}"; then
      check_replacement_tool "uv" "brew install uv"
      enforce "${py_mode}" "pipenv" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}pipenv[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}pipenv${WB_END} ]]; then
    check_replacement_tool "uv" "brew install uv"
    enforce "${py_mode}" "pipenv"
  fi

fi

# ============================================================
# JavaScript enforcement (independent if blocks — required for compound cmd safety)
# ============================================================

js_raw=$(get_pm_enforcement "javascript")
js_parsed=$(parse_pm_config "${js_raw}")
js_mode="${js_parsed%%:*}"   # off / warn / block

if [[ "${js_mode}" != "off" ]]; then

  # npm (independent check — elif chain within this block)
  if   [[ "${cmd}" =~ ${WB_START}npm[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "npm" "${subcmd}"; then
      check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
      enforce "${js_mode}" "npm" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]*[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "npm" "${subcmd}"; then
      check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
      enforce "${js_mode}" "npm" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}npm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]* ]]; then
    check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
    enforce "${js_mode}" "npm"
  elif [[ "${cmd}" =~ ${WB_START}npm${WB_END} ]]; then
    check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
    enforce "${js_mode}" "npm"
  fi

  # npx (independent check)
  if   [[ "${cmd}" =~ ${WB_START}npx[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}npx${WB_END} ]]; then
    check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
    enforce "${js_mode}" "npx"
  fi

  # yarn (independent check — not elif from npm)
  if   [[ "${cmd}" =~ ${WB_START}yarn[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "yarn" "${subcmd}"; then
      check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
      enforce "${js_mode}" "yarn" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}yarn[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}yarn${WB_END} ]]; then
    check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
    enforce "${js_mode}" "yarn" "install"
  fi

  # pnpm (independent check — not elif from yarn)
  if   [[ "${cmd}" =~ ${WB_START}pnpm[[:space:]]+([a-zA-Z]+) ]]; then
    subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310  # is_allowed_subcommand is an intentional predicate
    if ! is_allowed_subcommand "pnpm" "${subcmd}"; then
      check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
      enforce "${js_mode}" "pnpm" "${subcmd}"
    fi
  elif [[ "${cmd}" =~ ${WB_START}pnpm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    :   # diagnostic no-op
  elif [[ "${cmd}" =~ ${WB_START}pnpm${WB_END} ]]; then
    check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
    enforce "${js_mode}" "pnpm" "install"
  fi

fi

echo '{"decision": "approve"}'
exit 0
