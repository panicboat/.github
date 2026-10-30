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
