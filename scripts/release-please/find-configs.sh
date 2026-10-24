#!/usr/bin/env bash
set -euo pipefail

git ls-files ':(glob)**/release-please-config.json' |
  jq -R -s -c 'split("\n") | map(select(. != "") | sub("/?release-please-config\\.json$"; "") | if . == "" then "." else . end) | sort'
