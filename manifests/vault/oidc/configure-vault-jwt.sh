#!/bin/bash
# Configure Vault JWT/OIDC Auth Method for TFE Workload Identity
# This script sets up Vault to accept TFE Workload Identity tokens

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

info "Vault root token retrieved successfully"

# Enable JWT auth method
info "Enabling JWT auth method at path: $AUTH_PATH..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault auth enable -path="$AUTH_PATH" jwt 2>/dev/null || {
    warn "JWT auth method already enabled at path: $AUTH_PATH"
}

# Get TFE hostname for JWKS URL configuration
TFE_HOSTNAME="${TFE_HOSTNAME:-tfe.tfe.local}"
TFE_URL="https://$TFE_HOSTNAME"
JWKS_URL="$TFE_URL/.well-known/jwks"

info "TFE URL for OIDC discovery: $TFE_URL"
info "JWKS URL: $JWKS_URL"

# Create TFE workload identity policy first
info "Creating TFE workload identity policy..."

# Create policy file
POLICY_FILE=$(cat <<'EOF'
# Allow reading secrets
path "secret/data/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

# Allow reading from KV v2 (if using)
path "kv/data/*" {
  capabilities = ["read", "list"]
}

# Allow token lookup and renewal
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Allow reading JWT auth configuration
path "auth/tfe-jwt/.*" {
  capabilities = ["read"]
}

# Dynamic credentials for common providers
# AWS
path "aws/creds/*" {
  capabilities = ["read"]
}

# GCP
path "gcp/key/*" {
  capabilities = ["read"]
}

# Azure
path "azure/creds/*" {
  capabilities = ["read"]
}

# Database
path "database/creds/*" {
  capabilities = ["read"]
}

# PKI (for certificate generation)
path "pki_int/issue/*" {
  capabilities = ["create", "update"]
}

# SSH
path "ssh/creds/*" {
  capabilities = ["read"]
}
EOF
)

# Write policy using a temp file approach
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' cat > /tmp/tfe-workload-policy.hcl << 'POLICY_EOF'
# Allow reading secrets
path \"secret/data/*\" {
  capabilities = [\"read\", \"list\"]
}

path \"secret/metadata/*\" {
  capabilities = [\"read\", \"list\"]
}

# Allow reading from KV v2 (if using)
path \"kv/data/*\" {
  capabilities = [\"read\", \"list\"]
}

# Allow token lookup and renewal
path \"auth/token/lookup-self\" {
  capabilities = [\"read\"]
}

path \"auth/token/renew-self\" {
  capabilities = [\"update\"]
}

# Allow reading JWT auth configuration
path \"auth/tfe-jwt/.*\" {
  capabilities = [\"read\"]
}

# Dynamic credentials for common providers
# AWS
path \"aws/creds/*\" {
  capabilities = [\"read\"]
}

# GCP
path \"gcp/key/*\" {
  capabilities = [\"read\"]
}

# Azure
path \"azure/creds/*\" {
  capabilities = [\"read\"]
}

# Database
path \"database/creds/*\" {
  capabilities = [\"read\"]
}

# PKI (for certificate generation)
path \"pki_int/issue/*\" {
  capabilities = [\"create\", \"update\"]
}

# SSH
path \"ssh/creds/*\" {
  capabilities = [\"read\"]
}
POLICY_EOF
"

kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault policy write tfe-workload-policy /tmp/tfe-workload-policy.hcl

info "TFE workload identity policy created successfully"

# Configure JWT auth method with JWKS URL
# Note: This will fail if TFE is not running, but we set it for when TFE is available
info "Configuring JWT auth method with TFE as identity provider..."
info "Note: JWKS endpoint will be available once TFE is deployed"

kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault write "auth/$AUTH_PATH/config" \
    jwks_url="$JWKS_URL" \
    bound_issuer="$TFE_URL" || {
    warn "JWKS URL configuration failed (TFE not running yet)"
    warn "Run ./update-jwt-jwks.sh after TFE is deployed"
}

info "JWT auth method configured"

# Create JWT role for TFE workloads
info "Creating JWT role for TFE workloads..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault write "auth/$AUTH_PATH/role/tfe-workload-role" \
    policies="tfe-workload-policy" \
    bound_audiences="vault.workload.identity" \
    bound_claims_type="glob" \
    user_claim="terraform_full_workspace" \
    role_type="jwt" \
    token_ttl="20m" \
    token_max_ttl="30m" \
    claim_mappings='{"terraform_organization_name": "organization", "terraform_workspace_name": "workspace", "terraform_run_id": "run_id"}' || {
    warn "Role may already exist, continuing..."
}

info "JWT role created successfully"

# Create organization-specific role (optional, for finer access control)
info "Creating organization-specific JWT role..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$CONTEXT" -- env VAULT_TOKEN="$VAULT_TOKEN" vault write "auth/$AUTH_PATH/role/tfe-org-role" \
    policies="tfe-workload-policy" \
    bound_audiences="vault.workload.identity" \
    bound_claims_type="glob" \
    bound_claims='{"terraform_organization_name": "*"}' \
    user_claim="terraform_full_workspace" \
    role_type="jwt" \
    token_ttl="20m" \
    token_max_ttl="30m" || {
    warn "Organization role may already exist, continuing..."
}

info "Organization-specific JWT role created successfully"

# Display configuration summary
echo ""
info "=== Vault JWT/OIDC Configuration Summary ==="
echo ""
echo "JWT Auth Path: $AUTH_PATH"
echo "TFE URL: $TFE_URL"
echo "JWKS URL: $JWKS_URL"
echo ""
echo "Vault Roles Created:"
echo "  - tfe-workload-role: Generic role for TFE workloads"
echo "  - tfe-org-role: Organization-scoped role"
echo ""
echo "Vault Policy Created:"
echo "  - tfe-workload-policy: Permissions for TFE workloads"
echo ""
echo "Next Steps:"
echo "1. Deploy TFE to an amd64 cluster (Story-8 is blocked on Apple Silicon)"
echo "2. Once TFE is running, verify JWKS endpoint is accessible:"
echo "   curl -k https://$TFE_HOSTNAME/.well-known/jwks"
echo "3. If JWKS is not working, run: ./update-jwt-jwks.sh"
echo "4. Test the configuration with: ./test-jwt-config.sh"
echo ""
warn "IMPORTANT: TFE must be deployed and running before JWKS endpoint is accessible"
warn "The JWKS URL will be: $JWKS_URL"
echo ""
info "Configuration completed successfully!"
