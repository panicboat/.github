#!/usr/bin/env bash
set -euo pipefail

service="${1:?usage: previous-release-tag.sh <service>}"

# Reads tags from the remote because the workflow checkout fetches no tags.
git ls-remote --tags --refs origin "refs/tags/${service}-v*" \
    | sed -n "s#^[0-9a-f]*[[:space:]]refs/tags/\(${service}-v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\$#\1#p" \
    | sort -V \
    | tail -n 1
