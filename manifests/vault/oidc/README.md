# Vault JWT/OIDC Authentication for TFE Workload Identity

This directory contains scripts and documentation for configuring Vault JWT/OIDC authentication to work with Terraform Enterprise Workload Identity tokens.

## Overview

TFE Workload Identity allows Terraform runs in TFE to authenticate to external systems (like Vault) using OpenID Connect (OIDC) tokens. This eliminates the need for static credentials and provides a more secure, scalable way to manage dynamic credentials.

## Architecture

```
┌─────────────────┐                    ┌─────────────────┐
│  TFE Workspace  │                    │     Vault       │
│                 │                    │                 │
│  - Terraform    │  1. Request JWT    │  - JWT Auth     │
│    run starts   │  ────────────────> │    Method       │
│  - Generates    │                    │  - Validates    │
│    Workload     │                    │    JWT token    │
│    Identity     │                    │  - Issues Vault │
│    token        │                    │    token        │
└─────────────────┘                    └─────────────────┘
       │                                        │
       │  2. Use Vault token                    │
       │     to access secrets                  │
       └────────────────────────────────────────┘
```

## Components

### Files

- **configure-vault-jwt.sh**: Main script to configure Vault JWT/OIDC for TFE
- **update-jwt-jwks.sh**: Update JWT configuration with TFE JWKS endpoint (run after TFE deployment)
- **test-jwt-config.sh**: Verify JWT/OIDC configuration is working
- **README.md**: This documentation

### Vault Configuration

#### Auth Method
- **Path**: `tfe-jwt`
- **Type**: JWT
- **Issuer**: `https://tfe.tfe.local` (configurable via `TFE_HOSTNAME`)
- **JWKS URL**: `https://tfe.tfe.local/.well-known/jwks`

#### Roles

1. **tfe-workload-role**: Generic role for TFE workloads
   - Bound Audiences: `vault.workload.identity`
   - User Claim: `terraform_full_workspace`
   - Token TTL: 20 minutes

2. **tfe-org-role**: Organization-scoped role
   - Bound Audiences: `vault.workload.identity`
   - Bound Claims: `terraform_organization_name=*`
   - User Claim: `terraform_full_workspace`
   - Token TTL: 20 minutes

#### Policy

**tfe-workload-policy**: Permissions granted to TFE workloads
- Read secrets from `secret/` and `kv/` paths
- Token lookup and renewal
- Read JWT auth configuration
- Access to dynamic credential endpoints (AWS, GCP, Azure, Database, PKI, SSH)

## TFE Workload Identity Token Claims

TFE Workload Identity tokens contain the following claims:

### Standard OIDC Claims
- `jti`: Unique JWT identifier
- `iss`: Issuer (TFE instance URL)
- `iat`: Issued at timestamp
- `nbf`: Not before timestamp
- `aud`: Audience (defaults to `vault.workload.identity`)
- `exp`: Expiration timestamp
- `sub`: Subject with workspace path

### TFE-Specific Claims
- `terraform_organization_id`: Organization ID
- `terraform_organization_name`: Organization name
- `terraform_project_id`: Project ID
- `terraform_project_name`: Project name
- `terraform_workspace_id`: Workspace ID
- `terraform_workspace_name`: Workspace name
- `terraform_full_workspace`: Full workspace path (e.g., `org:project:workspace`)
- `terraform_run_id`: Run ID
- `terraform_run_phase`: Run phase (`plan` or `apply`)

## Usage

### 1. Initial Configuration

Run the main configuration script:

```bash
cd /Users/larry.song/work/hashicorp/tfe-setup/manifests/vault/oidc
./configure-vault-jwt.sh
```

This script:
- Enables JWT auth method at `tfe-jwt` path
- Creates `tfe-workload-policy` with appropriate permissions
- Creates `tfe-workload-role` and `tfe-org-role` JWT roles
- Configures basic JWT settings

**Note**: The JWKS URL configuration may fail if TFE is not yet deployed. This is expected.

### 2. Update JWKS Configuration (After TFE Deployment)

Once TFE is deployed and running, update the JWT configuration with the JWKS endpoint:

```bash
./update-jwt-jwks.sh
```

This script:
- Tests JWKS endpoint accessibility
- Updates JWT auth method configuration with the JWKS URL
- Verifies the configuration

### 3. Test Configuration

Verify the JWT/OIDC configuration:

```bash
./test-jwt-config.sh
```

This script:
- Verifies JWT auth method is enabled
- Checks JWT configuration
- Validates roles and policies
- Tests JWKS endpoint accessibility

## TFE Workspace Configuration

To enable Workload Identity in a TFE workspace, set the following environment variables:

```bash
# Enable Vault dynamic credentials
TFC_VAULT_PROVIDER_AUTH=true

# Vault address
TFC_VAULT_ADDR=https://vault.vault.svc.cluster.local:8200

# JWT role to use
TFC_VAULT_RUN_ROLE=tfe-workload-role

# Optional: Audience (must match Vault role's bound_audiences)
TFC_VAULT_WORKLOAD_IDENTITY_AUDIENCE=vault.workload.identity

# Optional: JWT auth path (default: jwt)
TFC_VAULT_AUTH_PATH=tfe-jwt

# Optional: Vault namespace (if using namespaces)
# TFC_VAULT_NAMESPACE=admin
```

## Example Terraform Configuration

Using Vault dynamic credentials in Terraform:

```hcl
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "vault" {
  # TFE Workload Identity will automatically handle authentication
  # No static token needed!
}

# Read a secret from Vault
data "vault_generic_secret" "example" {
  path = "secret/my-app/config"
}

output "secret_value" {
  value     = data.vault_generic_secret.example.data["password"]
  sensitive = true
}
```

## Troubleshooting

### JWKS Endpoint Not Accessible

**Problem**: `update-jwt-jwks.sh` fails with "error checking jwks URL"

**Solution**: Ensure TFE is deployed and accessible. Check:
- TFE pods are running: `kubectl get pods -n tfe`
- TFE service is accessible: `kubectl get svc -n tfe`
- DNS resolution: `kubectl run test --rm -it --image=busybox -- nslookup tfe.tfe.local`

### Token Validation Fails

**Problem**: Vault rejects TFE Workload Identity tokens

**Solution**: Check:
- JWT auth method configuration: `vault read auth/tfe-jwt/config`
- Role bound_audiences matches TFE audience setting
- User claim is set to `terraform_full_workspace`
- JWKS endpoint is accessible from Vault pod

### Permission Denied

**Problem**: TFE run fails with permission denied accessing Vault secrets

**Solution**: Check:
- Policy grants necessary permissions: `vault policy read tfe-workload-policy`
- Role includes the policy: `vault read auth/tfe-jwt/role/tfe-workload-role`
- Bound claims don't restrict the workspace

## Security Considerations

1. **Token TTL**: Keep token TTL short (20 minutes recommended)
2. **Bound Audiences**: Use specific audiences to prevent token replay
3. **Bound Claims**: Use `terraform_organization_name` to restrict access
4. **Policy Scope**: Grant minimum required permissions
5. **HTTPS**: Always use HTTPS for TFE and Vault communication

## JWKS URL Format

The JWKS (JSON Web Key Set) URL for TFE is:

```
https://<TFE_HOSTNAME>/.well-known/jwks
```

For example:
- `https://tfe.tfe.local/.well-known/jwks`
- `https://tfe.example.com/.well-known/jwks`
- `https://app.terraform.io/.well-known/jwks` (HCP Terraform)

## References

- [TFE Workload Identity Documentation](https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens)
- [Vault JWT Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Dynamic Credentials with Vault](https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/vault-configuration)

## Status

**Current Status**: Configuration complete and ready for use

**Dependencies**:
- Vault must be deployed and running (Story-6: Complete)
- TFE must be deployed and running (Story-8: BLOCKED on Apple Silicon)

**Next Steps**:
1. Deploy TFE to an amd64 cluster
2. Run `./update-jwt-jwks.sh` to configure JWKS endpoint
3. Run `./test-jwt-config.sh` to verify configuration
4. Configure TFE workspace variables
5. Test with a sample Terraform configuration
