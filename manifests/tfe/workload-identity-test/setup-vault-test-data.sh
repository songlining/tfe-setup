#!/bin/bash
# setup-vault-test-data.sh
# Setup test data in Vault for Workload Identity testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Setting up Vault test data for Workload Identity testing"
echo "======================================"

# Check if Vault is accessible
echo "Checking Vault connection..."
kubectl exec -n vault vault-0 -- vault status > /dev/null 2>&1 || {
    echo "ERROR: Vault is not accessible. Is Vault running?"
    exit 1
}

# Get Vault root token
VAULT_TOKEN=$(kubectl get secret vault-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d)
export VAULT_TOKEN

echo "Vault root token retrieved successfully"

# Enable KV v2 secrets engine if not already enabled
echo ""
echo "Enabling KV v2 secrets engine at 'kv' path..."
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault secrets enable -path=kv kv-v2 2>/dev/null || echo 'KV v2 already enabled'"

# Create test secrets
echo ""
echo "Creating test secrets in Vault..."

# Test secret for basic read operation
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault kv put kv/test/workload-identity \
    test_value='Hello from Vault via TFE Workload Identity!' \
    environment='test' \
    source='terraform-enterprise' \
    timestamp='$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"

echo "✓ Created kv/test/workload-identity secret"

# Create additional test secrets for different scenarios
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault kv put kv/test/app-config \
    database_host='postgresql.psql.svc.cluster.local' \
    database_port='5432' \
    database_name='tfe' \
    redis_host='redis.redis.svc.cluster.local' \
    redis_port='6379'"

echo "✓ Created kv/test/app-config secret"

# Create a secret for testing at workspace level
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault kv put kv/test/workspace-secrets \
    api_endpoint='https://api.example.com' \
    api_key='test-key-12345' \
    workspace_name='test-workspace'"

echo "✓ Created kv/test/workspace-secrets secret"

# Enable database secrets engine for dynamic credentials test (optional)
echo ""
echo "Enabling database secrets engine (for dynamic credentials test)..."
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault secrets enable -path=database database 2>/dev/null || echo 'Database secrets engine already enabled'"

# Configure database connection for dynamic credentials
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault write database/config/tfe-postgres \
    plugin_name='postgresql-database-plugin' \
    connection_url='postgresql://{{username}}:{{password}}@postgresql.psql.svc.cluster.local:5432/postgres?sslmode=disable' \
    allowed_roles='tfe-role' \
    username='tfe' \
    password='tfepassword123'" 2>/dev/null || echo "Database configuration already exists or failed"

# Create role for database credentials
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=\$VAULT_TOKEN vault write database/roles/tfe-role \
    db_name='tfe-postgres' \
    creation_statements='CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD \"{{password}}\" VALID UNTIL \"{{expiration}}\"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";' \
    default_ttl='1h' \
    max_ttl='24h'" 2>/dev/null || echo "Database role already exists or failed"

echo "✓ Database secrets engine configured (if PostgreSQL is accessible)"

echo ""
echo "======================================"
echo "Vault test data setup complete!"
echo "======================================"
echo ""
echo "Test secrets created:"
echo "  - kv/test/workload-identity (basic read test)"
echo "  - kv/test/app-config (configuration test)"
echo "  - kv/test/workspace-secrets (workspace-level test)"
echo ""
echo "To verify the secrets, run:"
echo "  kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=\$VAULT_TOKEN vault kv list kv/test'"
echo ""
echo "To read a test secret:"
echo "  kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=\$VAULT_TOKEN vault kv get kv/test/workload-identity'"
echo ""
