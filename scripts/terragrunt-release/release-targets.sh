#!/usr/bin/env bash
set -euo pipefail

jq -c 'map(select(.type == "terragrunt" and .environment == "production"))'
