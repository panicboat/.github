#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
decide="${script_dir}/decide.sh"
failed=0

check() {
  local name="$1" action="$2" label="$3" approved="$4" author="$5" changed="$6" prior="$7" files="$8" expected_mode="$9" expected_remove="${10}" scope="${11:-^dystopia/}"
  local expected actual
  expected="$(printf 'mode=%s\nremove_label=%s' "$expected_mode" "$expected_remove")"
  actual="$(printf '%s' "$files" | SCOPE_PATTERN="$scope" EVENT_ACTION="$action" EVENT_LABEL="$label" APPROVED="$approved" AUTHOR_TYPE="$author" BODY_OR_BASE_CHANGED="$changed" PRIOR_STATE="$prior" bash "$decide" 2>&1)"
  if [ "$actual" = "$expected" ]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    echo "  expected: ${expected//$'\n'/ | }"
    echo "  actual:   ${actual//$'\n'/ | }"
    failed=1
  fi
}

check ignores_other_labels labeled deploy:frontend false User false '' $'dystopia/a.rb' ignore false
check ignores_other_labels_even_when_approved labeled deploy:frontend true User false '' $'dystopia/a.rb' ignore false
check ignores_other_label_removed unlabeled deploy:frontend false User false '' $'dystopia/a.rb' ignore false
check skips_bots opened '' false Bot false '' $'dystopia/a.rb' skip-bot false
check skips_without_dystopia_changes opened '' false User false '' $'platform/a.tf' skip-unchanged false
check skips_empty_diff opened '' false User false '' '' skip-unchanged false
check judges_dystopia_changes opened '' false User false '' $'README.md\ndystopia/docs/x.md' judge false
check does_not_match_prefix_only opened '' false User false '' $'dystopia-old/a.rb' skip-unchanged false
check passes_on_approval_label_after_failure labeled docs-check-approved true User false failure $'dystopia/a.rb' approved false
check passes_on_approval_label_after_success labeled docs-check-approved true User false success $'dystopia/a.rb' approved false
check approval_label_before_any_verdict_rejudges labeled docs-check-approved true User false '' $'dystopia/a.rb' judge true
check approval_label_while_judging_rejudges labeled docs-check-approved true User false pending $'dystopia/a.rb' judge true
check approval_label_already_removed_rejudges labeled docs-check-approved false User false failure $'dystopia/a.rb' judge false
check approval_label_before_any_verdict_without_dystopia labeled docs-check-approved true User false '' $'platform/a.tf' skip-unchanged true
check ignores_edit_while_approved edited '' true User true '' $'dystopia/a.rb' ignore false
check ignores_reopen_while_approved reopened '' true User false '' $'dystopia/a.rb' ignore false
check ignores_title_only_edit edited '' false User false '' $'dystopia/a.rb' ignore false
check judges_body_edit edited '' false User true '' $'dystopia/a.rb' judge false
check rejudges_when_approval_removed unlabeled docs-check-approved false User false '' $'dystopia/a.rb' judge false
check opened_with_approval_rejudges opened '' true User false '' $'dystopia/a.rb' judge true
check push_after_approval_rejudges synchronize '' true User false '' $'dystopia/a.rb' judge true
check push_after_approval_without_dystopia synchronize '' true User false '' $'platform/a.tf' skip-unchanged true
check skips_changes_outside_the_scope_pattern opened '' false User false '' $'dystopia/a.rb' skip-unchanged false '^platform/'
check judges_changes_inside_the_scope_pattern opened '' false User false '' $'platform/a.tf' judge false '^platform/'

check_requires_scope_pattern() {
  local name="$1" actual
  if actual="$(printf '%s' $'dystopia/a.rb' | env -u SCOPE_PATTERN EVENT_ACTION=opened EVENT_LABEL='' APPROVED=false AUTHOR_TYPE=Bot BODY_OR_BASE_CHANGED=false PRIOR_STATE='' bash "$decide" 2>&1)"; then
    echo "FAIL ${name}"
    echo "  expected a non-zero exit, actual output: ${actual//$'\n'/ | }"
    failed=1
  elif [[ "$actual" == *SCOPE_PATTERN* ]]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    echo "  expected stderr to name SCOPE_PATTERN, actual: ${actual//$'\n'/ | }"
    failed=1
  fi
}

check_requires_scope_pattern rejects_missing_scope_pattern_even_when_the_event_exits_early

exit "$failed"
