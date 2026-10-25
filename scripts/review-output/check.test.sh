#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="${script_dir}/check.sh"
failed=0

check() {
  local name="$1" mode="$2" output="$3" token="$4" expected_exit="$5" expected_stdout="$6"
  local actual_stdout actual_exit
  actual_stdout="$(STRUCTURED_OUTPUT="$output" GITHUB_TOKEN_VALUE="$token" bash "$check_script" "$mode" 2>/dev/null)"
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

check accepts_docs_sync docs-sync '{"passed":true,"body":"x"}' tok 0 '{"passed":true,"body":"x"}'
check accepts_failed_verdict docs-sync '{"passed":false,"body":"x"}' tok 0 '{"passed":false,"body":"x"}'
check accepts_review review '{"body":"x"}' tok 0 '{"body":"x"}'
check drops_extra_fields review '{"body":"x","passed":true}' tok 0 '{"body":"x"}'
check rejects_empty_output docs-sync '' tok 1 ''
check rejects_invalid_json docs-sync 'not json' tok 1 ''
check rejects_body_with_token docs-sync '{"passed":true,"body":"leak tok here"}' tok 1 ''
check rejects_review_body_with_token review '{"body":"tok"}' tok 1 ''
check rejects_string_passed docs-sync '{"passed":"true","body":"x"}' tok 1 ''
check rejects_missing_body review '{}' tok 1 ''
check rejects_empty_body review '{"body":""}' tok 1 ''
check rejects_unknown_mode other '{"body":"x"}' tok 1 ''
check ignores_empty_token review '{"body":"x"}' '' 0 '{"body":"x"}'

exit "$failed"
