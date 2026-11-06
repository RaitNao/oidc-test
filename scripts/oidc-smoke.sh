#!/usr/bin/env bash

# Never trace credential-bearing commands, even when invoked with bash -x.
set +x
set -eEuo pipefail

log() {
    printf '%s\n' "${*}" >&2
}

fatal() {
    log "ERROR: ${*}"
    exit 1
}

mask() {
    local value="${1}"
    value="${value//'%'/'%25'}"
    value="${value//$'\r'/'%0D'}"
    value="${value//$'\n'/'%0A'}"
    printf '::add-mask::%s\n' "${value}"
}

main() {
    local name oidc_token exchange_token audience_encoded image_ref
    for name in REGISTRY_ORG CONNECTION_ID CONNECTION_PARAMETER OIDC_AUDIENCE EXCHANGE_AUDIENCE STS_URL REGISTRY IMAGE TAG ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
    do
        [ -n "${!name:-}" ] || fatal "Missing ${name}"
    done
    [[ "${CONNECTION_PARAMETER}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || fatal 'CONNECTION_PARAMETER must be a form field name'
    [[ "${STS_URL}" == https://* ]] || fatal 'STS_URL must use HTTPS'
    [[ "${REGISTRY}" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || fatal 'REGISTRY must be a hostname with optional port'
    for name in curl jq docker
    do
        command -v "${name}" >/dev/null || fatal "Missing command: ${name}"
    done

    umask 077
    work_dir="$(mktemp -d)"
    trap 'rm -rf "${work_dir}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    # Isolate credentials from the runner's existing Docker configuration.
    export DOCKER_CONFIG="${work_dir}/docker"
    mkdir -p "${DOCKER_CONFIG}"

    log 'Requesting GitHub OIDC ID token'
    audience_encoded="$(jq -rn --arg audience "${OIDC_AUDIENCE}" '$audience | @uri')"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
        --header "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience_encoded}" \
        --output "${work_dir}/oidc.json"
    oidc_token="$(jq -er '.value | select(type == "string" and length > 0)' "${work_dir}/oidc.json" 2>/dev/null)" \
        || fatal 'GitHub returned no usable ID token'
    mask "${oidc_token}"
    printf '%s' "${oidc_token}" > "${work_dir}/subject-token"
    unset oidc_token

    log 'Exchanging ID token with STS'
    # No repository scope here: Docker negotiates that with the registry later.
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
        --request POST "${STS_URL%/}/oauth/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
        --data-urlencode "subject_token@${work_dir}/subject-token" \
        --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
        --data-urlencode "${CONNECTION_PARAMETER}=${CONNECTION_ID}" \
        --data-urlencode "audience=${EXCHANGE_AUDIENCE}" \
        --output "${work_dir}/exchange.json"
    exchange_token="$(jq -er '.access_token | select(type == "string" and length > 0)' "${work_dir}/exchange.json" 2>/dev/null)" \
        || fatal 'STS returned no usable access_token'
    mask "${exchange_token}"

    log "Logging in to ${REGISTRY}"
    printf '%s' "${exchange_token}" | docker login "${REGISTRY}" \
        --username '$oauthtoken' --password-stdin
    unset exchange_token

    image_ref="${REGISTRY}/${REGISTRY_ORG}/${IMAGE}:${TAG}"
    log "Fetching manifest for ${image_ref}"
    docker manifest inspect "${image_ref}" > manifest.json
    jq . manifest.json
    log 'Success: token exchange, Docker login, and manifest retrieval completed'
}

main
