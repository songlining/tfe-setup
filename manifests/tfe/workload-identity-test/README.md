# TFE Workload Identity Integration Test

This directory contains test configurations for validating the Workload Identity integration between Terraform Enterprise and HashiCorp Vault.

## Overview

Workload Identity allows Terraform runs in TFE to authenticate to Vault using a temporary JWT token issued by TFE, eliminating the need to store long-lived Vault tokens in TFE workspace variables.

**IMPORTANT**: This test configuration requires TFE to be deployed on an **amd64** Kubernetes cluster. See the main project README for alternatives if running on Apple Silicon.

## Prerequisites

1. **TFE Deployed**: TFE must be running and accessible (story-8)
2. **Vault Running**: Vault must be deployed and accessible (story-6)
3. **JWT Auth Configured**: Vault JWT/OIDC auth method configured (story-12)
4. **JWKS URL Updated**: The JWT auth method must have the TFE JWKS URL configured

## Files

| File | Description |
|------|-------------|
| `terraform-vault-test.tf` | Main Terraform configuration for testing Vault integration |
| `variables.tf` | Terraform variables for test configuration |
| `outputs.tf` | Output definitions for test verification |
| `setup-vault-test-data.sh` | Script to create test secrets in Vault |
| `verify-workload-identity.sh` | Script to verify Workload Identity configuration |
| `README.md` | This file |

## Quick Start

### 1. Setup Test Data in Vault

```bash
cd manifests/tfe/workload-identity-test
./setup-vault-test-data.sh
```

This creates:
- `kv/test/workload-identity` - Basic test secret
- `kv/test/app-config` - Application configuration
- `kv/test/workspace-secrets` - Workspace-level secrets

### 2. Verify Workload Identity Configuration

```bash
./verify-workload-identity.sh
```

This checks:
- TFE deployment status
- Vault JWT auth method configuration
- Vault roles and policies
- JWKS endpoint accessibility

### 3. Configure TFE Workspace

Create a new TFE workspace and add the following environment variables:

| Variable | Value |
|----------|-------|
| `TFC_VAULT_PROVIDER_AUTH` | `true` |
| `TFC_VAULT_ADDR` | `https://vault.vault.svc.cluster.local:8200` |
| `TFC_VAULT_RUN_ROLE` | `tfe-workload-role` |
| `TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE` | `vault.workload.identity` |
| `TFC_VAULT_AUTH_PATH` | `tfe-jwt` |

### 4. Upload Terraform Configuration to TFE

Upload the contents of this directory (`terraform-vault-test.tf`, `variables.tf`, `outputs.tf`) as the Terraform configuration in your TFE workspace.

### 5. Run a Terraform Plan/Apply

Run a Terraform plan in TFE. The first run may take longer as TFE establishes the Workload Identity trust relationship with Vault.

## Expected Results

### Successful Outputs

```
vault_authentication_status = "Successfully authenticated to Vault using TFE Workload Identity"

test_secret_value = "Hello from Vault via TFE Workload Identity!"

workspace_identity_claims = {
  organization = "your-org-name"
  workspace    = "workload-identity-test"
  run_id       = "run-xxx"
}
```

### Vault Run Logs

Check the TFE run logs for successful Vault authentication:

```
2025-01-21T00:00:00Z [INFO]  Provider: vault
2025-01-21T00:00:01Z [INFO]  Authenticating to Vault using Workload Identity
2025-01-01T00:00:02Z [INFO]  Successfully authenticated to Vault
2025-01-21T00:00:03Z [INFO]  Reading secret: kv/test/workload-identity
```

## Troubleshooting

### TFE Run Fails with "Vault authentication failed"

1. Verify Vault is accessible from TFE namespace:
   ```bash
   kubectl run vault-test -n tfe --rm -i --restart=Never --image=curlimages/curl:latest -- \
     curl -s https://vault.vault.svc.cluster.local:8200/v1/sys/health
   ```

2. Verify JWT auth method is configured:
   ```bash
   kubectl exec -n vault vault-0 -- vault read auth/tfe-jwt/config
   ```

3. Verify JWKS URL is set:
   ```bash
   kubectl exec -n vault vault-0 -- vault read auth/tfe-jwt/config -format=json | jq '.jwks_url'
   ```

### "No Vault token found" Error

This means Workload Identity authentication failed. Check:

1. TFE workspace variables are set correctly
2. JWT role exists in Vault:
   ```bash
   kubectl exec -n vault vault-0 -- vault read auth/tfe-jwt/role/tfe-workload-role
   ```

3. JWKS endpoint is accessible:
   ```bash
   curl -s -H "Host: tfe.tfe.local" http://<TFE-SERVICE-IP>/.well-known/jwks
   ```

### "Permission denied" Reading Secret

The Vault policy may not have the correct permissions. Verify:

```bash
kubectl exec -n vault vault-0 -- vault policy read tfe-workload-policy
```

The policy should include:
```hcl
path "kv/data/test/*" {
  capabilities = ["read", "list"]
}
```

## Advanced Testing

### Enable Dynamic Credentials Test

Set `test_dynamic_credentials = true` in the Terraform configuration to test dynamic database credential generation from Vault.

This requires the Vault database secrets engine to be configured (done by `setup-vault-test-data.sh`).

### Enable PKI Certificate Test

Set `test_pki = true` in the Terraform configuration to test certificate issuance from Vault PKI.

## Architecture Diagram

```
┌─────────────────┐
│   TFE Workspace │
│                 │
│  ┌───────────┐  │    Workload Identity Token (JWT)
│  │ Terraform │──┼──────────────────────────┐
│  │   Run     │  │                          │
│  └───────────┘  │                          │
└─────────────────┘                          │
                                              │
                                             ┌┴────────────────────────────────┐
                                             │  Vault (tfe-jwt auth method)    │
                                             │  - Validates JWT signature      │
                                             │  - Checks bound_audiences       │
                                             │  - Returns Vault token          │
                                             └────────────────────────────────┘
                                                        │
                                                        │ Vault Token
                                                        │
                                             ┌──────────┴──────────────────────┐
                                             │  Vault Secrets Engines         │
                                             │  - kv (test secrets)           │
                                             │  - database (dynamic creds)    │
                                             │  - pki (certificates)          │
                                             └─────────────────────────────────┘
```

## References

- [TFE Workload Identity Documentation](https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens)
- [Vault JWT Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault Provider for Terraform](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)

## Next Steps

After successful Workload Identity testing:

1. **Configure Production Workspaces**: Add TFE workspace variables for production workspaces
2. **Create Fine-Grained Policies**: Create specific Vault policies for different workspace access levels
3. **Enable Audit Logging**: Configure Vault audit logging to track Workload Identity token usage
4. **Set Token TTL**: Adjust token TTL based on security requirements (default: 20 minutes)
