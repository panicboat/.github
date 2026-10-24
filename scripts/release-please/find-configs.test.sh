#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_configs="${script_dir}/find-configs.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failed=0

check() {
  local name="$1" expected="$2" repo actual path
  shift 2
  repo="$(mktemp -d "${work}/repo.XXXXXX")"
  git -C "$repo" init -q
  for path in "$@"; do
    mkdir -p "${repo}/$(dirname "$path")"
    echo '{}' >"${repo}/${path}"
  done
  git -C "$repo" add -A
  actual="$(cd "$repo" && bash "$find_configs" 2>&1)"
  if [ "$actual" = "$expected" ]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    failed=1
  fi
}

test_finds_nested_configs() {
  check test_finds_nested_configs '["a","b/c"]' a/release-please-config.json b/c/release-please-config.json b/c/other.json
}

test_finds_root_config() {
  check test_finds_root_config '["."]' release-please-config.json
}

test_finds_none() {
  check test_finds_none '[]' a/other.json
}

test_finds_nested_configs
test_finds_root_config
test_finds_none

exit "$failed"
