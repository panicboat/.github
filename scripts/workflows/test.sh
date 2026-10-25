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

test_docs_sync_status_does_not_name_a_model() {
    assert_eq "1" "$(grep -c "state=pending; description='AI が判定しています'" "${workflows_dir}/reusable--docs-sync-check.yaml")"
}

test_review_jobs_fetch_the_pull_request_before_the_model() {
    local wf job
    for pair in "reusable--docs-sync-check.yaml:judge" "reusable--renovate-major-review.yaml:review"; do
        wf="${workflows_dir}/${pair%%:*}"
        job="${pair##*:}"
        assert_eq "fetch-pull-request claude" "$(yq ".jobs.${job}.steps[] | select(.id == \"fetch-pull-request\" or .id == \"claude\") | .id" "${wf}" | tr '\n' ' ' | sed 's/ $//')"
        yq ".jobs.${job}.steps[] | select(.id == \"fetch-pull-request\") | .run" "${wf}" | grep -q '.review-context/pull-request.json'
        yq ".jobs.${job}.steps[] | select(.id == \"fetch-pull-request\") | .run" "${wf}" | grep -q '.review-context/diff.patch'
    done
}

claude_step() {
    yq ".jobs.$2.steps[] | select(.id == \"claude\")" "${workflows_dir}/$1"
}

assert_claude_step_uses_wif() {
    local step="$1"
    assert_eq "anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13" "$(yq '.uses' <<<"${step}")"
    assert_eq "fdrl_01EFTG7Y8vWedXu5dyKHk9VP|3e6cc666-1654-4da0-9d46-3abb52bc7288|svac_01XpqeHTNpHPf7zZSQXgck3S|wrkspc_01Pn5wRk8fQ8vXGsUGzH66wv" \
        "$(yq '.with | [.anthropic_federation_rule_id, .anthropic_organization_id, .anthropic_service_account_id, .anthropic_workspace_id] | join("|")' <<<"${step}")"
    assert_eq "null" "$(yq '.with.anthropic_api_key' <<<"${step}")"
    assert_eq "null" "$(yq '.with.claude_code_oauth_token' <<<"${step}")"
    local args
    args="$(yq '.with.claude_args' <<<"${step}")"
    grep -q 'blockReadsOutsideWorkingDirectories' <<<"${args}"
    grep -qF 'Read(//home/runner/work/_temp/**)' <<<"${args}"
    grep -qF 'Read(./.git/**)' <<<"${args}"
}

test_docs_sync_judge_runs_claude_code_action() {
    local wf="${workflows_dir}/reusable--docs-sync-check.yaml" step args
    step="$(claude_step reusable--docs-sync-check.yaml judge)"
    assert_claude_step_uses_wif "${step}"
    args="$(yq '.with.claude_args' <<<"${step}")"
    grep -qF -- '--model claude-haiku-5-5' <<<"${args}"
    grep -qF -- '--max-budget-usd 0.5' <<<"${args}"
    ! grep -qF -- '--allowedTools' <<<"${args}"
    grep -qE -- '--disallowedTools "[^"]*Bash[,"]' <<<"${args}"
    assert_eq "" "$(yq '.jobs.judge.steps[] | select(.uses == "*run-gemini-cli*" or .uses == "*configure-aws-credentials*") | .name' "${wf}")"
}

test_renovate_review_runs_claude_code_action() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml" step args
    step="$(claude_step reusable--renovate-major-review.yaml review)"
    assert_claude_step_uses_wif "${step}"
    args="$(yq '.with.claude_args' <<<"${step}")"
    grep -qF -- '--model claude-sonnet-5-5' <<<"${args}"
    grep -qF -- '--max-budget-usd 5' <<<"${args}"
    grep -qF -- '--allowedTools "WebFetch,Bash(helm repo add:*),Bash(helm repo update:*),Bash(helm pull:*),Bash(helm show:*)"' <<<"${args}"
    assert_eq "" "$(yq '.jobs.review.steps[] | select(.uses == "*run-gemini-cli*" or .uses == "*configure-aws-credentials*") | .name' "${wf}")"
}

test_review_jobs_enable_only_the_listed_tools() {
    grep -qF -- '--tools "Read,Glob,Grep"' <<<"$(yq '.with.claude_args' <<<"$(claude_step reusable--docs-sync-check.yaml judge)")"
    grep -qF -- '--tools "Read,Glob,Grep,Bash,WebFetch"' <<<"$(yq '.with.claude_args' <<<"$(claude_step reusable--renovate-major-review.yaml review)")"
}

test_renovate_review_accepts_the_renovate_bot() {
    assert_eq "renovate" "$(yq '.with.allowed_bots' <<<"$(claude_step reusable--renovate-major-review.yaml review)")"
}

test_renovate_review_scrubs_secrets_from_bash() {
    local wf="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq "1" "$(yq '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' <<<"$(claude_step reusable--renovate-major-review.yaml review)")"
    assert_eq "install-bubblewrap claude" "$(yq '.jobs.review.steps[] | select(.id == "install-bubblewrap" or .id == "claude") | .id' "${wf}" | tr '\n' ' ' | sed 's/ $//')"
    yq '.jobs.review.steps[] | select(.id == "install-bubblewrap") | .run' "${wf}" | grep -q 'apt-get install -y --no-install-recommends bubblewrap'
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
