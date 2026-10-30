#!/usr/bin/env bash
set -euo pipefail

jq -cn 'input | map(select(.type == "kustomize" and .environment == "production") | {service, environment, kustomization_directory: .working_directory})'
