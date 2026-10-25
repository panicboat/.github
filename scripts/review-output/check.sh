#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

case "${mode}" in
  docs-sync) filter='select(type == "object" and (.passed | type) == "boolean" and (.body | type) == "string" and (.body | length) >= 1) | {passed, body}' ;;
  review) filter='select(type == "object" and (.body | type) == "string" and (.body | length) >= 1) | {body}' ;;
  *) echo "::warning::unknown mode: ${mode}" >&2; exit 1 ;;
esac

if ! parsed="$(jq -ce "${filter}" <<<"${STRUCTURED_OUTPUT:-}" 2>/dev/null)" || [ -z "${parsed}" ]; then
  echo "::warning::the model's structured output is missing or malformed" >&2
  exit 1
fi

# The body becomes a public PR comment, so a leaked job token must never reach it.
if [ -n "${GITHUB_TOKEN_VALUE:-}" ] && jq -e --arg token "${GITHUB_TOKEN_VALUE}" '.body | contains($token)' <<<"${parsed}" >/dev/null; then
  echo "::warning::the model's output contains the job's GitHub token" >&2
  exit 1
fi

printf '%s\n' "${parsed}"
