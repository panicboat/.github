#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "${work_root}"' EXIT

assert_eq() {
    local expected="$1" actual="$2"
    if [ "${expected}" != "${actual}" ]; then
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

resolver_targets='[
    {"service":"monolith","environment":"production","stack":"kubernetes","working_directory":"dystopia/monolith/kubernetes/overlays/production","type":"kustomize"},
    {"service":"monolith","environment":"develop","stack":"kubernetes","working_directory":"dystopia/monolith/kubernetes/overlays/develop","type":"kustomize"},
    {"service":"monolith","environment":"production","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/production","type":"terragrunt","aws_region":"ap-northeast-1"},
    {"service":"monolith","stack":"container","working_directory":"dystopia/monolith","type":"container"}
]'

test_release_kustomizations_maps_production_overlays() {
    local expected='[{"service":"monolith","environment":"production","kustomization_directory":"dystopia/monolith/kubernetes/overlays/production"}]'
    assert_eq "${expected}" "$(bash "${script_dir}/release-kustomizations.sh" <<<"${resolver_targets}")"
}

test_release_kustomizations_returns_empty_without_kustomize_targets() {
    local targets
    targets="$(jq -c 'map(select(.type != "kustomize"))' <<<"${resolver_targets}")"
    assert_eq "[]" "$(bash "${script_dir}/release-kustomizations.sh" <<<"${targets}")"
}

init_origin_with_tags() {
    git init -q --bare origin.git
    git init -q repo
    git -C repo -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    local tag
    for tag in "$@"; do
        git -C repo tag "${tag}"
    done
    git -C repo remote add origin "$(pwd)/origin.git"
    git -C repo push -q origin --tags
}

test_previous_release_tag_picks_the_highest_version_of_the_service() {
    init_origin_with_tags pennyworth-v1.2.0 pennyworth-v1.10.0 pennyworth-v1.9.3 monolith-v2.0.0
    local tag
    tag="$(cd repo && bash "${script_dir}/previous-release-tag.sh" pennyworth)"
    assert_eq "pennyworth-v1.10.0" "${tag}"
}

test_previous_release_tag_ignores_services_sharing_a_prefix() {
    init_origin_with_tags front-v1.0.0 frontend-v0.11.0
    local tag
    tag="$(cd repo && bash "${script_dir}/previous-release-tag.sh" front)"
    assert_eq "front-v1.0.0" "${tag}"
}

test_previous_release_tag_is_empty_without_a_release() {
    init_origin_with_tags monolith-v0.9.0
    local tag
    tag="$(cd repo && bash "${script_dir}/previous-release-tag.sh" pennyworth)"
    assert_eq "" "${tag}"
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
