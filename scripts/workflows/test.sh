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

test_resolver_applies_only_non_production_targets() {
    local expected="\${{ matrix.target.type == 'terragrunt' && (github.event_name == 'pull_request' && 'plan' || (matrix.target.environment != 'production' && 'apply' || '')) || '' }}"
    local actual
    actual="$(yq '.jobs["deploy-terragrunt"].with["action-type"]' "${workflows_dir}/reusable--label-base-deploy--resolver.yaml")"
    assert_eq "${expected}" "${actual}"
}

test_resolver_routes_targets_by_type() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    local kind
    assert_eq "0" "$(grep -cF "contains(needs.resolve.outputs.targets, '\"stack\":" "${resolver}" || true)"
    assert_eq "0" "$(grep -cF 'matrix.target.stack_id' "${resolver}" || true)"
    for kind in terragrunt container kustomize helmfile; do
        grep -qF "contains(needs.resolve.outputs.targets, '\"type\":\"${kind}\"')" "${resolver}" || { echo "  missing type route: ${kind}" >&2; exit 1; }
    done
    yq '.jobs["helmfile-targets-group"].steps[] | select(.id == "group") | .run' "${resolver}" | grep -qF 'select(.type == "helmfile")'
}

test_resolver_groups_environments_with_orphaned_manifests() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    local job='.jobs["helmfile-targets-group"]'
    local run work repo targets
    assert_eq "needs.resolve.result == 'success'" "$(yq "${job}.if" "${resolver}")"
    assert_eq 'actions/checkout@*' "$(yq "${job}.steps[0].uses | sub(\"@.*\", \"@*\")" "${resolver}")"
    assert_eq 'null' "$(yq "${job}.steps[0].with.path" "${resolver}")"
    assert_eq '.shared-workflows' "$(yq "${job}.steps[1].with.path" "${resolver}")"
    assert_eq '${{ job.workflow_repository }}' "$(yq "${job}.steps[1].with.repository" "${resolver}")"
    assert_eq '${{ job.workflow_sha }}' "$(yq "${job}.steps[1].with.ref" "${resolver}")"
    run="$(yq "${job}.steps[] | select(.id == \"group\") | .run" "${resolver}")"
    assert_eq '${{ needs.resolve.outputs.targets }}' "$(yq "${job}.steps[] | select(.id == \"group\") | .env.TARGETS" "${resolver}")"
    assert_eq "0" "$(grep -c '\${{' <<<"${run}" || true)"

    work="$(mktemp -d)"
    trap "rm -rf '${work}'" EXIT
    group() {
        rm -f "${work}/output"
        (cd "$1" && GITHUB_OUTPUT="${work}/output" TARGETS="$2" bash -c "${run}")
        cat "${work}/output"
    }

    repo="${work}/no-manifests"
    mkdir -p "${repo}"
    git -C "${repo}" init -q
    ln -s "${repo_root}" "${repo}/.shared-workflows"
    assert_eq 'environments=[]' "$(group "${repo}" '')"
    assert_eq 'environments=[]' "$(group "${repo}" '[]')"
    targets='[{"service":"api","environment":"develop","type":"terragrunt"},{"service":"coredns","environment":"production","type":"helmfile"},{"service":"cilium","environment":"production","type":"helmfile"}]'
    assert_eq 'environments=[{"environment":"production","services":["coredns","cilium"]}]' "$(group "${repo}" "${targets}")"

    repo="${work}/orphans"
    mkdir -p "${repo}/kubernetes/manifests/production/gone" "${repo}/kubernetes/manifests/develop/gone"
    git -C "${repo}" init -q
    ln -s "${repo_root}" "${repo}/.shared-workflows"
    assert_eq 'environments=[{"environment":"develop","services":[]},{"environment":"production","services":[]}]' "$(group "${repo}" '')"
    assert_eq 'environments=[{"environment":"develop","services":[]},{"environment":"production","services":["coredns","cilium"]}]' "$(group "${repo}" "${targets}")"
}

test_resolver_hydrates_only_listed_environments() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    assert_eq "needs.helmfile-targets-group.outputs.environments != '[]'" "$(yq '.jobs["deploy-helmfile-hydrate"].if' "${resolver}")"
    assert_eq '${{ fromJson(needs.helmfile-targets-group.outputs.environments) }}' "$(yq '.jobs["deploy-helmfile-hydrate"].strategy.matrix.env' "${resolver}")"
    assert_eq '${{ toJson(matrix.env.services) }}' "$(yq '.jobs["deploy-helmfile-hydrate"].with.services' "${resolver}")"
}

test_resolver_diffs_helmfile_only_for_helmfile_targets() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    local expected
    expected="$(printf '%s\n' "github.event_name == 'pull_request' &&" "needs.resolve.outputs.has-targets == 'true' &&" "contains(needs.resolve.outputs.targets, '\"type\":\"helmfile\"')")"
    assert_eq "${expected}" "$(yq '.jobs["deploy-helmfile"].if' "${resolver}" | sed '/^$/d')"
    assert_eq 'resolve deploy-helmfile-hydrate' "$(yq '.jobs["deploy-helmfile"].needs | join(" ")' "${resolver}")"
}

test_resolver_summarizes_only_runs_with_targets() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    assert_eq "always() && needs.resolve.outputs.has-targets == 'true'" "$(yq '.jobs["deployment-summary"].if' "${resolver}")"
    assert_eq 'resolve deploy-terragrunt deploy-container deploy-kustomize deploy-helmfile-hydrate deploy-helmfile' "$(yq '.jobs["deployment-summary"].needs | join(" ")' "${resolver}")"
}

test_label_base_deploy_pins_both_actions_to_one_deploy_actions_commit() {
    local pin_pattern='^panicboat/deploy-actions/label-[a-z]+@([0-9a-f]{40}) # (v[0-9]+\.[0-9]+\.[0-9]+)$'
    local name line pins=""
    for name in dispatcher resolver; do
        line="$(grep -o "panicboat/deploy-actions/label-${name}@.*" "${workflows_dir}/reusable--label-base-deploy--${name}.yaml")"
        [[ "${line}" =~ ${pin_pattern} ]] || { echo "  unpinned: ${line}" >&2; exit 1; }
        pins+="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"$'\n'
    done
    assert_eq "1" "$(sort -u <<<"${pins}" | grep -c .)"
}

test_resolver_skips_label_resolver_without_a_pull_request() {
    local workflow="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    assert_eq "steps.pr-info.outputs.number != ''" "$(yq '.jobs.resolve.steps[] | select(.id == "resolver") | .if' "${workflow}")"
    assert_eq "needs.resolve.outputs.has-targets == 'true' &&" "$(yq '.jobs["deploy-terragrunt"].if' "${workflow}" | head -n 1)"
}

test_workflows_do_not_read_apply_trigger() {
    assert_eq "" "$(grep -rl --exclude='*test.sh' 'apply_trigger\|validate-apply-trigger' "${workflows_dir}" "${repo_root}/scripts" || true)"
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

test_release_workflows_resolve_with_the_label_resolver() {
    local pin_pattern='^panicboat/deploy-actions/label-resolver@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$'
    local steps='.jobs.resolve.steps[]'
    local targets='[{"service":"monolith","environment":"production","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/production","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"p","iam_role_apply":"a"},{"service":"monolith","environment":"production","stack":"kubernetes","working_directory":"dystopia/monolith/kubernetes/overlays/production","type":"kustomize"},{"service":"monolith","environment":"develop","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/develop","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"p","iam_role_apply":"a"},{"service":"monolith","environment":"develop","stack":"kubernetes","working_directory":"dystopia/monolith/kubernetes/overlays/develop","type":"kustomize"},{"service":"monolith","stack":"container","working_directory":"dystopia/monolith","type":"container"}]'
    local terragrunt_targets='[{"service":"monolith","environment":"production","stack":"terragrunt","working_directory":"dystopia/monolith/infrastructure/aws/production","type":"terragrunt","aws_region":"ap-northeast-1","iam_role_plan":"p","iam_role_apply":"a"}]'
    local kustomizations='[{"service":"monolith","environment":"production","kustomization_directory":"dystopia/monolith/kubernetes/overlays/production"}]'
    local name workflow pin step run work
    work="$(mktemp -d)"
    trap "rm -rf '${work}'" EXIT
    git init -q --bare "${work}/origin.git"
    git init -q "${work}/plan"
    git -C "${work}/plan" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    git -C "${work}/plan" tag monolith-v1.2.3
    git -C "${work}/plan" remote add origin "${work}/origin.git"
    git -C "${work}/plan" push -q origin --tags
    mkdir "${work}/deploy"
    for name in plan deploy; do
        workflow="${workflows_dir}/reusable--release--${name}.yaml"
        pin="$(grep -o 'panicboat/deploy-actions/label-resolver@.*' "${workflow}")"
        [[ "${pin}" =~ ${pin_pattern} ]] || { echo "  unpinned: ${pin}" >&2; exit 1; }
        assert_eq "$(grep -o 'panicboat/deploy-actions/label-resolver@.*' "${workflows_dir}/reusable--label-base-deploy--resolver.yaml")" "${pin}"
        ln -s "${repo_root}" "${work}/${name}/.shared-workflows"

        step="$(yq "${steps} | select(.id == \"resolver\")" "${workflow}")"
        assert_eq '${{ github.repository }}' "$(yq '.with.repository' <<<"${step}")"
        assert_eq '${{ steps.service.outputs.service }}' "$(yq '.with.service' <<<"${step}")"
        assert_eq 'null' "$(yq '.with.environments' <<<"${step}")"

        step="$(yq "${steps} | select(.id == \"service\")" "${workflow}")"
        run="$(yq '.run' <<<"${step}")"
        assert_eq "0" "$(grep -c '\${{' <<<"${run}" || true)"
        if [ "${name}" = plan ]; then
            (cd "${work}/plan" && GITHUB_OUTPUT="${work}/plan-service" HEAD_REF=release-please--branches--main--components--monolith bash -c "${run}")
            assert_eq "service=monolith" "$(cat "${work}/plan-service")"
        else
            (cd "${work}/deploy" && GITHUB_OUTPUT="${work}/deploy-service" TAG=monolith-v1.2.3 bash -c "${run}")
            assert_eq "service=monolith" "$(cat "${work}/deploy-service")"
        fi

        step="$(yq "${steps} | select(.id == \"resolve\")" "${workflow}")"
        run="$(yq '.run' <<<"${step}")"
        assert_eq '${{ steps.resolver.outputs.targets }}' "$(yq '.env.TARGETS' <<<"${step}")"
        assert_eq "0" "$(grep -c '\${{' <<<"${run}" || true)"
        if [ "${name}" = plan ]; then
            assert_eq '${{ steps.service.outputs.service }}' "$(yq '.env.SERVICE' <<<"${step}")"
            (cd "${work}/plan" && GITHUB_OUTPUT="${work}/plan-resolve" SERVICE=monolith TARGETS="${targets}" bash -c "${run}")
            assert_eq "$(printf 'targets=%s\nkustomizations=%s\nprevious-tag=monolith-v1.2.3' "${terragrunt_targets}" "${kustomizations}")" "$(cat "${work}/plan-resolve")"
        else
            (cd "${work}/deploy" && GITHUB_OUTPUT="${work}/deploy-resolve" TAG=monolith-v1.2.3 TARGETS="${targets}" bash -c "${run}")
            assert_eq "$(printf 'targets=%s\ntag=monolith-v1.2.3' "${terragrunt_targets}")" "$(cat "${work}/deploy-resolve")"
        fi
    done

    assert_eq 'null' "$(yq "${steps} | select(.id == \"resolver\") | .with.ref" "${workflows_dir}/reusable--release--plan.yaml")"
    assert_eq '${{ env.TAG }}' "$(yq "${steps} | select(.id == \"resolver\") | .with.ref" "${workflows_dir}/reusable--release--deploy.yaml")"
    assert_eq "1" "$(yq "[${steps} | select(.uses == \"actions/checkout@*\" and .with.path == null)] | length" "${workflows_dir}/reusable--release--plan.yaml")"
    assert_eq "0" "$(yq "[${steps} | select(.uses == \"actions/checkout@*\" and .with.path == null)] | length" "${workflows_dir}/reusable--release--deploy.yaml")"
}

test_release_build_tags_the_release_tag() {
    local build="${workflows_dir}/reusable--release--build.yaml"
    local builder="${workflows_dir}/internal--image-builder.yaml"
    assert_eq '${{ needs.detect-component.outputs.tag }}' "$(yq '.jobs["container-build"].with["release-tag"]' "${build}")"
    assert_eq '${{ steps.parse.outputs.tag }}' "$(yq '.jobs["detect-component"].outputs.tag' "${build}")"
    assert_eq "" "$(yq '.on.workflow_call.inputs["release-tag"].default' "${builder}")"
    grep -qF "type=raw,value=\${{ inputs.release-tag }},enable=\${{ inputs.release-tag != '' }}" "${builder}"
}

test_release_build_checks_out_the_release_tag() {
    local build="${workflows_dir}/reusable--release--build.yaml"
    local builder="${workflows_dir}/internal--image-builder.yaml"
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    assert_eq 'false' "$(yq '.on.workflow_call.inputs.ref.required' "${builder}")"
    assert_eq 'string' "$(yq '.on.workflow_call.inputs.ref.type' "${builder}")"
    assert_eq "" "$(yq '.on.workflow_call.inputs.ref.default' "${builder}")"
    assert_eq '${{ inputs.ref }}' "$(yq '.jobs["build-and-push"].steps[] | select(.name == "Checkout repository") | .with.ref' "${builder}")"
    assert_eq '${{ needs.detect-component.outputs.tag }}' "$(yq '.jobs["container-build"].with.ref' "${build}")"
    assert_eq 'null' "$(yq '.jobs["deploy-container"].with.ref' "${resolver}")"
}

test_image_builder_moves_latest_only_without_a_ref() {
    local builder="${workflows_dir}/internal--image-builder.yaml"
    local tags
    tags="$(yq '.jobs["build-and-push"].steps[] | select(.id == "meta") | .with.tags' "${builder}")"
    grep -qxF "type=raw,value=latest,enable=\${{ inputs.ref == '' && '{{is_default_branch}}' || 'false' }}" <<<"${tags}"
    grep -qxF 'type=sha' <<<"${tags}"
    grep -qxF 'type=raw,value=${{ github.actor }}' <<<"${tags}"
}

test_release_build_parses_tags_with_the_release_service_script() {
    local build="${workflows_dir}/reusable--release--build.yaml"
    local job='.jobs["detect-component"]'
    local step run work status out spec tag service version
    assert_eq '.shared-workflows' "$(yq "${job}.steps[0].with.path" "${build}")"
    assert_eq '${{ job.workflow_repository }}' "$(yq "${job}.steps[0].with.repository" "${build}")"
    assert_eq '${{ job.workflow_sha }}' "$(yq "${job}.steps[0].with.ref" "${build}")"
    step="$(yq "${job}.steps[] | select(.id == \"parse\")" "${build}")"
    run="$(yq '.run' <<<"${step}")"
    assert_eq "0" "$(grep -c '\${{' <<<"${run}" || true)"
    assert_eq "0" "$(grep -c '=~' <<<"${run}" || true)"
    assert_eq '${{ steps.parse.outputs.version }}' "$(yq "${job}.outputs.version" "${build}")"
    assert_eq '${{ needs.detect-component.outputs.version }}' "$(yq '.jobs["container-build"].with["semver-tag"]' "${build}")"

    work="$(mktemp -d)"
    trap "rm -rf '${work}'" EXIT
    ln -s "${repo_root}" "${work}/.shared-workflows"
    for spec in monolith:v0.9.0 github-oidc-auth:v1.2.3 route53:v1.0.0 oauth2-proxy:v10.20.30 my_Service2:v1.0.0 api-v2:v3.0.0; do
        service="${spec%%:*}"
        version="${spec##*:}"
        tag="${service}-${version}"
        rm -f "${work}/output"
        (cd "${work}" && GITHUB_OUTPUT="${work}/output" TAG="${tag}" bash -c "${run}")
        assert_eq "$(printf 'service=%s\nversion=%s\ntag=%s' "${service}" "${version}" "${tag}")" "$(cat "${work}/output")"
    done

    for tag in v1.0.0 monolith kubernetes-production a.b-v1.0.0 monolith-v1.2 ''; do
        rm -f "${work}/output"
        status=0
        out="$(cd "${work}" && GITHUB_OUTPUT="${work}/output" TAG="${tag}" bash -c "${run}" 2>&1)" || status=$?
        assert_eq "1" "${status}"
        [[ "${out}" == *"::error::"* ]] || { echo "  no error annotation: ${out}" >&2; exit 1; }
        [ ! -e "${work}/output" ]
    done
}

test_release_build_resolves_the_container_directory_with_the_label_resolver() {
    local build="${workflows_dir}/reusable--release--build.yaml"
    local pin_pattern='^panicboat/deploy-actions/label-resolver@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$'
    local job='.jobs["detect-component"]'
    local pin step run work status out targets
    pin="$(grep -o 'panicboat/deploy-actions/label-resolver@.*' "${build}")"
    [[ "${pin}" =~ ${pin_pattern} ]] || { echo "  unpinned: ${pin}" >&2; exit 1; }
    assert_eq "$(grep -o 'panicboat/deploy-actions/label-resolver@.*' "${workflows_dir}/reusable--label-base-deploy--resolver.yaml")" "${pin}"
    step="$(yq "${job}.steps[] | select(.id == \"resolver\")" "${build}")"
    assert_eq '${{ steps.parse.outputs.service }}' "$(yq '.with.service' <<<"${step}")"
    assert_eq '${{ steps.parse.outputs.tag }}' "$(yq '.with.ref' <<<"${step}")"
    assert_eq '${{ github.repository }}' "$(yq '.with.repository' <<<"${step}")"
    assert_eq 'null' "$(yq '.with.environments' <<<"${step}")"
    assert_eq "0" "$(yq "[${job}.steps[] | select(.uses == \"actions/checkout@*\" and .with.path == null)] | length" "${build}")"
    assert_eq "1" "$(yq "[${job}.steps[] | select(.uses == \"actions/checkout@*\")] | length" "${build}")"

    step="$(yq "${job}.steps[] | select(.id == \"resolve-dir\")" "${build}")"
    run="$(yq '.run' <<<"${step}")"
    assert_eq '${{ steps.resolver.outputs.targets }}' "$(yq '.env.TARGETS' <<<"${step}")"
    assert_eq "0" "$(grep -c '\${{' <<<"${run}" || true)"
    assert_eq "0" "$(grep -cw 'yq' <<<"${run}" || true)"
    assert_eq "0" "$(grep -v '::error::' <<<"${run}" | grep -c 'workflow-config.yaml' || true)"
    grep -qF 'select(.type == "container")' <<<"${run}"

    work="$(mktemp -d)"
    trap "rm -rf '${work}'" EXIT
    targets='[{"service":"api","environment":"develop","stack":"terragrunt","working_directory":"terragrunt/api/develop","type":"terragrunt"},{"service":"api","stack":"container","working_directory":"services/api","type":"container"}]'
    GITHUB_OUTPUT="${work}/output" SERVICE=api TARGETS="${targets}" bash -c "${run}"
    assert_eq "working-directory=services/api" "$(cat "${work}/output")"
    for targets in '[{"service":"billing","environment":"develop","stack":"terragrunt","working_directory":"terragrunt/billing/develop","type":"terragrunt"}]' '[]'; do
        status=0
        out="$(GITHUB_OUTPUT="${work}/none" SERVICE=billing TARGETS="${targets}" bash -c "${run}")" || status=$?
        assert_eq "1" "${status}"
        assert_eq "::error::No directory found for service 'billing' among the container targets of workflow-config.yaml" "${out}"
        [ ! -e "${work}/none" ]
    done
}

test_kustomize_builder_checks_out_head_ref_only_for_helmfile() {
    local resolver="${workflows_dir}/reusable--label-base-deploy--resolver.yaml"
    local kustomize_builder="${workflows_dir}/internal--kustomize-builder.yaml"
    assert_eq '${{ github.head_ref }}' "$(yq '.jobs["deploy-helmfile"].with.ref' "${resolver}")"
    assert_eq 'null' "$(yq '.jobs["deploy-kustomize"].with.ref' "${resolver}")"
    assert_eq '${{ inputs.ref }}' "$(yq '.jobs["kustomize-diff"].steps[] | select(.name == "Checkout") | .with.ref' "${kustomize_builder}")"
}

test_kustomize_builder_diffs_against_the_base_ref_when_given() {
    local kustomize_builder="${workflows_dir}/internal--kustomize-builder.yaml"
    assert_eq "" "$(yq '.on.workflow_call.inputs["base-ref"].default' "${kustomize_builder}")"
    assert_eq '${{ inputs.base-ref || github.event.pull_request.base.sha }}' "$(yq '.jobs["kustomize-diff"].steps[] | select(.name == "Checkout base ref") | .with.ref' "${kustomize_builder}")"
}

test_release_plan_diffs_kustomizations_against_the_previous_release() {
    local plan="${workflows_dir}/reusable--release--plan.yaml"
    assert_eq "needs.resolve.outputs.kustomizations != '[]' && needs.resolve.outputs.previous-tag != ''" "$(yq '.jobs["kustomize-diff"].if' "${plan}")"
    assert_eq '$/.github/workflows/internal--kustomize-builder.yaml' "$(yq '.jobs["kustomize-diff"].uses' "${plan}")"
    assert_eq '${{ needs.resolve.outputs.previous-tag }}' "$(yq '.jobs["kustomize-diff"].with["base-ref"]' "${plan}")"
    assert_eq '${{ matrix.kustomization.kustomization_directory }}' "$(yq '.jobs["kustomize-diff"].with["kustomization-directory"]' "${plan}")"
    assert_eq '${{ steps.resolve.outputs.kustomizations }}' "$(yq '.jobs.resolve.outputs.kustomizations' "${plan}")"
    assert_eq '${{ steps.resolve.outputs.previous-tag }}' "$(yq '.jobs.resolve.outputs["previous-tag"]' "${plan}")"
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

claude_workflow="${workflows_dir}/internal--claude-code-action.yaml"

claude_job_step() {
    yq ".jobs.claude.steps[] | select(.id == \"$1\")" "${claude_workflow}"
}

sorted_json() {
    yq -o=json -I=0 'to_entries | sort_by(.key) | from_entries'
}

test_claude_job_runs_in_the_claude_code_action_environment() {
    assert_eq "claude-code-action" "$(yq '.jobs.claude.environment' "${claude_workflow}")"
    assert_eq '{"contents":"read","id-token":"write","pull-requests":"read"}' "$(yq '.jobs.claude.permissions' "${claude_workflow}" | sorted_json)"
}

test_claude_job_orders_its_steps() {
    assert_eq "fetch-pull-request aws-secrets token claude fallback aws-bedrock claude-bedrock check" \
        "$(yq '.jobs.claude.steps[] | select(.id != null) | .id | select(test("^(fetch-pull-request|aws-secrets|token|claude|fallback|aws-bedrock|claude-bedrock|check)$"))' "${claude_workflow}" | tr '\n' ' ' | sed 's/ $//')"
    claude_job_step fetch-pull-request | yq '.run' | grep -q '.review-context/pull-request.json'
    claude_job_step fetch-pull-request | yq '.run' | grep -q '.review-context/diff.patch'
}

test_claude_step_uses_the_subscription_token() {
    local step
    step="$(claude_job_step claude)"
    assert_eq "anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13" "$(yq '.uses' <<<"${step}")"
    assert_eq '${{ steps.token.outputs.token }}' "$(yq '.with.claude_code_oauth_token' <<<"${step}")"
    assert_eq "null" "$(yq '.with.anthropic_api_key' <<<"${step}")"
    assert_eq "null" "$(yq '.with.anthropic_federation_rule_id' <<<"${step}")"
    yq '.if' <<<"${step}" | grep -qF "steps.token.outcome == 'success'"
    assert_eq "null" "$(yq '.env.AWS_ACCESS_KEY_ID' <<<"${step}")"
}

test_claude_steps_keep_the_permission_settings() {
    local id args
    for id in claude claude-bedrock; do
        args="$(claude_job_step "${id}" | yq '.with.claude_args')"
        grep -q 'blockReadsOutsideWorkingDirectories' <<<"${args}"
        grep -qF -- '--tools "${{ inputs.tools }}"' <<<"${args}"
        grep -qF -- '--max-budget-usd ${{ inputs.max-budget-usd }}' <<<"${args}"
        grep -qF -- '--disallowedTools "Write,Edit,NotebookEdit,Agent,WebSearch,Read(//home/runner/work/_temp/**),Read(./.git/**)' <<<"${args}"
        grep -qF 'inputs.extra-disallowed-tools' <<<"${args}"
        grep -qF 'inputs.allowed-tools' <<<"${args}"
        grep -qF -- "--json-schema '\${{ steps.schema.outputs.json }}'" <<<"${args}"
        assert_eq '${{ inputs.allowed-bots }}' "$(claude_job_step "${id}" | yq '.with.allowed_bots')"
        assert_eq '${{ github.token }}' "$(claude_job_step "${id}" | yq '.with.github_token')"
    done
}

test_schema_step_selects_the_output_kind() {
    local run
    run="$(claude_job_step schema | yq '.run')"
    grep -qF '{"type":"object","properties":{"passed":{"type":"boolean"},"body":{"type":"string","minLength":1,"maxLength":60000}},"required":["passed","body"]}' <<<"${run}"
    grep -qF '{"type":"object","properties":{"body":{"type":"string","minLength":1,"maxLength":60000}},"required":["body"]}' <<<"${run}"
}

test_bedrock_step_runs_only_on_fallback() {
    local step
    step="$(claude_job_step claude-bedrock)"
    yq '.if' <<<"${step}" | grep -qF "steps.fallback.outputs.fallback == 'true'"
    claude_job_step aws-bedrock | yq '.if' | grep -qF "steps.fallback.outputs.fallback == 'true'"
    assert_eq "true" "$(yq '.with.use_bedrock' <<<"${step}")"
    yq '.with.claude_args' <<<"${step}" | grep -qF -- '--model ${{ inputs.bedrock-model }}'
    claude_job_step claude | yq '.with.claude_args' | grep -qF -- '--model ${{ inputs.model }}'
    assert_eq "global.anthropic.claude-haiku-4-5-20251001-v1:0" "$(yq '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL' <<<"${step}")"
    assert_eq "us-east-1" "$(yq '.env.AWS_REGION' <<<"${step}")"
    assert_eq '${{ steps.aws-bedrock.outputs.aws-access-key-id }}' "$(yq '.env.AWS_ACCESS_KEY_ID' <<<"${step}")"
}

test_aws_credentials_stay_out_of_the_job_env() {
    local id step
    assert_eq "aws-secrets aws-bedrock" "$(yq '.jobs.claude.steps[] | select(.uses == "aws-actions/configure-aws-credentials@*") | .id' "${claude_workflow}" | tr '\n' ' ' | sed 's/ $//')"
    for id in aws-secrets aws-bedrock; do
        step="$(claude_job_step "${id}")"
        assert_eq "aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd" "$(yq '.uses' <<<"${step}")"
        assert_eq "arn:aws:iam::559744160976:role/github-oidc-auth-master-github-actions-claude-code-role" "$(yq '.with.role-to-assume' <<<"${step}")"
        assert_eq "false true" "$(yq '[.with.output-env-credentials, .with.output-credentials] | join(" ")' <<<"${step}")"
    done
    assert_eq '["secretsmanager:GetSecretValue"]' "$(claude_job_step aws-secrets | yq '.with.inline-session-policy' | jq -c '[.Statement[].Action] | flatten | unique')"
    assert_eq '["arn:aws:secretsmanager:ap-northeast-1:559744160976:secret:github-actions/claude-code/oauth-token-*"]' "$(claude_job_step aws-secrets | yq '.with.inline-session-policy' | jq -c '[.Statement[].Resource] | flatten | unique')"
    assert_eq '["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"]' "$(claude_job_step aws-bedrock | yq '.with.inline-session-policy' | jq -c '[.Statement[].Action] | flatten | unique')"
}

test_token_stays_out_of_the_env() {
    local step
    step="$(claude_job_step token)"
    assert_eq "true" "$(yq '.continue-on-error' <<<"${step}")"
    yq '.run' <<<"${step}" | grep -qF '::add-mask::'
    ! yq '.run' <<<"${step}" | grep -qF 'GITHUB_ENV'
    yq '.run' <<<"${step}" | grep -qF -- '--secret-id github-actions/claude-code/oauth-token '
    yq '.run' <<<"${step}" | grep -qF ".CLAUDE_CODE_OAUTH_TOKEN // empty"
    assert_eq '${{ steps.aws-secrets.outputs.aws-access-key-id }}' "$(yq '.env.AWS_ACCESS_KEY_ID' <<<"${step}")"
    ! grep -qF 'GITHUB_ENV' "${claude_workflow}"
}

test_claude_job_scrubs_secrets_when_bash_is_enabled() {
    local id
    assert_eq "\${{ contains(inputs.tools, 'Bash') }}" "$(claude_job_step install-bubblewrap | yq '.if')"
    claude_job_step install-bubblewrap | yq '.run' | grep -q 'apt-get install -y --no-install-recommends bubblewrap'
    for id in claude claude-bedrock; do
        assert_eq "\${{ contains(inputs.tools, 'Bash') && '1' || '' }}" "$(claude_job_step "${id}" | yq '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB')"
    done
}

test_check_step_marks_a_bedrock_run() {
    local run
    run="$(claude_job_step check | yq '.run')"
    grep -qF '> ⚠️ subscription で動かせなかったため、Bedrock（`' <<<"${run}"
    grep -qF 'check.sh' <<<"${run}"
}

test_fallback_step_warns_before_the_bedrock_run() {
    claude_job_step fallback | yq '.run' | grep -qF '::warning::'
    claude_job_step fallback | yq '.run' | grep -qF 'GITHUB_STEP_SUMMARY'
}

test_check_step_fails_without_an_output() {
    local run
    run="$(claude_job_step check | yq '.run')"
    grep -qE '^else$' <<<"${run}"
    grep -qF '::error::' <<<"${run}"
    tail -n 3 <<<"${run}" | grep -qF 'exit 1'
}

test_review_jobs_call_the_claude_job() {
    local docs_sync renovate
    docs_sync="${workflows_dir}/reusable--docs-sync-check.yaml"
    renovate="${workflows_dir}/reusable--renovate-major-review.yaml"
    assert_eq '$/.github/workflows/internal--claude-code-action.yaml' "$(yq '.jobs.judge.uses' "${docs_sync}")"
    assert_eq '$/.github/workflows/internal--claude-code-action.yaml' "$(yq '.jobs.review.uses' "${renovate}")"
    assert_eq '{"bedrock-model":"global.anthropic.claude-haiku-4-5-20251001-v1:0","checkout-ref":"${{ github.event.pull_request.head.sha }}","execution-log-name":"docs-sync-check-execution","extra-disallowed-tools":"Bash,WebFetch","max-budget-usd":"0.5","model":"claude-haiku-5-5","output-kind":"docs-sync","prompt-path":"${{ inputs.prompt-path }}","tools":"Read,Glob,Grep"}' \
        "$(yq '.jobs.judge.with' "${docs_sync}" | sorted_json)"
    assert_eq '{"allowed-bots":"renovate","allowed-tools":"WebFetch,Bash(helm repo add:*),Bash(helm repo update:*),Bash(helm pull:*),Bash(helm show:*)","bedrock-model":"global.anthropic.claude-sonnet-4-6","download-artifact-name":"render-diff","download-artifact-path":".render-diff","execution-log-name":"renovate-major-review-execution","max-budget-usd":"5","model":"claude-sonnet-5-5","output-kind":"review","prompt-path":"${{ inputs.prompt-path }}","setup-aqua":true,"tools":"Read,Glob,Grep,Bash,WebFetch"}' \
        "$(yq '.jobs.review.with' "${renovate}" | sorted_json)"
    assert_eq '{"contents":"read","id-token":"write","pull-requests":"read"}' "$(yq '.jobs.judge.permissions' "${docs_sync}" | sorted_json)"
    assert_eq '{"contents":"read","id-token":"write","pull-requests":"read"}' "$(yq '.jobs.review.permissions' "${renovate}" | sorted_json)"
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
