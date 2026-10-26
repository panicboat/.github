#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fallback_script="${script_dir}/fallback.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
failed=0

# A log of "-" leaves EXECUTION_FILE empty, as when the action never wrote one.
check() {
  local name="$1" token_outcome="$2" claude_outcome="$3" log="$4" expected="$5"
  local execution_file="" actual
  if [ "$log" != "-" ]; then
    execution_file="${work_dir}/${name}.json"
    printf '%s' "$log" > "$execution_file"
  fi
  actual="$(TOKEN_OUTCOME="$token_outcome" CLAUDE_OUTCOME="$claude_outcome" EXECUTION_FILE="$execution_file" bash "$fallback_script" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  if [ "$actual" = "$expected" ]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    failed=1
  fi
}

check falls_back_when_the_token_is_unavailable failure skipped - 'fallback=true reason=token-unavailable'
check keeps_a_successful_subscription_run success success '[{"type":"result","subtype":"success"}]' 'fallback=false reason='
check falls_back_when_the_run_fails_without_a_log success failure - 'fallback=true reason=subscription-failed'
check falls_back_when_the_log_has_no_result success failure '[]' 'fallback=true reason=subscription-failed'
check falls_back_when_the_log_is_not_json success failure 'not json' 'fallback=true reason=subscription-failed'
check falls_back_on_an_error_result success failure '[{"type":"result","subtype":"error_during_execution"}]' 'fallback=true reason=subscription-failed'
check keeps_a_budget_stop success failure '[{"type":"result","subtype":"error_max_budget_usd"}]' 'fallback=false reason='
check keeps_a_turn_stop success failure '[{"type":"result","subtype":"error_max_turns"}]' 'fallback=false reason='
check keeps_a_structured_output_stop success failure '[{"type":"result","subtype":"error_max_structured_output_retries"}]' 'fallback=false reason='
check reads_the_last_result success failure '[{"type":"result","subtype":"error_during_execution"},{"type":"system"},{"type":"result","subtype":"error_max_budget_usd"}]' 'fallback=false reason='

exit "$failed"
