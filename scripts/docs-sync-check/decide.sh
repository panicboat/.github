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

if ! grep -qE "$scope_pattern" <<<"$changed_files"; then
  emit skip-unchanged
  exit 0
fi

emit judge
