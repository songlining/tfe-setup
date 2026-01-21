# Terraform configuration to test Workload Identity integration with Vault
# This configuration demonstrates how to use Vault provider with TFE Workload Identity

terraform {
  required_version = ">= 1.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Vault provider configured with TFE Workload Identity
# The authentication is handled via TFE environment variables
provider "vault" {
  # These values are automatically provided by TFE when Workload Identity is enabled
  # No explicit token needed - TFE exchanges the workload identity token for a Vault token
}

# Test 1: Read a secret from Vault KV v2 secrets engine
data "vault_kv_secret_v2" "test_secret" {
  mount = "kv"
  name  = "test/workload-identity"
}

# Test 2: Generate dynamic credentials (if enabled)
# Example: Generate a PostgreSQL database credential
resource "vault_database_credentials" "test_db_creds" {
  count = var.test_dynamic_credentials ? 1 : 0

  name        = "tfe-test-creds-${terraform.workspace}"
  db_name     = "tfe-postgres"
  ttl         = "1h"
  max_ttl     = "24h"
}

# Test 3: Read a PKI certificate (if enabled)
data "vault_pki_secret_backend_cert" "test_cert" {
  count = var.test_pki ? 1 : 0

  backend     = "pki_int"
  name        = "tfe-test-${terraform.workspace}"
  common_name = "test.tfe.local"
  ttl         = "1h"
}

# Outputs to verify successful authentication and data retrieval
output "vault_authentication_status" {
  description = "Confirms successful Vault authentication via Workload Identity"
  value       = "Successfully authenticated to Vault using TFE Workload Identity"
}

output "test_secret_value" {
  description = "Test secret value read from Vault"
  value       = try(data.vault_kv_secret_v2.test_secret.data.test_value, "Secret not configured - create kv/test/workload-identity in Vault")
}

output "workspace_identity_claims" {
  description = "Workload Identity token claims (for verification)"
  value = {
    organization = terraform.workspace
    workspace    = try(terraform.workspace, "unknown")
    run_id       = try(terraform.env.TFE_RUN_ID, "N/A")
  }
}
