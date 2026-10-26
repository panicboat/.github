#!/usr/bin/env bash
set -euo pipefail

decide() {
  if [ "${TOKEN_OUTCOME:-}" != "success" ]; then
    echo "true token-unavailable"
    return
  fi
  if [ "${CLAUDE_OUTCOME:-}" = "success" ]; then
    echo "false "
    return
  fi
  local subtype=""
  if [ -n "${EXECUTION_FILE:-}" ] && [ -s "${EXECUTION_FILE}" ]; then
    # SILENT: an unreadable log means the run failed before the model answered, which is a reason to fall back.
    subtype="$(jq -r '[.[] | select(.type == "result")] | last | .subtype // ""' "${EXECUTION_FILE}" 2>/dev/null || true)"
  fi
  # A run stopped by its own limits or unable to shape its output would stop the same way on Bedrock, so only the cost would grow.
  case "${subtype}" in
    error_max_budget_usd|error_max_turns|error_max_structured_output_retries) echo "false " ;;
    *) echo "true subscription-failed" ;;
  esac
}

read -r fallback reason <<<"$(decide)"
echo "fallback=${fallback}"
echo "reason=${reason:-}"
