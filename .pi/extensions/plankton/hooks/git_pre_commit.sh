#!/usr/bin/env bash
# Plankton-managed Git pre-commit hook runner.
# Runs deterministic Plankton file checks against staged files.

set -euo pipefail

if [[ "${PLANKTON_GIT_HOOKS:-1}" == "0" ]]; then
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
protect_hook="${repo_root}/.plankton/hooks/protect_linter_configs.sh"
lint_hook="${repo_root}/.plankton/hooks/multi_linter.sh"

if ! command -v jaq >/dev/null 2>&1; then
  echo "plankton: Git pre-commit hook requires 'jaq' in PATH" >&2
  echo "plankton: set PLANKTON_GIT_HOOKS=0 to bypass temporarily" >&2
  exit 1
fi

if [[ ! -f "${protect_hook}" ]] || [[ ! -f "${lint_hook}" ]]; then
  echo "plankton: expected hook scripts under .plankton/hooks/" >&2
  exit 1
fi

make_payload() {
  local abs_path="$1"
  # shellcheck disable=SC2016 # $tool_name/$file_path are jaq variables, not shell variables.
  jaq -cn --arg tool_name "Write" --arg file_path "${abs_path}" \
    '{tool_name: $tool_name, tool_input: {file_path: $file_path}}'
}

sha_file() {
  local target="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum "${target}" 2>/dev/null | awk '{print $1}'
  else
    cksum "${target}" 2>/dev/null | awk '{print $1 ":" $2}'
  fi
}

summarize_remaining() {
  local stderr_file="$1"
  local raw_json codes count
  raw_json=$(sed -n 's/^\[hook\] //p' "${stderr_file}" | tail -n1)
  [[ -z "${raw_json}" ]] && return 1

  count=$(printf '%s' "${raw_json}" | jaq 'length' 2>/dev/null | head -n1 || echo "")
  codes=$(printf '%s' "${raw_json}" | jaq -r '[.[].code] | sort | unique | join(",")' 2>/dev/null || echo "")

  if [[ -n "${count}" ]] && [[ -n "${codes}" ]]; then
    echo "${count} remaining violation(s): ${codes}"
  elif [[ -n "${count}" ]]; then
    echo "${count} remaining violation(s)"
  else
    echo "violations remain after deterministic checks"
  fi
}

had_failure=0
saw_file=0

while IFS= read -r -d '' rel_path; do
  [[ -z "${rel_path}" ]] && continue
  saw_file=1

  abs_path="${repo_root}/${rel_path}"
  [[ -f "${abs_path}" ]] || continue

  payload=$(make_payload "${abs_path}")

  if [[ "${PLANKTON_STRICT_ALLOW_PROTECTED:-}" != "1" ]]; then
    protect_json=$(printf '%s\n' "${payload}" | PLANKTON_PROJECT_DIR="${repo_root}" bash "${protect_hook}")
    decision=$(printf '%s' "${protect_json}" | jaq -r '.decision // empty' 2>/dev/null || echo "")
    if [[ "${decision}" == "block" ]]; then
      reason=$(printf '%s' "${protect_json}" | jaq -r '.reason // "Protected file change blocked."' 2>/dev/null || echo "Protected file change blocked.")
      echo "plankton: ${rel_path}: ${reason}" >&2
      had_failure=1
      continue
    fi
  fi

  before_hash=""
  set +e
  before_hash=$(sha_file "${abs_path}")
  before_hash_status=$?
  set -e
  if [[ "${before_hash_status}" -ne 0 ]]; then
    before_hash=""
  fi

  stdout_file=$(mktemp)
  stderr_file=$(mktemp)

  set +e
  PLANKTON_PROJECT_DIR="${repo_root}" \
    HOOK_SKIP_SUBPROCESS=1 \
    bash "${lint_hook}" <<<"${payload}" >"${stdout_file}" 2>"${stderr_file}"
  hook_status=$?
  set -e

  after_hash=""
  set +e
  after_hash=$(sha_file "${abs_path}")
  after_hash_status=$?
  set -e
  if [[ "${after_hash_status}" -ne 0 ]]; then
    after_hash=""
  fi

  if [[ -n "${before_hash}" ]] && [[ -n "${after_hash}" ]] && [[ "${before_hash}" != "${after_hash}" ]]; then
    echo "plankton: ${rel_path}: deterministic fixes modified the file; review and re-stage it" >&2
    had_failure=1
  fi

  case "${hook_status}" in
    0) ;;
    2)
      message=""
      set +e
      message=$(summarize_remaining "${stderr_file}")
      message_status=$?
      set -e
      if [[ "${message_status}" -ne 0 ]]; then
        message=""
      fi
      [[ -z "${message:-}" ]] && message="violations remain after deterministic checks"
      echo "plankton: ${rel_path}: ${message}" >&2
      had_failure=1
      ;;
    *)
      echo "plankton: ${rel_path}: hook runner failed (exit ${hook_status})" >&2
      if [[ -s "${stderr_file}" ]]; then
        cat "${stderr_file}" >&2
      fi
      had_failure=1
      ;;
  esac

  rm -f "${stdout_file}" "${stderr_file}"
done < <(git -C "${repo_root}" diff --cached --name-only --diff-filter=ACMR -z || true)

if [[ "${saw_file}" -eq 0 ]]; then
  exit 0
fi

if [[ "${had_failure}" -ne 0 ]]; then
  cat <<'EOF_INNER' >&2
plankton: Git pre-commit runs deterministic file checks matching runtime hooks.
If a file was auto-fixed, re-stage it and commit again.
EOF_INNER
  exit 1
fi

exit 0
