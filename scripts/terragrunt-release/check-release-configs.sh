#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "::error::usage: check-release-configs.sh <candidates_json_path>" >&2
    exit 1
fi
candidates_path="$1"

failed=0

report() {
    echo "::error::$*" >&2
    failed=1
}

if ! jq -e 'type == "array" and all(.[]; type == "object" and (.target | type == "object"))' "${candidates_path}" >/dev/null 2>&1; then
    echo "::error::${candidates_path} must hold the label resolver candidates as a JSON array of objects with a target object" >&2
    exit 1
fi

# Excluded candidates still need a release-please config, so they stay in the release set.
release_candidates="$(jq -c '[.[] | select(.target.type == "terragrunt" and .target.environment == "production")]' "${candidates_path}")"

incomplete="$(jq -r '
    .[] | select(.excluded | not) | .target as $target
    | ("aws_region", "iam_role_plan", "iam_role_apply") as $field
    | select(($target[$field] // "") == "")
    | "::error::release target \($target.working_directory) has no \($field)"
' <<<"${release_candidates}")"
if [ -n "${incomplete}" ]; then
    echo "${incomplete}" >&2
    failed=1
fi

release_packages="$(jq -r 'map([.target.service, .root]) | unique[] | @tsv' <<<"${release_candidates}")"

while IFS=$'\t' read -r service package; do
    [ -n "${service}" ] || continue
    config_file="${package}/release-please-config.json"
    manifest_file="${package}/release-please-manifest.json"

    if [ ! -f "${config_file}" ]; then
        report "${config_file} is missing but ${service} has a release environment"
        continue
    fi

    component="$(jq -r --arg package "${package}" '.packages[$package].component // ""' "${config_file}")"
    if [ "${component}" != "${service}" ]; then
        report "${package}: component must be ${service} (got '${component}')"
    fi

    if [ ! -f "${manifest_file}" ] || ! jq -e --arg package "${package}" 'has($package)' "${manifest_file}" >/dev/null; then
        report "${manifest_file} must have the key ${package}"
    fi
done <<<"${release_packages}"

components=""
config_files="$(git ls-files '*/release-please-config.json')"
while IFS= read -r config_file; do
    [ -n "${config_file}" ] || continue
    packages="$(jq -r '.packages // {} | to_entries[] | [.key, (.value.component // "")] | @tsv' "${config_file}")"
    while IFS=$'\t' read -r package component; do
        [ -n "${package}" ] || continue
        if [ -n "${component}" ]; then
            components+="${component}"$'\t'"${package}"$'\n'
        fi
    done <<<"${packages}"
done <<<"${config_files}"

# A release tag names only the component, so a component shared by two packages would release both.
duplicates="$(jq -R -s -r '
    split("\n") | map(select(. != "") | split("\t")) | group_by(.[0])[]
    | select(length > 1)
    | "::error::component \(.[0][0]) is used by more than one package: \(map(.[1]) | join(" "))"
' <<<"${components}")"
if [ -n "${duplicates}" ]; then
    echo "${duplicates}" >&2
    failed=1
fi

exit "${failed}"
