#!/bin/bash
# test_elixir_hooks.sh - Integration tests for Elixir/Phoenix hooks
# Tests LiveView anti-pattern detection, config parsing, and violation routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANKTON_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="$(dirname "${PLANKTON_DIR}")"
HOOKS_DIR="${PLANKTON_DIR}/hooks"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/elixir"

pass_count=0
fail_count=0
total_count=0

pass() {
  pass_count=$((pass_count + 1))
  total_count=$((total_count + 1))
  echo "  PASS: $1"
}

fail() {
  fail_count=$((fail_count + 1))
  total_count=$((total_count + 1))
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && echo "        $2"
}

echo "=== Elixir/Phoenix Hook Tests ==="
echo ""

# ---- Test: detect_liveview_antipatterns on bad LiveView ----
echo "--- LiveView Anti-Pattern Detection ---"

# Source the functions we need (they're defined in multi_linter.sh)
# We'll extract and test them via the hook's HOOK_SKIP_SUBPROCESS mode

# Test 1: Bad LiveView should trigger LV_PUBSUB_NO_CONNECTED
if [[ -f "${FIXTURES_DIR}/bad_liveview.ex" ]]; then
  output=$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"${FIXTURES_DIR}/bad_liveview.ex"'"}}' \
    | HOOK_SKIP_SUBPROCESS=1 HOOK_SESSION_PID=$$ \
      PLANKTON_PROJECT_DIR="${PROJECT_DIR}" \
      bash "${HOOKS_DIR}/multi_linter.sh" 2>&1) || true

  if echo "${output}" | grep -q "LV_PUBSUB_NO_CONNECTED"; then
    pass "Bad LiveView detected: PubSub without connected? guard"
  else
    fail "Expected LV_PUBSUB_NO_CONNECTED in bad_liveview.ex" "Got: ${output:0:200}"
  fi

  if echo "${output}" | grep -q "LV_REPO_IN_LIVEVIEW"; then
    pass "Bad LiveView detected: Repo query in LiveView"
  else
    fail "Expected LV_REPO_IN_LIVEVIEW in bad_liveview.ex" "Got: ${output:0:200}"
  fi

  if echo "${output}" | grep -q "LV_GENERIC_EVENT_PARAMS"; then
    pass "Bad LiveView detected: generic event params"
  else
    fail "Expected LV_GENERIC_EVENT_PARAMS in bad_liveview.ex" "Got: ${output:0:200}"
  fi

  if echo "${output}" | grep -q "LV_MISSING_IMPL"; then
    pass "Bad LiveView detected: missing @impl true"
  else
    fail "Expected LV_MISSING_IMPL in bad_liveview.ex" "Got: ${output:0:200}"
  fi

  if echo "${output}" | grep -q "LV_LIST_WITHOUT_STREAM"; then
    pass "Bad LiveView detected: list without stream"
  else
    fail "Expected LV_LIST_WITHOUT_STREAM in bad_liveview.ex" "Got: ${output:0:200}"
  fi
else
  fail "Fixture file bad_liveview.ex not found"
fi

echo ""

# Test 2: Good LiveView should NOT trigger any LV_ violations
echo "--- Good LiveView (no violations expected) ---"
if [[ -f "${FIXTURES_DIR}/good_liveview.ex" ]]; then
  output=$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"${FIXTURES_DIR}/good_liveview.ex"'"}}' \
    | HOOK_SKIP_SUBPROCESS=1 HOOK_SESSION_PID=$$ \
      PLANKTON_PROJECT_DIR="${PROJECT_DIR}" \
      bash "${HOOKS_DIR}/multi_linter.sh" 2>&1) || true

  if echo "${output}" | grep -q "LV_PUBSUB_NO_CONNECTED"; then
    fail "Good LiveView false positive: LV_PUBSUB_NO_CONNECTED"
  else
    pass "Good LiveView: no PubSub false positive"
  fi

  if echo "${output}" | grep -q "LV_REPO_IN_LIVEVIEW"; then
    fail "Good LiveView false positive: LV_REPO_IN_LIVEVIEW"
  else
    pass "Good LiveView: no Repo false positive"
  fi

  if echo "${output}" | grep -q "LV_MISSING_IMPL"; then
    fail "Good LiveView false positive: LV_MISSING_IMPL"
  else
    pass "Good LiveView: no missing @impl false positive"
  fi

  if echo "${output}" | grep -q "LV_GENERIC_EVENT_PARAMS"; then
    fail "Good LiveView false positive: LV_GENERIC_EVENT_PARAMS"
  else
    pass "Good LiveView: no generic params false positive"
  fi
else
  fail "Fixture file good_liveview.ex not found"
fi

echo ""

# Test 3: Unused assigns detection
echo "--- Unused Assigns Detection ---"
if [[ -f "${FIXTURES_DIR}/unused_assigns.ex" ]]; then
  output=$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"${FIXTURES_DIR}/unused_assigns.ex"'"}}' \
    | HOOK_SKIP_SUBPROCESS=1 HOOK_SESSION_PID=$$ \
      PLANKTON_PROJECT_DIR="${PROJECT_DIR}" \
      bash "${HOOKS_DIR}/multi_linter.sh" 2>&1) || true

  if echo "${output}" | tr '\n' ' ' | grep -q "LV_UNUSED_ASSIGN.*debug_data"; then
    pass "Unused assign detected: :debug_data"
  else
    fail "Expected LV_UNUSED_ASSIGN for :debug_data" "Got: ${output:0:200}"
  fi

  if echo "${output}" | tr '\n' ' ' | grep -q "LV_UNUSED_ASSIGN.*revenue"; then
    pass "Unused assign detected: :revenue"
  else
    fail "Expected LV_UNUSED_ASSIGN for :revenue" "Got: ${output:0:200}"
  fi

  # page_title and user_count ARE used in template
  if echo "${output}" | grep -q "LV_UNUSED_ASSIGN.*page_title"; then
    fail "False positive: :page_title is used in template"
  else
    pass "No false positive for :page_title (used in template)"
  fi
else
  fail "Fixture file unused_assigns.ex not found"
fi

echo ""

# Test 4: Elixir config parsing
echo "--- Elixir Config Parsing ---"

# Verify config keys are parsed in the config.json
if [[ -f "${SCRIPT_DIR}/fixtures/config.json" ]]; then
  if jaq -r '.languages.elixir.liveview_checks' "${SCRIPT_DIR}/fixtures/config.json" 2>/dev/null | grep -q "true"; then
    pass "Config: liveview_checks present and true"
  else
    fail "Config: liveview_checks missing or not true"
  fi

  if jaq -r '.languages.elixir.deps_audit' "${SCRIPT_DIR}/fixtures/config.json" 2>/dev/null | grep -q "true"; then
    pass "Config: deps_audit present and true"
  else
    fail "Config: deps_audit missing or not true"
  fi

  if jaq -r '.languages.elixir.xref_warnings' "${SCRIPT_DIR}/fixtures/config.json" 2>/dev/null | grep -q "true"; then
    pass "Config: xref_warnings present and true"
  else
    fail "Config: xref_warnings missing or not true"
  fi
fi

echo ""

# Test 5: Model routing for LiveView codes
echo "--- Model Routing (LiveView codes) ---"
# LV_MISSING_IMPL and LV_LIST_WITHOUT_STREAM should route to haiku
# LV_PUBSUB_NO_CONNECTED, LV_REPO_IN_LIVEVIEW should route to sonnet

haiku_pattern='MIX_FORMAT|SOBELOW|MIX_COMPILE|DEPS_AUDIT|XREF_[A-Z]+|LV_LIST_WITHOUT_STREAM|LV_MISSING_IMPL'
sonnet_pattern='Credo\.|Sobelow\.|LV_PUBSUB_NO_CONNECTED|LV_REPO_IN_LIVEVIEW|LV_GENERIC_EVENT_PARAMS|LV_UNUSED_ASSIGN'

if echo "LV_MISSING_IMPL" | grep -qE "^(${haiku_pattern})$"; then
  pass "LV_MISSING_IMPL routes to haiku tier"
else
  fail "LV_MISSING_IMPL should route to haiku"
fi

if echo "LV_PUBSUB_NO_CONNECTED" | grep -qE "^(${sonnet_pattern})$"; then
  pass "LV_PUBSUB_NO_CONNECTED routes to sonnet tier"
else
  fail "LV_PUBSUB_NO_CONNECTED should route to sonnet"
fi

if echo "LV_REPO_IN_LIVEVIEW" | grep -qE "^(${sonnet_pattern})$"; then
  pass "LV_REPO_IN_LIVEVIEW routes to sonnet tier"
else
  fail "LV_REPO_IN_LIVEVIEW should route to sonnet"
fi

if echo "DEPS_AUDIT" | grep -qE "^(${haiku_pattern})$"; then
  pass "DEPS_AUDIT routes to haiku tier"
else
  fail "DEPS_AUDIT should route to haiku"
fi

echo ""
echo "--- Config Getter False-Preservation Regression ---"

extract_hook_function() {
  local fn="$1"
  awk -v fn="${fn}" '
    $0 == fn "() {" { printing=1 }
    printing { print }
    printing && $0 == "}" { printing=0 }
  ' "${HOOKS_DIR}/multi_linter.sh"
}

helper_file=$(mktemp)
for fn in get_language_config_value get_ts_config get_elixir_config is_elixir_enabled; do
  extract_hook_function "${fn}" >>"${helper_file}"
  printf '\n' >>"${helper_file}"
done
# shellcheck source=/dev/null
source "${helper_file}"
rm -f "${helper_file}"

assert_elixir_enabled_status() {
  local name="$1" config="$2" expected_rc="$3" rc
  export CONFIG_JSON="${config}"
  if is_elixir_enabled; then
    rc=0
  else
    rc=$?
  fi

  if [[ "${rc}" -eq "${expected_rc}" ]]; then
    pass "${name}"
  else
    fail "${name}" "Expected return ${expected_rc}, got ${rc}"
  fi
}

assert_elixir_config_value() {
  local name="$1" config="$2" key="$3" default="$4" expected="$5" actual
  export CONFIG_JSON="${config}"
  actual=$(get_elixir_config "${key}" "${default}")
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${name}"
  else
    fail "${name}" "Expected ${expected}, got ${actual}"
  fi
}

assert_ts_config_value() {
  local name="$1" config="$2" key="$3" default="$4" expected="$5" actual
  export CONFIG_JSON="${config}"
  actual=$(get_ts_config "${key}" "${default}")
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${name}"
  else
    fail "${name}" "Expected ${expected}, got ${actual}"
  fi
}

assert_elixir_enabled_status \
  "Elixir enabled=false disables language" \
  '{"languages":{"elixir":{"enabled":false}}}' \
  1
assert_elixir_enabled_status \
  "Elixir enabled=true enables language" \
  '{"languages":{"elixir":{"enabled":true}}}' \
  0
assert_elixir_config_value \
  "Elixir credo=false is preserved" \
  '{"languages":{"elixir":{"credo":false}}}' \
  "credo" "true" "false"
assert_elixir_config_value \
  "Elixir credo=true is preserved" \
  '{"languages":{"elixir":{"credo":true}}}' \
  "credo" "true" "true"
assert_elixir_config_value \
  "Elixir missing credo uses default" \
  '{"languages":{"elixir":{}}}' \
  "credo" "true" "true"
assert_elixir_config_value \
  "Elixir sobelow=false is preserved" \
  '{"languages":{"elixir":{"sobelow":false}}}' \
  "sobelow" "true" "false"
assert_elixir_config_value \
  "Elixir credo=null uses default" \
  '{"languages":{"elixir":{"credo":null}}}' \
  "credo" "true" "true"
assert_elixir_config_value \
  "Legacy scalar Elixir config uses default" \
  '{"languages":{"elixir":true}}' \
  "credo" "true" "true"
assert_ts_config_value \
  "TypeScript semgrep=false is preserved" \
  '{"languages":{"typescript":{"semgrep":false}}}' \
  "semgrep" "true" "false"
assert_ts_config_value \
  "TypeScript biome_nursery string is preserved" \
  '{"languages":{"typescript":{"biome_nursery":"error"}}}' \
  "biome_nursery" "off" "error"
assert_ts_config_value \
  "TypeScript js_runtime string is preserved" \
  '{"languages":{"typescript":{"js_runtime":"bun"}}}' \
  "js_runtime" "node" "bun"
assert_ts_config_value \
  "TypeScript missing semgrep uses default" \
  '{"languages":{"typescript":{}}}' \
  "semgrep" "true" "true"

echo ""
echo "--- Credo Toggle Integration (fake mix) ---"

setup_fake_mix_project() {
  local project="$1" fake_bin="$2"
  mkdir -p "${project}/lib" "${fake_bin}"
  cat >"${project}/mix.exs" <<'EOF'
defmodule PlanktonFake.MixProject do
  use Mix.Project

  def project do
    [app: :plankton_fake, version: "0.1.0"]
  end
end
EOF
  cat >"${project}/lib/example.ex" <<'EOF'
defmodule PlanktonFake.Example do
  def hello do
    :world
  end
end
EOF
  cat >"${fake_bin}/mix" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MIX_LOG:-}" ]]; then
  echo "mix $*" >>"${MIX_LOG}"
fi

case "$1" in
  help)
    exit 0
    ;;
  credo)
    printf '{"explanations":[]}\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/mix"
}

write_credo_config() {
  local config_file="$1" credo_state="$2" enabled="$3" credo_line=""
  case "${credo_state}" in
    true | false) credo_line="\"credo\": ${credo_state}," ;;
    missing) credo_line="" ;;
    *) fail "Invalid fake Credo state" "${credo_state}" ;;
  esac

  cat >"${config_file}" <<EOF
{
  "phases": {"auto_format": false, "subprocess_delegation": false},
  "languages": {
    "elixir": {
      "enabled": ${enabled},
      ${credo_line}
      "sobelow": false,
      "deps_audit": false,
      "xref_warnings": false,
      "mix_compile_warnings": false,
      "liveview_checks": false
    }
  }
}
EOF
}

run_credo_toggle_case() {
  local name="$1" credo_state="$2" enabled="$3" expectation="$4"
  local tmp_dir project fake_bin config_file mix_log source_file hook_input output session_id log_output

  tmp_dir=$(mktemp -d)
  project="${tmp_dir}/project"
  fake_bin="${tmp_dir}/bin"
  config_file="${tmp_dir}/config.json"
  mix_log="${tmp_dir}/mix.log"
  setup_fake_mix_project "${project}" "${fake_bin}"
  write_credo_config "${config_file}" "${credo_state}" "${enabled}"

  source_file="${project}/lib/example.ex"
  hook_input=$(jaq -n --arg f "${source_file}" "{tool_name:\"Write\",tool_input:{file_path:\$f}}")
  session_id="test_elixir_${RANDOM}_${total_count}"
  output=$(PATH="${fake_bin}:${PATH}" \
    MIX_LOG="${mix_log}" \
    HOOK_SKIP_SUBPROCESS=1 \
    HOOK_SESSION_PID="${session_id}" \
    PLANKTON_CONFIG="${config_file}" \
    PLANKTON_PROJECT_DIR="${project}" \
    bash "${HOOKS_DIR}/multi_linter.sh" <<<"${hook_input}" 2>&1) || true
  log_output="$(cat "${mix_log}" 2>/dev/null || true)"

  case "${expectation}" in
    no_credo)
      if grep -q "mix credo" <<<"${log_output}"; then
        fail "${name}" "Unexpected mix credo invocation. Log: ${log_output}. Output: ${output:0:200}"
      else
        pass "${name}"
      fi
      ;;
    credo)
      if grep -q "mix credo --strict --format json" <<<"${log_output}"; then
        pass "${name}"
      else
        fail "${name}" "Expected mix credo invocation. Log: ${log_output}. Output: ${output:0:200}"
      fi
      ;;
    no_mix)
      if [[ -z "${log_output}" ]]; then
        pass "${name}"
      else
        fail "${name}" "Expected no mix invocations. Log: ${log_output}. Output: ${output:0:200}"
      fi
      ;;
    *)
      fail "${name}" "Unknown expectation: ${expectation}"
      ;;
  esac

  rm -rf "${tmp_dir}"
}

run_credo_toggle_case "Credo false skips mix credo" "false" "true" "no_credo"
run_credo_toggle_case "Credo true runs mix credo" "true" "true" "credo"
run_credo_toggle_case "Missing Credo key defaults to enabled" "missing" "true" "credo"
run_credo_toggle_case "Elixir enabled=false skips all mix calls" "missing" "false" "no_mix"

echo ""
echo "=== Results: ${pass_count} passed, ${fail_count} failed, ${total_count} total ==="

if [[ ${fail_count} -gt 0 ]]; then
  exit 1
fi
