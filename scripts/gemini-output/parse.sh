#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

case "${mode}" in
  docs-sync) filter='select(type == "object" and (.passed | type) == "boolean" and (.body | type) == "string" and (.body | length) >= 1 and (.body | length) <= 60000) | {passed, body}' ;;
  review) filter='select(type == "object" and (.body | type) == "string" and (.body | length) >= 1 and (.body | length) <= 60000) | {body}' ;;
  *) echo "::warning::unknown mode: ${mode}" >&2; exit 1 ;;
esac

response="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF { started = 1 } started')"

# Gemini CLI cannot force a response schema, so a fenced answer is accepted but any prose around it is not.
if [[ "$(head -n 1 <<<"${response}")" =~ ^\`\`\`(json)?$ ]] && [ "$(tail -n 1 <<<"${response}")" = '```' ]; then
  response="$(sed -e '1d' -e '$d' <<<"${response}")"
fi

if ! parsed="$(jq -ce "${filter}" <<<"${response}" 2>/dev/null)" || [ -z "${parsed}" ]; then
  echo "::warning::the model's final answer is not the expected JSON object" >&2
  exit 1
fi

printf '%s\n' "${parsed}"
