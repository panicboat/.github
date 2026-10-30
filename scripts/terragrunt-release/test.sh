#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "${work_root}"' EXIT

last_stderr=""

assert_eq() {
    local expected="$1" actual="$2"
    if [ "${expected}" != "${actual}" ]; then
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

assert_fails() {
    local stderr_file="${work_root}/stderr"
    if "$@" 2>"${stderr_file}"; then
        echo "  expected a non-zero exit: $*" >&2
        exit 1
    fi
    last_stderr="$(cat "${stderr_file}")"
}

assert_stderr_contains() {
    local needle="$1"
    if [[ "${last_stderr}" != *"${needle}"* ]]; then
        echo "  stderr does not contain: ${needle}" >&2
        echo "  stderr: ${last_stderr}" >&2
        exit 1
    fi
}

test_release_service_parses_tag() {
    assert_eq "monolith" "$(bash "${script_dir}/release-service.sh" --tag monolith-v1.2.3)"
}

test_release_service_rejects_root_tag() {
    assert_fails bash "${script_dir}/release-service.sh" --tag v0.1.0
    assert_stderr_contains "::error::"
}

test_release_service_rejects_flux_tag() {
    assert_fails bash "${script_dir}/release-service.sh" --tag kubernetes-production
    assert_stderr_contains "::error::"
}

test_release_service_parses_branch() {
    assert_eq "pennyworth" "$(bash "${script_dir}/release-service.sh" --branch release-please--branches--main--components--pennyworth)"
}

test_release_service_rejects_root_branch() {
    assert_fails bash "${script_dir}/release-service.sh" --branch release-please--branches--main
    assert_stderr_contains "::error::"
}

test_release_service_error_is_single_line() {
    assert_fails bash "${script_dir}/release-service.sh" --tag $'monolith-v1.2.3\n::warning::x'
    assert_stderr_contains "::error::"
    assert_eq "1" "$(printf '%s\n' "${last_stderr}" | wc -l | tr -d ' ')"
}

resolver_targets='[
    {"service":"monolith","environment":"production","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/production","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"arn:aws:iam::222222222222:role/production-plan","iam_role_apply":"arn:aws:iam::222222222222:role/production-apply"},
    {"service":"monolith","environment":"develop","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/develop","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"arn:aws:iam::111111111111:role/develop-plan","iam_role_apply":"arn:aws:iam::111111111111:role/develop-apply"},
    {"service":"monolith","stack":"container","working_directory":"dystopia/monolith","type":"container"},
    {"service":"monolith","environment":"production","stack":"kubernetes","working_directory":"dystopia/monolith/kubernetes/overlays/production","type":"kustomize"}
]'

test_release_targets_keeps_production_terragrunt_targets() {
    local expected='[{"service":"monolith","environment":"production","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/production","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"arn:aws:iam::222222222222:role/production-plan","iam_role_apply":"arn:aws:iam::222222222222:role/production-apply"}]'
    assert_eq "${expected}" "$(bash "${script_dir}/release-targets.sh" <<<"${resolver_targets}")"
}

test_release_targets_returns_empty_for_empty_input() {
    assert_eq "[]" "$(bash "${script_dir}/release-targets.sh" <<<'[]')"
}

test_release_targets_rejects_empty_stdin() {
    assert_fails bash "${script_dir}/release-targets.sh" </dev/null
}

write_service_release_config() {
    local package="$1" component="${2:-${1##*/}}" exclude_paths="${3:-[\"$1/infrastructure/aws/develop\"]}"
    mkdir -p "${package}"
    cat > "${package}/release-please-config.json" <<JSON
{"packages":{"${package}":{"release-type":"simple","component":"${component}","include-component-in-tag":true,"exclude-paths":${exclude_paths}}}}
JSON
    echo "{\"${package}\":\"0.1.0\"}" > "${package}/release-please-manifest.json"
}

terragrunt_candidate() {
    local service="$1" root="$2" excluded="${3:-false}" environment="${4:-production}"
    jq -nc --arg service "${service}" --arg root "${root}" --arg environment "${environment}" --argjson excluded "${excluded}" '{
        target: {
            service: $service,
            environment: $environment,
            stack: "terragrunt",
            working_directory: "\($root)/infrastructure/aws/\($environment)",
            type: "terragrunt",
            aws_region: "ap-northeast-1",
            iam_role_plan: "arn:aws:iam::222222222222:role/\($environment)-plan",
            iam_role_apply: "arn:aws:iam::222222222222:role/\($environment)-apply"
        },
        excluded: $excluded,
        root: $root
    }'
}

write_candidates() {
    printf '%s\n' "$@" | jq -sc '.' > candidates.json
}

check_configs() {
    git init -q
    git add -A
    bash "${script_dir}/check-release-configs.sh" candidates.json
}

test_check_configs_accepts_matching_set() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith)"
    write_service_release_config dystopia/monolith
    write_service_release_config dystopia/frontend
    assert_eq "" "$(check_configs 2>&1)"
}

test_check_configs_rejects_missing_config() {
    write_candidates "$(terragrunt_candidate pennyworth system-components/pennyworth)"
    assert_fails check_configs
    assert_stderr_contains "system-components/pennyworth/release-please-config.json"
}

test_check_configs_rejects_wrong_component() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith)"
    write_service_release_config dystopia/monolith frontend
    assert_fails check_configs
    assert_stderr_contains "dystopia/monolith: component must be monolith (got 'frontend')"
}

test_check_configs_rejects_manifest_without_package() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith)"
    write_service_release_config dystopia/monolith
    echo '{}' > dystopia/monolith/release-please-manifest.json
    assert_fails check_configs
    assert_stderr_contains "dystopia/monolith/release-please-manifest.json"
    rm dystopia/monolith/release-please-manifest.json
    assert_fails check_configs
    assert_stderr_contains "dystopia/monolith/release-please-manifest.json"
}

test_check_configs_rejects_incomplete_release_env() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith | jq -c '.target |= with_entries(select(.key | IN("aws_region", "iam_role_plan", "iam_role_apply") | not))')"
    write_service_release_config dystopia/monolith
    assert_fails check_configs
    assert_stderr_contains "dystopia/monolith/infrastructure/aws/production"
    assert_stderr_contains "aws_region"
    assert_stderr_contains "iam_role_plan"
    assert_stderr_contains "iam_role_apply"
}

test_check_configs_skips_incomplete_excluded_env() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith true | jq -c '.target.aws_region = ""')"
    write_service_release_config dystopia/monolith
    assert_eq "" "$(check_configs 2>&1)"
}

test_check_configs_requires_config_for_excluded_env() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith true)"
    assert_fails check_configs
    assert_stderr_contains "dystopia/monolith/release-please-config.json"
    write_service_release_config dystopia/monolith
    assert_eq "" "$(check_configs 2>&1)"
}

test_check_configs_ignores_candidates_that_are_not_terragrunt_production() {
    write_candidates \
        "$(terragrunt_candidate monolith dystopia/monolith false develop)" \
        "$(jq -nc '{target: {service: "frontend", stack: "container", working_directory: "dystopia/frontend", type: "container"}, excluded: false, root: "dystopia/frontend"}')" \
        "$(terragrunt_candidate pennyworth system-components/pennyworth | jq -c '.target.environment = "staging"')"
    assert_eq "" "$(check_configs 2>&1)"
}

test_check_configs_rejects_candidates_that_are_not_an_array() {
    echo '' > candidates.json
    assert_fails check_configs
    assert_stderr_contains "::error::"
    echo '{}' > candidates.json
    assert_fails check_configs
    assert_stderr_contains "::error::"
}

test_check_configs_ignores_exclude_paths() {
    write_candidates "$(terragrunt_candidate monolith dystopia/monolith)"
    write_service_release_config dystopia/monolith monolith '["unrelated/path"]'
    assert_eq "" "$(check_configs 2>&1)"
    jq -c 'del(.packages["dystopia/monolith"]["exclude-paths"])' dystopia/monolith/release-please-config.json > config.tmp
    mv config.tmp dystopia/monolith/release-please-config.json
    assert_eq "" "$(check_configs 2>&1)"
}

test_check_configs_ignores_untracked_configs() {
    write_candidates
    write_service_release_config dystopia/frontend
    git init -q
    git add -A
    write_service_release_config node_modules/pkg pkg '[]'
    assert_eq "" "$(bash "${script_dir}/check-release-configs.sh" candidates.json 2>&1)"
}

test_check_configs_rejects_duplicate_service() {
    write_candidates
    write_service_release_config dystopia/monolith
    write_service_release_config system-components/monolith
    assert_fails check_configs
    assert_stderr_contains "component monolith is used by more than one package: dystopia/monolith system-components/monolith"
}

failed=0
for test_name in $(compgen -A function test_); do
    fixture="$(mktemp -d "${work_root}/fixture.XXXXXX")"
    set +e
    (set -e; cd "${fixture}"; "${test_name}")
    status=$?
    set -e
    if [ "${status}" -eq 0 ]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
        failed=1
    fi
done

exit "${failed}"
