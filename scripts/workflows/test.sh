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

test_kustomize_builder_checks_out_head_ref_only_for_helmfile() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    local kustomize_builder="${workflows_dir}/internal--kustomize-builder.yaml"
    assert_eq '${{ github.head_ref }}' "$(yq '.jobs["deploy-helmfile"].with.ref' "${resolver}")"
    assert_eq 'null' "$(yq '.jobs["deploy-kustomize"].with.ref' "${resolver}")"
    assert_eq '${{ inputs.ref }}' "$(yq '.jobs["kustomize-diff"].steps[] | select(.name == "Checkout") | .with.ref' "${kustomize_builder}")"
}

test_nested_test_workflow_uses_dollar_slash() {
    local workflow="${workflows_dir}/self--test-shared-workflows--nested.yaml"
    assert_eq '$/.github/workflows/self--test-shared-workflows--checkout.yaml' "$(yq '.jobs[].uses' "${workflow}")"
}

test_nested_calls_resolve_to_existing_workflows() {
    local target
    for target in $(yq -N '.jobs[].uses | select(. != null and test("^\\$/"))' "${workflows_dir}"/*.y*ml); do
        [ -f "${repo_root}/${target#\$/}" ] || { echo "  missing: ${target}" >&2; exit 1; }
    done
}

test_workflows_carry_matching_file_and_name_prefix() {
    local workflow file prefix
    for workflow in "${workflows_dir}"/*; do
        file="$(basename "${workflow}")"
        case "${file}" in
            reusable--*.yaml) prefix='Reusable - ' ;;
            internal--*.yaml) prefix='Internal - ' ;;
            self--*.yaml) prefix='Self - ' ;;
            *) echo "  unknown prefix: ${file}" >&2; exit 1 ;;
        esac
        [[ "$(yq '.name' "${workflow}")" == "${prefix}"* ]] || { echo "  name mismatch: ${file}" >&2; exit 1; }
    done
}

test_docs_sync_judge_uses_gemini_on_vertex() {
    local wf="${workflows_dir}/reusable--docs-sync-check.yaml"
    assert_eq "google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489" "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .uses' "${wf}")"
    assert_eq "gemini-3.5-flash-lite" "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .with.gemini_model' "${wf}")"
    assert_eq "" "$(yq '.jobs.judge.steps[] | select(.with.role-to-assume) | .name' "${wf}")"
}

test_docs_sync_judge_allows_only_read_tools() {
    local wf="${workflows_dir}/reusable--docs-sync-check.yaml"
    assert_eq '["read_file","glob","grep_search","run_shell_command(gh pr view)","run_shell_command(gh pr diff)","run_shell_command(git diff)","run_shell_command(git log)","run_shell_command(git show)"]' \
        "$(yq '.jobs.judge.steps[] | select(.id == "gemini") | .with.settings' "${wf}" | jq -c '.tools.core')"
}

test_docs_sync_status_does_not_name_a_model() {
    assert_eq "0" "$(grep -c 'Claude' "${workflows_dir}/reusable--docs-sync-check.yaml" || true)"
}

test_renovate_review_uses_gemini_on_vertex() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq "google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489" "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .uses' "${wf}")"
    assert_eq "gemini-3.8-flash" "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .with.gemini_model' "${wf}")"
    assert_eq "" "$(yq '.jobs.review.steps[] | select(.with.role-to-assume) | .name' "${wf}")"
}

test_renovate_review_allows_only_read_tools() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq '["read_file","glob","grep_search","web_fetch","run_shell_command(gh pr view)","run_shell_command(gh pr diff)","run_shell_command(gh api)","run_shell_command(git diff)","run_shell_command(git log)","run_shell_command(git show)","run_shell_command(helm repo add)","run_shell_command(helm repo update)","run_shell_command(helm pull)","run_shell_command(helm show)"]' \
        "$(yq '.jobs.review.steps[] | select(.id == "gemini") | .with.settings' "${wf}" | jq -c '.tools.core')"
}

test_gemini_steps_record_tool_calls() {
    local wf job
    for pair in "reusable--docs-sync-check.yaml:judge" "reusable--renovate-major-review.yaml:review"; do
        wf="${workflows_dir}/${pair%%:*}"
        job="${pair##*:}"
        assert_eq "true|local|.gemini/telemetry.log|true" "$(yq ".jobs.${job}.steps[] | select(.id == \"gemini\") | .env | [.GEMINI_TELEMETRY_ENABLED, .GEMINI_TELEMETRY_TARGET, .GEMINI_TELEMETRY_OUTFILE, .GEMINI_TELEMETRY_LOG_PROMPTS] | join(\"|\")" "${wf}")"
    done
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
