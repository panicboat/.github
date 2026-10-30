#!/usr/bin/env bash
set -euo pipefail

jq -c 'map(select(.type == "kustomize" and .environment == "production") | {service, environment, kustomization_directory: .working_directory})'
