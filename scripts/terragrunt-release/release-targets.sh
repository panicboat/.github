#!/usr/bin/env bash
set -euo pipefail

service="${1:?usage: release-targets.sh <service> [config_path] | release-targets.sh --all [config_path]}"
config_path="${2:-workflow-config.yaml}"

all=false
if [ "${service}" = "--all" ]; then
    all=true
fi

config="$(yq -o=json '.' "${config_path}")"

# A path without {service} or {environment} cannot be tied to a release, so it never yields a target.
patterns="$(jq -r --arg service "${service}" --argjson all "${all}" '
    .stacks | to_entries[]
    | select(.value.name == "terragrunt")
    | .key as $stack
    | .value as $value
    | ($value.environments | to_entries[] | select(.value.apply_trigger == "release") | .key) as $environment
    | $value.paths[]
    | select(contains("{service}") and contains("{environment}"))
    | [$stack, ., $environment, (gsub("\\{environment\\}"; $environment) | if $all then . else gsub("\\{service\\}"; $service) end)]
    | @tsv
' <<<"${config}")"

placeholder='^\{[a-z_][a-z0-9_]*\}$'
shopt -s nullglob

# Walks one segment at a time so that a literal segment is never expanded as a glob.
find_directories() {
    local segments segment dir child dirs="." next
    IFS=/ read -r -a segments <<<"$1"
    for segment in "${segments[@]}"; do
        next=""
        while IFS= read -r dir; do
            [ -n "${dir}" ] || continue
            if [[ "${segment}" =~ ${placeholder} ]]; then
                for child in "${dir}"/*/; do
                    next+="${child%/}"$'\n'
                done
            elif [ -d "${dir}/${segment}" ]; then
                next+="${dir}/${segment}"$'\n'
            fi
        done <<<"${dirs}"
        dirs="${next}"
    done
    printf '%s' "${dirs}"
}

matches=""
while IFS=$'\t' read -r stack pattern environment search; do
    [ -n "${pattern}" ] || continue
    while IFS= read -r directory; do
        [ -n "${directory}" ] || continue
        matches+="${stack}"$'\t'"${pattern}"$'\t'"${environment}"$'\t'"${directory#./}"$'\n'
    done <<<"$(find_directories "${search}")"
done <<<"${patterns}"

jq -R -s -c --argjson config "${config}" --argjson all "${all}" '
    def capture_regex:
        "^" + (split("/") | map(
            if test("^\\{[a-z_][a-z0-9_]*\\}$") then "(?<\(.[1:-1])>[^/]+)"
            else gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\])"; "\\\(.c)") end
        ) | join("/")) + "$";
    [
        split("\n")[] | select(. != "") | split("\t")
        | . as [$stack, $pattern, $environment, $directory]
        | $config.stacks[$stack | tonumber] as $stack_config
        | $stack_config.environments[$environment] as $attributes
        | ($directory | capture($pattern | capture_regex)) as $values
        | {
            service: $values.service,
            environment: $environment,
            working_directory: $directory,
            aws_region: $attributes.aws_region,
            iam_role_plan: $attributes.iam_role_plan,
            iam_role_apply: $attributes.iam_role_apply,
            pattern: $pattern,
            excluded: any(($stack_config.exclude // [])[]; to_entries | all(.[]; . as $pair | $values | has($pair.key) and .[$pair.key] == $pair.value))
        }
    ]
    | if $all then . else map(select(.excluded | not) | del(.excluded, .pattern)) end
' <<<"${matches}"
