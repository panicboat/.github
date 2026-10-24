#!/usr/bin/env bash
set -euo pipefail

# Read stdin before any early exit so the upstream command under pipefail does not die of SIGPIPE.
changed_files="$(cat)"
scope_pattern="${SCOPE_PATTERN:?SCOPE_PATTERN is required}"
is_approved="$APPROVED"
remove_label=false

emit() {
  echo "mode=$1"
  echo "remove_label=${remove_label}"
}

case "$EVENT_ACTION" in
  labeled | unlabeled)
    if [ "$EVENT_LABEL" != "docs-check-approved" ]; then
      emit ignore
      exit 0
    fi
    ;;
esac

if [ "$AUTHOR_TYPE" = "Bot" ]; then
  emit skip-bot
  exit 0
fi

if [ "$EVENT_ACTION" = "edited" ] && [ "$BODY_OR_BASE_CHANGED" != "true" ]; then
  emit ignore
  exit 0
fi

case "$EVENT_ACTION" in
  labeled)
    # Approval needs an existing verdict on the commit, since a label set at PR creation can cancel the opened run.
    if [ "$is_approved" = "true" ] && [ "$PRIOR_STATE" != "" ] && [ "$PRIOR_STATE" != "pending" ]; then
      emit approved
      exit 0
    fi
    remove_label="$is_approved"
    is_approved=false
    ;;
  unlabeled)
    is_approved=false
    ;;
  synchronize | opened)
    if [ "$is_approved" = "true" ]; then
      is_approved=false
      remove_label=true
    fi
    ;;
esac

if [ "$is_approved" = "true" ]; then
  emit ignore
  exit 0
fi

scope_status=0
grep -qE -e "$scope_pattern" <<<"$changed_files" || scope_status=$?
if [ "$scope_status" -gt 1 ]; then
  echo "SCOPE_PATTERN is not a valid extended regular expression: ${scope_pattern}" >&2
  exit 1
fi

if [ "$scope_status" -eq 1 ]; then
  emit skip-unchanged
  exit 0
fi

emit judge
