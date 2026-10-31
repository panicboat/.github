#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
value="${2:-}"

# The service name rule of deploy-actions' Entities::Service.name_format.
service_rule='[a-zA-Z0-9_-]+'

case "${mode}" in
    --tag)
        pattern="^(${service_rule})-v[0-9]+\.[0-9]+\.[0-9]+\$"
        expected='<service>-vX.Y.Z'
        ;;
    --branch)
        pattern="^release-please--branches--main--components--(${service_rule})\$"
        expected='release-please--branches--main--components--<service>'
        ;;
    *)
        echo "::error::usage: release-service.sh --tag <tag> | --branch <branch>" >&2
        exit 1
        ;;
esac

if [[ ! "${value}" =~ ${pattern} ]]; then
    shown="${value//$'\n'/ }"
    shown="${shown//$'\r'/ }"
    echo "::error::'${shown}' does not match ${expected}" >&2
    exit 1
fi

echo "${BASH_REMATCH[1]}"
