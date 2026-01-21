#!/bin/bash
# verify-workload-identity.sh
# Verify Workload Identity integration between TFE and Vault

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Verifying TFE Workload Identity Integration"
echo "======================================"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check function
check_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

# 1. Check if TFE is running
echo ""
echo "1. Checking TFE deployment status..."
TFE_PODS=$(kubectl get pods -n tfe -l app.kubernetes.io/name=terraform-enterprise --no-headers 2>/dev/null | wc -l)
if [ "$TFE_PODS" -gt 0 ]; then
    TFE_READY=$(kubectl get pods -n tfe -l app.kubernetes.io/name=terraform-enterprise --no-headers | grep -c "Running" || true)
    if [ "$TFE_READY" -gt 0 ]; then
        check_pass "TFE pods are running ($TFE_READY pod(s) ready)"
    else
        check_fail "TFE pods exist but are not ready"
    fi
else
    check_fail "TFE is not deployed. Please deploy TFE first (story-8)"
    echo ""
    echo "Workload Identity testing requires TFE to be running."
    echo "This test configuration is ready but cannot be verified without TFE."
    exit 1
fi

# 2. Check if Vault is running
echo ""
echo "2. Checking Vault deployment status..."
VAULT_PODS=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault --no-headers 2>/dev/null | wc -l)
if [ "$VAULT_PODS" -gt 0 ]; then
    VAULT_READY=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault --no-headers | grep -c "Running" || true)
    if [ "$VAULT_READY" -gt 0 ]; then
        check_pass "Vault pods are running ($VAULT_READY pod(s) ready)"
    else
        check_fail "Vault pods exist but are not ready"
    fi
else
    check_fail "Vault is not deployed"
fi

# 3. Check Vault JWT auth method configuration
echo ""
echo "3. Checking Vault JWT auth method..."
JWT_ENABLED=$(kubectl exec -n vault vault-0 -- vault auth list 2>/dev/null | grep -c "tfe-jwt/" || true)
if [ "$JWT_ENABLED" -gt 0 ]; then
    check_pass "Vault JWT auth method 'tfe-jwt' is enabled"

    # Check JWT configuration
    JWT_CONFIG=$(kubectl exec -n vault vault-0 -- vault read auth/tfe-jwt/config -format=json 2>/dev/null || echo "{}")
    echo "$JWT_CONFIG" | jq -e '.bound_issuer' > /dev/null 2>&1 && check_pass "JWT bound_issuer configured" || check_warn "JWT bound_issuer not configured"

    # Check JWKS URL
    JWKS_URL=$(echo "$JWT_CONFIG" | jq -r '.jwks_url // "not set"' 2>/dev/null || echo "not set")
    if [ "$JWKS_URL" != "not set" ]; then
        check_pass "JWKS URL configured: $JWKS_URL"
    else
        check_warn "JWKS URL not set - Run ./update-jwt-jwks.sh after TFE deployment"
    fi
else
    check_fail "Vault JWT auth method 'tfe-jwt' not found - Run ./configure-vault-jwt.sh"
fi

# 4. Check Vault roles for Workload Identity
echo ""
echo "4. Checking Vault Workload Identity roles..."
ROLE_EXISTS=$(kubectl exec -n vault vault-0 -- vault list auth/tfe-jwt/roles 2>/dev/null | grep -c "tfe-workload-role" || true)
if [ "$ROLE_EXISTS" -gt 0 ]; then
    check_pass "Vault role 'tfe-workload-role' exists"

    # Check role configuration
    ROLE_CONFIG=$(kubectl exec -n vault vault-0 -- vault read auth/tfe-jwt/role/tfe-workload-role -format=json 2>/dev/null || echo "{}")
    echo "$ROLE_CONFIG" | jq -e '.bound_audiences' > /dev/null 2>&1 && check_pass "Role bound_audiences configured" || check_warn "Role bound_audiences not configured"
    echo "$ROLE_CONFIG" | jq -e '.user_claim' > /dev/null 2>&1 && check_pass "Role user_claim configured" || check_warn "Role user_claim not configured"
    echo "$ROLE_CONFIG" | jq -e '.policies' > /dev/null 2>&1 && check_pass "Role policies configured" || check_warn "Role policies not configured"
else
    check_fail "Vault role 'tfe-workload-role' not found"
fi

# 5. Check Vault policy for Workload Identity
echo ""
echo "5. Checking Vault Workload Identity policy..."
POLICY_EXISTS=$(kubectl exec -n vault vault-0 -- vault policy list 2>/dev/null | grep -c "tfe-workload-policy" || true)
if [ "$POLICY_EXISTS" -gt 0 ]; then
    check_pass "Vault policy 'tfe-workload-policy' exists"
else
    check_fail "Vault policy 'tfe-workload-policy' not found"
fi

# 6. Check test secrets in Vault
echo ""
echo "6. Checking test secrets in Vault..."
TEST_SECRET=$(kubectl exec -n vault vault-0 -- vault kv get kv/test/workload-identity 2>/dev/null || echo "not found")
if [ "$TEST_SECRET" != "not found" ]; then
    check_pass "Test secret kv/test/workload-identity exists"
else
    check_warn "Test secret not found - Run ./setup-vault-test-data.sh to create test data"
fi

# 7. Check TFE service endpoint
echo ""
echo "7. Checking TFE service accessibility..."
TFE_SVC=$(kubectl get svc -n tfe terraform-enterprise --no-headers 2>/dev/null | wc -l)
if [ "$TFE_SVC" -gt 0 ]; then
    check_pass "TFE service 'terraform-enterprise' exists"

    TFE_HOST=$(kubectl exec -n vault vault-0 -- sh -c 'echo $TFE_HOSTNAME 2>/dev/null || echo "tfe.tfe.local"')
    echo "   TFE Hostname: $TFE_HOST"
else
    check_warn "TFE service not found"
fi

# 8. Test JWKS endpoint accessibility (if TFE is running)
echo ""
echo "8. Checking TFE JWKS endpoint..."
TFE_SVC_IP=$(kubectl get svc -n tfe terraform-enterprise -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -n "$TFE_SVC_IP" ]; then
    # Try to access JWKS endpoint from within cluster
    JWKS_TEST=$(kubectl run jwks-test --rm -i --restart=Never --image=curlimages/curl:latest --silent -- \
        curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        -H "Host: $TFE_HOST" \
        "http://$TFE_SVC_IP/.well-known/jwks" 2>/dev/null || echo "000")

    if [ "$JWKS_TEST" = "200" ]; then
        check_pass "JWKS endpoint is accessible (HTTP 200)"
    else
        check_warn "JWKS endpoint returned HTTP $JWKS_TEST (may not be fully initialized)"
    fi
else
    check_warn "Cannot check JWKS endpoint - TFE service not found"
fi

# Summary
echo ""
echo "======================================"
echo "Verification Summary"
echo "======================================"
echo ""
echo "Workload Identity Configuration Status:"
echo ""
echo "To test Workload Identity end-to-end:"
echo "1. Ensure TFE is deployed and running"
echo "2. Run: ./setup-vault-test-data.sh (to create test secrets)"
echo "3. Run: ./update-jwt-jwks.sh (if JWKS URL not configured)"
echo "4. Create a TFE workspace with the Terraform configuration"
echo "5. Configure TFE workspace variables for Vault integration:"
echo "   - TFC_VAULT_PROVIDER_AUTH = true"
echo "   - TFC_VAULT_ADDR = https://vault.vault.svc.cluster.local:8200"
echo "   - TFC_VAULT_RUN_ROLE = tfe-workload-role"
echo "   - TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE = vault.workload.identity"
echo "   - TFC_VAULT_AUTH_PATH = tfe-jwt"
echo "6. Run a Terraform plan/apply in TFE"
echo "7. Verify the outputs show successful Vault authentication"
echo ""
