#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="${here}/.."
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; failures=$((failures + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; echo "# expected: $2"; echo "# actual:   $3"; fi; }

new_repo() {
    local repo="${work}/$1"
    mkdir -p "${repo}"
    git -C "${repo}" init -q -b main
    echo "${repo}"
}

add_dirs() {
    local repo="$1" dir
    shift
    for dir in "$@"; do
        mkdir -p "${repo}/kubernetes/${dir}"
        touch "${repo}/kubernetes/${dir}/file.yaml"
    done
}

orphans() {
    (cd "$1" && bash "${scripts}/orphan-environments.sh")
}

repo="$(new_repo no-kubernetes)"
expect_eq "a repository without kubernetes/manifests yields an empty list" "[]" "$(orphans "${repo}")"

repo="$(new_repo components-only)"
add_dirs "${repo}" components/app/production
expect_eq "components without manifests yield an empty list" "[]" "$(orphans "${repo}")"

repo="$(new_repo clean)"
add_dirs "${repo}" components/app/production manifests/production/app manifests/production/00-namespaces
expect_eq "matching manifests yield an empty list" "[]" "$(orphans "${repo}")"

repo="$(new_repo namespaces-only)"
add_dirs "${repo}" manifests/production/00-namespaces
expect_eq "00-namespaces is not an orphan" "[]" "$(orphans "${repo}")"

repo="$(new_repo file-in-environment)"
add_dirs "${repo}" components/app/production manifests/production/app
touch "${repo}/kubernetes/manifests/production/kustomization.yaml"
expect_eq "a file in the environment directory is not an orphan" "[]" "$(orphans "${repo}")"

repo="$(new_repo one-orphan)"
add_dirs "${repo}" components/app/production manifests/production/app manifests/production/gone
expect_eq "a manifest without a component is an orphan" '["production"]' "$(orphans "${repo}")"

repo="$(new_repo several-orphans)"
add_dirs "${repo}" manifests/production/a manifests/production/b manifests/develop/a manifests/staging/00-namespaces
expect_eq "each environment with an orphan appears once" '["develop","production"]' "$(orphans "${repo}")"

repo="$(new_repo other-environment)"
add_dirs "${repo}" components/app/develop manifests/production/app
expect_eq "a component in another environment does not cover the manifest" '["production"]' "$(orphans "${repo}")"

expect_eq "the result does not depend on the working directory" '["production"]' "$(mkdir -p "${repo}/nested" && cd "${repo}/nested" && bash "${scripts}/orphan-environments.sh")"

repo="$(new_repo matches-hydrate-index)"
add_dirs "${repo}" components/app/production manifests/production/app manifests/production/gone components/app/develop manifests/develop/app
(cd "${repo}" && bash "${scripts}/hydrate-index.sh" production)
if [ -d "${repo}/kubernetes/manifests/production/gone" ]; then fail "hydrate-index removes the reported orphan"; else pass "hydrate-index removes the reported orphan"; fi
expect_eq "hydrate-index leaves no orphan to report" "[]" "$(orphans "${repo}")"

exit "${failures}"
