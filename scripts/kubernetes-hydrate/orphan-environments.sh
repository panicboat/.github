#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# An orphan is what hydrate-index.sh removes, so the two loops must agree.
for env_dir in kubernetes/manifests/*/; do
    [ -d "${env_dir}" ] || continue
    env=$(basename "${env_dir}")
    for dir in "${env_dir}"*/; do
        [ -d "${dir}" ] || continue
        name=$(basename "${dir}")
        [ "${name}" = "00-namespaces" ] && continue
        if [ ! -d "kubernetes/components/${name}/${env}" ]; then
            printf '%s\n' "${env}"
            break
        fi
    done
done | jq -Rsc 'split("\n") | map(select(length > 0))'
