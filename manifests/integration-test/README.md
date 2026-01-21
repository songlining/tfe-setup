# Integration Test for TFE on Kubernetes

This directory contains the integration test report and verification scripts for the TFE on Kubernetes setup.

## Integration Test Status

**Last Updated**: 2026-01-21

**Overall Status**: CONFIGURED - Awaiting TFE deployment on amd64 cluster

### Test Summary

| Component | Status | Notes |
|-----------|--------|-------|
| Kind Cluster | PASS | Running v1.33.1 |
| dnsmasq DNS | PASS | Resolving external domains |
| MinIO (S3) | PASS | API accessible, tfe bucket ready |
| Redis | PASS | Authentication working |
| PostgreSQL | PASS | Database 'tfe' accessible |
| HashiCorp Vault | PASS | PKI configured |
| nginx Ingress | PASS | Controller running |
| TFE Helm Values | PASS | Configuration complete |
| TLS Certificates | PASS | Vault PKI issued |
| TLS Option 1 | PASS | Termination configured |
| TLS Option 2 | PASS | Passthrough configured |
| Vault JWT/OIDC | PASS | Auth method enabled |
| Workload Identity | CONFIGURED | Test configs ready |
| TFE Deployment | BLOCKED | Requires amd64 cluster |

## Files

- `INTEGRATION_TEST_REPORT.md` - Comprehensive test report with all verification results
- `run-integration-test.sh` - Script to run all integration tests

## Running Integration Tests

```bash
# Run all integration tests
./run-integration-test.sh
```

## Manual Verification

### Verify All Services

```bash
# Check all pods
kubectl get pods -A --context kind-tfe

# Check all services
kubectl get svc -A --context kind-tfe
```

### Verify Individual Components

#### Redis
```bash
kubectl exec -n redis <redis-pod> -- redis-cli -a redispassword123 PING
```

#### PostgreSQL
```bash
kubectl run psql-test --rm -i --restart=Never --image=postgres:15-alpine \
  --env="PGPASSWORD=tfepassword123" -- psql -h postgresql.psql.svc.cluster.local -U tfe -d tfe
```

#### MinIO S3
```bash
kubectl run s3-test --rm -i --restart=Never --image=minio/mc:latest \
  --command -- /bin/sh -c 'mc alias set minio http://minio.s3.svc.cluster.local:9000 minioadmin minioadmin123 && mc ls minio/tfe'
```

#### Vault
```bash
kubectl exec -n vault vault-0 -- vault status
```

#### DNS
```bash
kubectl run dns-test --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup google.com dnsmasq.dns.svc.cluster.local
```

## Blocking Issue

**TFE Deployment Blocked on Apple Silicon**:

Terraform Enterprise container images are ONLY available for `linux/amd64` architecture. The kind cluster on Apple Silicon (M1/M2/M3) creates `arm64` nodes by default.

### Resolution Options

1. **Cloud-based Kubernetes cluster** (EKS, GKE, AKS) with amd64 nodes
2. **VM-based local cluster**:
   - minikube with `--driver=vmware` or `--driver=virtualbox`
3. **Colima**: `colima start --arch x86_64 --kubernetes`
4. **Lima** with amd64 configuration

### Complete TFE Deployment

Once you have an amd64 cluster:

```bash
# 1. Create TFE namespace
kubectl create namespace tfe

# 2. Create image pull secret
kubectl create secret docker-registry terraform-enterprise \
  --docker-server=images.releases.hashicorp.com \
  --docker-username=terraform \
  --docker-password=$(cat tfe.license) \
  -n tfe

# 3. Install TFE Helm chart
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install terraform-enterprise hashicorp/terraform-enterprise \
  -n tfe -f manifests/tfe/values.yaml

# 4. Update Vault JWT JWKS URL
cd manifests/vault/oidc
./update-jwt-jwks.sh

# 5. Test Workload Identity
cd manifests/tfe/workload-identity-test
./setup-vault-test-data.sh
./verify-workload-identity.sh
```

## Documentation

- See `INTEGRATION_TEST_REPORT.md` for detailed test results
- See `../AGENTS.md` for component-specific knowledge
- See `../../progress.txt` for iteration history
