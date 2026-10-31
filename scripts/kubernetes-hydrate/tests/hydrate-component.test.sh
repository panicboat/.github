#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="${here}/.."
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; failures=$((failures + 1)); }
expect_contains() { if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1"; sed 's/^/# /' "$3"; fi; }
expect_failure() { if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1"; fi; }
expect_success() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; sed 's/^/# /' "$3"; fi; }
expect_file() { if [ "$(cat "$2")" = "$3" ]; then pass "$1"; else fail "$1"; sed 's/^/# /' "$2"; fi; }
expect_missing() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1"; fi; }

repo="${work}/repo"
live="${repo}/kubernetes/manifests/production/namespace-only/manifest.yaml"
mkdir -p "${repo}/aws/eks/production" "$(dirname "${live}")" "${repo}/kubernetes/components/namespace-only/production"
printf 'locals {\n  cluster_version = "1.33"\n}\n' > "${repo}/aws/eks/production/env.hcl"
printf 'kind: Namespace\n' > "${repo}/kubernetes/components/namespace-only/production/namespace.yaml"
printf 'kind: Deployment\n' > "${live}"
git -C "${repo}" init -q -b main
git -C "${repo}" -c user.name=test -c user.email=test@example.com add -A
git -C "${repo}" -c user.name=test -c user.email=test@example.com commit -q -m base

hydrate() {
    local status=0
    (cd "${repo}" && bash "${scripts}/hydrate-component.sh" "$@") > "${work}/stdout" 2>&1 || status=$?
    echo "${status}"
}

status="$(hydrate namespace-only production)"
expect_failure "a component with neither input fails" "${status}"
expect_contains "the failure names the directory" "kubernetes/components/namespace-only/production" "${work}/stdout"
expect_file "the failure keeps the existing manifest" "${live}" "kind: Deployment"

status="$(hydrate missing production)"
expect_failure "a component without a directory fails" "${status}"
expect_contains "the failure names the missing directory" "kubernetes/components/missing/production" "${work}/stdout"
expect_missing "the failure writes no manifest directory" "${repo}/kubernetes/manifests/production/missing"

bin="${work}/bin"
mkdir -p "${bin}"
printf '#!/usr/bin/env bash\necho "kind: HelmRendered"\n' > "${bin}/helmfile"
chmod +x "${bin}/helmfile"
mkdir -p "${repo}/kubernetes/components/chart/production"
touch "${repo}/kubernetes/components/chart/production/helmfile.yaml"
status="$(PATH="${bin}:${PATH}" hydrate chart production)"
expect_success "a component with helmfile.yaml hydrates" "${status}" "${work}/stdout"
expect_contains "the helmfile output reaches the manifest" "kind: HelmRendered" "${repo}/kubernetes/manifests/production/chart/manifest.yaml"

mkdir -p "${repo}/kubernetes/components/plain/production/kustomization"
printf 'resources:\n  - configmap.yaml\n' > "${repo}/kubernetes/components/plain/production/kustomization/kustomization.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: plain\n' > "${repo}/kubernetes/components/plain/production/kustomization/configmap.yaml"
status="$(hydrate plain production)"
expect_success "a component with kustomization/ hydrates" "${status}" "${work}/stdout"
expect_contains "the kustomize output reaches the manifest" "kind: ConfigMap" "${repo}/kubernetes/manifests/production/plain/manifest.yaml"

exit "${failures}"
