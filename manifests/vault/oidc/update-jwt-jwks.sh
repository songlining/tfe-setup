#!/bin/bash
# Update Vault JWT Configuration with JWKS URL
# This script should be run AFTER TFE is deployed and running

set -e

# Context and namespace settings
CONTEXT="${CONTEXT:-kind-tfe}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
AUTH_PATH="${AUTH_PATH:-tfe-jwt}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get Vault root token
info "Getting Vault root token from secret..."
VAULT_TOKEN=$(kubectl get secret vault-keys -n "$VAULT_NAMESPACE" --context "$CONTEXT" -o jsonpath="{.data.root_token}" | base64 -d)

if [ -z "$VAULT_TOKEN" ]; then
    error "Failed to retrieve Vault root token"
    exit 1
fi

# Get TFE hostname
TFE_HOSTNAME="${TFE_HOSTNAME:-tfe.tfe.local}"
TFE_URL="https://$TFE_HOSTNAME"
JWKS_URL="$TFE_URL/.well-known/jwks"

info "TFE URL: $TFE_URL"
info "JWKS URL: $JWKS_URL"

# First, test if JWKS endpoint is accessible
info "Testing JWKS endpoint accessibility..."
kubectl run jwks-test --rm -i --restart=Never --image=curlimages/curl:latest --context "$CONTEXT" -- \
    curl -sk -o /dev/null -w "%{http_code}" "$JWKS_URL" || echo "failed"

echo ""

# Update JWT configuration with JWKS URL
info "Updating JWT auth method configuration with JWKS URL..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault write \"auth/$AUTH_PATH/config\" \
    jwks_url='$JWKS_URL' \
    bound_issuer='$TFE_URL'"

info "JWT configuration updated successfully"

# Verify configuration
echo ""
info "=== Verifying JWT Configuration ==="
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault read "auth/$AUTH_PATH/config"

echo ""
info "Configuration completed successfully!"
info "Vault will now use TFE's JWKS endpoint to verify workload identity tokens"
