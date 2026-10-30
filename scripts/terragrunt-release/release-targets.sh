#!/usr/bin/env bash
set -euo pipefail

jq -cn 'input | map(select(.type == "terragrunt" and .environment == "production"))'
