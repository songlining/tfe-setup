#!/bin/bash
# Vault PKI Setup Script for TFE
# This script configures Vault with PKI secrets engines and CAs for TFE TLS certificates

set -e

CONTEXT="${KUBECTL_CONTEXT:-kind-tfe}"
NAMESPACE="vault"
VAULT_POD="vault-0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if vault is running
echo_info "Checking Vault status..."
if ! kubectl get pod $VAULT_POD -n $NAMESPACE --context $CONTEXT &>/dev/null; then
    echo_error "Vault pod not found. Please deploy Vault first."
    exit 1
fi

# Check if Vault is already initialized
VAULT_STATUS=$(kubectl exec -n $NAMESPACE $VAULT_POD --context $CONTEXT -- vault status -format=json 2>/dev/null || echo '{"initialized": false, "sealed": true}')
INITIALIZED=$(echo $VAULT_STATUS | jq -r '.initialized')
SEALED=$(echo $VAULT_STATUS | jq -r '.sealed')

if [ "$INITIALIZED" == "true" ]; then
    echo_warn "Vault is already initialized."
    if [ "$SEALED" == "true" ]; then
        echo_info "Vault is sealed. Please unseal it first."
        echo_info "Get unseal key from: kubectl get secret vault-keys -n $NAMESPACE -o jsonpath='{.data.unseal_key}' | base64 -d"
        exit 1
    fi
    # Get token from secret if exists
    if kubectl get secret vault-keys -n $NAMESPACE --context $CONTEXT &>/dev/null; then
        VAULT_TOKEN=$(kubectl get secret vault-keys -n $NAMESPACE --context $CONTEXT -o jsonpath='{.data.root_token}' | base64 -d)
        echo_info "Using existing root token from secret"
    else
        echo_error "Vault is initialized but vault-keys secret not found. Please provide VAULT_TOKEN."
        exit 1
    fi
else
    # Initialize Vault
    echo_info "Initializing Vault..."
    INIT_OUTPUT=$(kubectl exec -n $NAMESPACE $VAULT_POD --context $CONTEXT -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
    UNSEAL_KEY=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[0]')
    VAULT_TOKEN=$(echo $INIT_OUTPUT | jq -r '.root_token')

    # Unseal Vault
    echo_info "Unsealing Vault..."
    kubectl exec -n $NAMESPACE $VAULT_POD --context $CONTEXT -- vault operator unseal $UNSEAL_KEY

    # Save keys to secret
    echo_info "Saving keys to Kubernetes secret..."
    kubectl create secret generic vault-keys -n $NAMESPACE --context $CONTEXT \
        --from-literal=unseal_key=$UNSEAL_KEY \
        --from-literal=root_token=$VAULT_TOKEN \
        --dry-run=client -o yaml | kubectl apply -f - --context $CONTEXT

    echo_info "Vault initialized and unsealed successfully"
fi

export VAULT_TOKEN

# Function to run vault commands
vault_cmd() {
    kubectl exec -n $NAMESPACE $VAULT_POD --context $CONTEXT -- env VAULT_TOKEN=$VAULT_TOKEN vault "$@"
}

# Check if PKI engines are already enabled
echo_info "Checking PKI secrets engines..."
SECRETS_LIST=$(vault_cmd secrets list -format=json 2>/dev/null || echo '{}')

if echo $SECRETS_LIST | jq -e '.["pki/"]' &>/dev/null; then
    echo_warn "Root PKI engine already enabled"
else
    echo_info "Enabling root PKI secrets engine..."
    vault_cmd secrets enable pki
fi

vault_cmd secrets tune -max-lease-ttl=87600h pki 2>/dev/null || true

if echo $SECRETS_LIST | jq -e '.["pki_int/"]' &>/dev/null; then
    echo_warn "Intermediate PKI engine already enabled"
else
    echo_info "Enabling intermediate PKI secrets engine..."
    vault_cmd secrets enable -path=pki_int pki
fi

vault_cmd secrets tune -max-lease-ttl=43800h pki_int 2>/dev/null || true

# Check if root CA exists
ROOT_ISSUERS=$(vault_cmd read -format=json pki/issuers 2>/dev/null | jq -r '.data.keys // []' || echo '[]')
if [ "$ROOT_ISSUERS" == "[]" ] || [ "$ROOT_ISSUERS" == "null" ]; then
    echo_info "Generating Root CA..."
    vault_cmd write pki/root/generate/internal \
        common_name="TFE Root CA" \
        issuer_name="root-2024" \
        ttl=87600h \
        key_bits=4096

    echo_info "Configuring Root CA URLs..."
    vault_cmd write pki/config/urls \
        issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
        crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki/crl"
else
    echo_warn "Root CA already exists"
fi

# Check if intermediate CA exists
INT_ISSUERS=$(vault_cmd read -format=json pki_int/issuers 2>/dev/null | jq -r '.data.keys // []' || echo '[]')
if [ "$INT_ISSUERS" == "[]" ] || [ "$INT_ISSUERS" == "null" ]; then
    echo_info "Generating Intermediate CA CSR..."
    CSR=$(vault_cmd write -format=json pki_int/intermediate/generate/internal \
        common_name="TFE Intermediate CA" \
        issuer_name="intermediate-2024" \
        key_bits=4096 | jq -r '.data.csr')

    echo_info "Signing Intermediate CA with Root CA..."
    SIGNED_CERT=$(vault_cmd write -format=json pki/root/sign-intermediate \
        issuer_ref="root-2024" \
        csr="$CSR" \
        format=pem_bundle \
        ttl="43800h" | jq -r '.data.certificate')

    echo_info "Importing signed Intermediate CA..."
    vault_cmd write pki_int/intermediate/set-signed certificate="$SIGNED_CERT"

    echo_info "Configuring Intermediate CA URLs..."
    vault_cmd write pki_int/config/urls \
        issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki_int/ca" \
        crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki_int/crl"
else
    echo_warn "Intermediate CA already exists"
fi

# Create/update TFE certificate role
echo_info "Creating/updating TFE certificate role..."
vault_cmd write pki_int/roles/tfe-cert \
    allowed_domains="tfe.local,tfe.tfe.svc.cluster.local" \
    allow_bare_domains=true \
    allow_subdomains=true \
    allow_glob_domains=true \
    allow_ip_sans=true \
    max_ttl="720h" \
    key_bits=2048

echo_info "====================================="
echo_info "Vault PKI Setup Complete!"
echo_info "====================================="
echo_info ""
echo_info "Root CA: TFE Root CA (10 year validity)"
echo_info "Intermediate CA: TFE Intermediate CA (5 year validity)"
echo_info "Certificate Role: tfe-cert"
echo_info ""
echo_info "To issue a TFE certificate:"
echo_info "  vault write pki_int/issue/tfe-cert \\"
echo_info "    common_name=\"tfe.tfe.local\" \\"
echo_info "    alt_names=\"tfe.local,tfe.tfe.svc.cluster.local\" \\"
echo_info "    ip_sans=\"127.0.0.1\" \\"
echo_info "    ttl=\"72h\""
echo_info ""
echo_info "Vault UI: kubectl port-forward -n vault svc/vault-ui 8200:8200"
echo_info "Root Token: kubectl get secret vault-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d"
