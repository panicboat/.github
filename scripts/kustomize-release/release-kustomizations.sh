#!/usr/bin/env bash
set -euo pipefail

service="${1:?usage: release-kustomizations.sh <service> [config_path]}"
config_path="${2:-workflow-config.yaml}"

directories="$(yq -o=json '.' "${config_path}" | jq -r --arg service "${service}" '
    .stacks[]
    | select(.name == "kustomize")
    | .paths[]
    | select(contains("{service}") and contains("{environment}"))
    | gsub("\\{service\\}"; $service)
    | gsub("\\{environment\\}"; "production")
')"

while IFS= read -r directory; do
    if [ -n "${directory}" ] && [ -d "${directory}" ]; then
        printf '%s\n' "${directory}"
    fi
done <<<"${directories}" | jq -R -s -c --arg service "${service}" '
    split("\n") | map(select(. != "")) | map({service: $service, environment: "production", kustomization_directory: .})
'
