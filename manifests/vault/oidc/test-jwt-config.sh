#!/bin/bash
# Test Vault JWT/OIDC Configuration
# This script tests the JWT auth method configuration for TFE Workload Identity

set -e

# Context and namespace settings
CONTEXT="${CONTEXT:-kind-tfe}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
AUTH_PATH="${AUTH_PATH:-tfe-jwt}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header() { echo -e "${BLUE}=== $1 ===${NC}"; }

# Get Vault root token
info "Getting Vault root token from secret..."
VAULT_TOKEN=$(kubectl get secret vault-keys -n "$VAULT_NAMESPACE" --context "$CONTEXT" -o jsonpath="{.data.root_token}" | base64 -d)

if [ -z "$VAULT_TOKEN" ]; then
    error "Failed to retrieve Vault root token"
    exit 1
fi

header "Vault JWT/OIDC Configuration Test"
echo ""

# Test 1: Verify JWT auth method is enabled
header "Test 1: JWT Auth Method Status"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault auth list | grep -q "$AUTH_PATH" && {
    info "PASS: JWT auth method is enabled at path: $AUTH_PATH"
} || {
    error "FAIL: JWT auth method not found at path: $AUTH_PATH"
}
echo ""

# Test 2: Check JWT configuration
header "Test 2: JWT Auth Method Configuration"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault read "auth/$AUTH_PATH/config" -format=json 2>/dev/null | jq -r '.data | "Issuer: \(.bound_issuer)\nJWKS URL: \(.jwks_url // "Not configured")"' || {
    warn "Could not read JWT configuration"
}
echo ""

# Test 3: Verify policy exists
header "Test 3: TFE Workload Policy"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault policy list | grep -q "tfe-workload-policy" && {
    info "PASS: tfe-workload-policy exists"
} || {
    error "FAIL: tfe-workload-policy not found"
}
echo ""

# Test 4: Verify roles exist
header "Test 4: JWT Roles"
echo "Available JWT roles:"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault list "auth/$AUTH_PATH/role" 2>/dev/null || {
    error "No roles found"
}
echo ""

# Test 5: Check role details
header "Test 5: Role Details - tfe-workload-role"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault read "auth/$AUTH_PATH/role/tfe-workload-role" -format=json 2>/dev/null | jq -r '.data | "Policies: \(.token_policies | join(", "))\nBound Audiences: \(.bound_audiences | join(", "))\nUser Claim: \(.user_claim)\nToken TTL: \(.token_ttl)"' || {
    warn "Could not read role details"
}
echo ""

# Test 6: Test JWKS endpoint accessibility (requires TFE to be running)
header "Test 6: JWKS Endpoint Accessibility"
TFE_HOSTNAME="${TFE_HOSTNAME:-tfe.tfe.local}"
JWKS_URL="https://$TFE_HOSTNAME/.well-known/jwks"

info "Testing JWKS endpoint: $JWKS_URL"
HTTP_CODE=$(kubectl run jwks-test --rm -i --restart=Never --image=curlimages/curl:latest --context "$CONTEXT" -- \
    curl -sk -o /dev/null -w "%{http_code}" "$JWKS_URL" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    info "PASS: JWKS endpoint is accessible (HTTP 200)"

    # Show JWKS keys
    info "JWKS response:"
    kubectl run jwks-test --rm -i --restart=Never --image=curlimages/curl:latest --context "$CONTEXT" -- \
        curl -sk "$JWKS_URL" | jq '.' || warn "Could not parse JWKS response"
elif [ "$HTTP_CODE" = "000" ]; then
    warn "SKIP: Cannot reach JWKS endpoint (TFE not running or network issue)"
    warn "This is expected if TFE is not yet deployed"
else
    warn "JWKS endpoint returned HTTP $HTTP_CODE"
fi
echo ""

# Test 7: Summary
header "Summary"
echo "JWT Auth Path: $AUTH_PATH"
echo "TFE URL: https://$TFE_HOSTNAME"
echo "JWKS URL: $JWKS_URL"
echo ""

# Configuration status
if [ "$HTTP_CODE" = "200" ]; then
    info "Vault JWT/OIDC configuration is COMPLETE and WORKING"
    info "TFE workloads can now authenticate to Vault"
elif [ "$HTTP_CODE" = "000" ]; then
    warn "Vault JWT/OIDC configuration is PARTIALLY COMPLETE"
    warn "Run ./update-jwt-jwks.sh after TFE is deployed"
else
    warn "Vault JWT/OIDC configuration may have issues"
    warn "Check JWKS endpoint accessibility"
fi
echo ""

info "Test completed!"
