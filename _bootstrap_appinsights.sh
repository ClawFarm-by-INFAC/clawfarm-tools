#!/usr/bin/env bash
# _bootstrap_appinsights.sh — resolve APPLICATIONINSIGHTS_CONNECTION_STRING
# from Azure Key Vault for resource-bootstrap.sh (Flow B).
#
# Sourced by public/tools/resource-bootstrap.sh before write_env_file().
# Mirrors the logic in scripts/deploy/lib/resource-agent.sh:265-287 (Flow A,
# deleted in the Flow A retirement plan) with one improvement: emits a
# stderr warning when APPINSIGHTS_KV_SECRET_NAME is set AND az CLI is
# available BUT the secret fetch returns empty. That silent-failure mode
# in Flow A meant operators lost prod tracing on a transient Key Vault
# blip with no signal until Azure Monitor went dark during an incident
# (plan D9 acceptance case).
#
# Contract:
#   - Exits 0 in all branches. NEVER aborts the sourcing script.
#   - Prints the connection string to stdout (trailing newline omitted).
#     Empty output means "no App Insights; caller writes OTEL_SDK_DISABLED=true".
#   - Warnings go to stderr.
#
# Env vars honored:
#   APPINSIGHTS_KV_SECRET_NAME - secret name in Key Vault. Empty/unset → skip.
#   AZURE_KEY_VAULT_NAME       - explicit vault name. If unset, falls back to
#                                `keyvault_discovery_default` (defined in
#                                scripts/deploy/lib/azure-keyvault.sh, which
#                                is NOT sourced here — must be available in
#                                the calling shell if auto-discovery is needed).

resolve_appinsights() {
    local secret_name="${APPINSIGHTS_KV_SECRET_NAME:-}"
    if [[ -z "$secret_name" ]]; then
        # No request for App Insights — silent fallback to OTEL_SDK_DISABLED
        return 0
    fi

    if ! command -v az >/dev/null 2>&1; then
        echo "WARNING: APPINSIGHTS_KV_SECRET_NAME set but az CLI not available; skipping App Insights" >&2
        return 0
    fi

    local vault="${AZURE_KEY_VAULT_NAME:-}"
    if [[ -z "$vault" ]]; then
        vault=$(keyvault_discovery_default 2>/dev/null || true)
    fi
    if [[ -z "$vault" ]]; then
        echo "WARNING: APPINSIGHTS_KV_SECRET_NAME set but no Key Vault resolved; set AZURE_KEY_VAULT_NAME" >&2
        return 0
    fi

    local value
    value=$(az keyvault secret show --name "$secret_name" --vault-name "$vault" --query 'value' -o tsv 2>/dev/null) || true
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
    else
        # D9: emit warning instead of silent empty return. Operator sees that
        # prod tracing silently fell back to OTEL_SDK_DISABLED and can fix the
        # Key Vault issue before it bites during an incident.
        echo "WARNING: APPINSIGHTS_KV_SECRET_NAME set but secret lookup failed (vault=${vault}, secret=${secret_name})" >&2
        return 0
    fi
}

# emit_tracing_env_block — produce the env-file tracing line(s) for
# write_env_file. Returns one of two shapes via stdout:
#
#   APPLICATIONINSIGHTS_CONNECTION_STRING=<value>   (when Key Vault resolves)
#   OTEL_SDK_DISABLED=true                          (dev fallback)
#
# Caller appends the output to the env file verbatim.
emit_tracing_env_block() {
    local appinsights_cs
    appinsights_cs=$(resolve_appinsights)
    if [[ -n "$appinsights_cs" ]]; then
        echo "APPLICATIONINSIGHTS_CONNECTION_STRING=${appinsights_cs}"
    else
        echo "OTEL_SDK_DISABLED=true"
    fi
}
