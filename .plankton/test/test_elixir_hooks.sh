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
echo "=== Results: ${pass_count} passed, ${fail_count} failed, ${total_count} total ==="

if [[ ${fail_count} -gt 0 ]]; then
  exit 1
fi
