#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parse="${script_dir}/parse.sh"
failed=0

check() {
  local name="$1" mode="$2" input="$3" expected_exit="$4" expected_stdout="$5"
  local actual_stdout actual_exit
  actual_stdout="$(printf '%s' "$input" | bash "$parse" "$mode" 2>/dev/null)"
  actual_exit=$?
  if [ "$actual_exit" = "$expected_exit" ] && [ "$actual_stdout" = "$expected_stdout" ]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    echo "  expected: exit=${expected_exit} stdout=${expected_stdout}"
    echo "  actual:   exit=${actual_exit} stdout=${actual_stdout}"
    failed=1
  fi
}

long_body="$(printf 'a%.0s' $(seq 60001))"

check accepts_docs_sync_object docs-sync '{"passed":true,"body":"## Docs Sync Check"}' 0 '{"passed":true,"body":"## Docs Sync Check"}'
check accepts_failed_verdict docs-sync '{"passed":false,"body":"x"}' 0 '{"passed":false,"body":"x"}'
check strips_json_code_fence docs-sync $'```json\n{"passed":true,"body":"x"}\n```' 0 '{"passed":true,"body":"x"}'
check strips_bare_code_fence docs-sync $'```\n{"passed":true,"body":"x"}\n```' 0 '{"passed":true,"body":"x"}'
check trims_surrounding_whitespace docs-sync $'\n  {"passed":true,"body":"x"}  \n' 0 '{"passed":true,"body":"x"}'
check rejects_text_around_json docs-sync $'Here is the result:\n{"passed":true,"body":"x"}' 1 ''
check rejects_string_passed docs-sync '{"passed":"true","body":"x"}' 1 ''
check rejects_missing_passed docs-sync '{"body":"x"}' 1 ''
check rejects_empty_body docs-sync '{"passed":true,"body":""}' 1 ''
check rejects_non_string_body docs-sync '{"passed":true,"body":1}' 1 ''
check rejects_body_over_60000 docs-sync "{\"passed\":true,\"body\":\"${long_body}\"}" 1 ''
check rejects_empty_response docs-sync '' 1 ''
check rejects_array docs-sync '[{"passed":true,"body":"x"}]' 1 ''
check rejects_trailing_json_value docs-sync '{"passed":true,"body":"x"} {"foo":1}' 1 ''
check rejects_two_verdicts docs-sync $'{"passed":false,"body":"x"}\n{"passed":true,"body":"y"}' 1 ''
check accepts_review_object review '{"body":"## Renovate Major Update Review"}' 0 '{"body":"## Renovate Major Update Review"}'
check drops_extra_fields review '{"body":"x","passed":true}' 0 '{"body":"x"}'
check rejects_review_without_body review '{"passed":true}' 1 ''
check rejects_unknown_mode other '{"body":"x"}' 1 ''

exit "$failed"
