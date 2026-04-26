#!/usr/bin/env bash
# Plankton-managed Git commit-msg hook runner.
# Rejects AI-attribution boilerplate in commit messages.

set -euo pipefail

if [[ "${PLANKTON_GIT_HOOKS:-1}" == "0" ]]; then
  exit 0
fi

msg_file="${1:-}"
[[ -z "${msg_file}" ]] && exit 0
[[ ! -f "${msg_file}" ]] && exit 0

if grep -Eiq '(^|\b)(co-authored-by|generated[ -]by|ai assistant)(\b|:)' "${msg_file}"; then
  cat >&2 <<'EOF_INNER'
Commit message rejected by Plankton: AI attribution strings are not allowed.

Blocked patterns:
- Co-Authored-By
- generated-by boilerplate
- AI assistant attribution
EOF_INNER
  exit 1
fi

exit 0
