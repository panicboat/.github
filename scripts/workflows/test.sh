#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
workflows_dir="${repo_root}/.github/workflows"

assert_eq() {
    local expected="$1" actual="$2"
    if [ "${expected}" != "${actual}" ]; then
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

test_resolver_applies_only_merge_targets() {
    local expected="\${{ matrix.target.stack == 'terragrunt' && (github.event_name == 'pull_request' && 'plan' || (matrix.target.apply_trigger == 'merge' && 'apply' || '')) || '' }}"
    local actual
    actual="$(yq '.jobs["deploy-terragrunt"].with["action-type"]' "${workflows_dir}/reusable--label-base-deploy--resolver.yaml")"
    assert_eq "${expected}" "${actual}"
}

test_release_workflows_skip_empty_targets() {
    local guard="needs.resolve.outputs.targets != '[]'"
    assert_eq "${guard}" "$(yq '.jobs.plan.if' "${workflows_dir}/reusable--release--plan.yaml")"
    assert_eq "${guard}" "$(yq '.jobs.apply.if' "${workflows_dir}/reusable--release--deploy.yaml")"
}

test_release_deploy_declares_environment() {
    local workflow="${workflows_dir}/reusable--release--deploy.yaml"
    assert_eq '${{ matrix.target.environment }}' "$(yq '.jobs.apply.with["github-environment"]' "${workflow}")"
    assert_eq '${{ needs.resolve.outputs.tag }}' "$(yq '.jobs.apply.with.ref' "${workflow}")"
}

test_nested_test_workflow_uses_dollar_slash() {
    local workflow="${workflows_dir}/test-shared-workflows--nested.yaml"
    assert_eq '$/.github/workflows/test-shared-workflows--checkout.yaml' "$(yq '.jobs[].uses' "${workflow}")"
}

failed=0
for test_name in $(compgen -A function test_); do
    set +e
    (set -e; "${test_name}")
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
