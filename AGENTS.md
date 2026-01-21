# TFE on Kubernetes - Agent Knowledge Base

This document contains patterns, gotchas, and reusable solutions discovered during the TFE setup process.

---

## Working Patterns

### Kind Cluster Management
```bash
# Create cluster
kind create cluster --name tfe

# Delete cluster
kind delete cluster --name tfe

# Get cluster info
kubectl cluster-info --context kind-tfe

# Set kubectl context
kubectl config use-context kind-tfe
```

### Namespace Creation
```bash
# Create namespace (idempotent)
kubectl create namespace <name> --dry-run=client -o yaml | kubectl apply -f -
```

### Helm Chart Installation Pattern
```bash
# Add repo
helm repo add <repo-name> <repo-url>
helm repo update

# Install with values
helm install <release-name> <chart> -n <namespace> -f values.yaml

# Upgrade existing
helm upgrade --install <release-name> <chart> -n <namespace> -f values.yaml
```

### Service Discovery in Kubernetes
- Services are accessible via: `<service-name>.<namespace>.svc.cluster.local`
- Example: `postgresql.psql.svc.cluster.local`

---

## Anti-Patterns (Avoid These)

### Kind Cluster
- Don't create multiple clusters for different services - use namespaces instead
- Don't use `kind load docker-image` for public images - let Kubernetes pull them

### Helm
- Don't hardcode versions in scripts - use `--version` flag or let it default to latest
- Don't skip `helm repo update` before installations

### Secrets
- Never commit actual secrets to git
- Use Kubernetes secrets or external secret managers
- Document where secrets should come from

---

## Component-Specific Knowledge

### MinIO (S3-Compatible Storage)
- **Deployment**: Can use Helm chart (`minio/minio` or `bitnami/minio`) OR simple manifests
- **Image**: `minio/minio:latest` works well for simple deployments
- Default ports: API 9000, Console 9001
- **IMPORTANT**: Use `--console-address ":9001"` flag to enable web console
- Access key and secret key must be configured via `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` env vars
- Bucket must be created before TFE can use it
- **Health endpoints**: `/minio/health/ready` and `/minio/health/live` for probes
- **S3 Endpoint**: `http://minio.s3.svc.cluster.local:9000`
- **Bucket name**: `tfe`
- **Credentials**: Stored in secret `minio-credentials` in namespace `s3`
- **Testing with mc**: Use `--command -- /bin/sh -c '...'` syntax when running in pods

### Redis
- **Image**: `redis:7-alpine` works well (lightweight, no Helm chart needed)
- Default port: 6379
- Standalone mode is simpler than sentinel for development/testing
- Password authentication required via `--requirepass` flag
- **Endpoint**: `redis.redis.svc.cluster.local:6379`
- **Credentials**: Stored in secret `redis-credentials` in namespace `redis`
- **Password**: `redispassword123`
- AOF persistence recommended (`--appendonly yes`) for durability
- Use tcpSocket probes for health checks (simpler than exec probes)
- When testing with redis-cli, the `-a password` warning is expected behavior

### PostgreSQL
- **Image**: `postgres:15-alpine` works well (lightweight, no Helm chart needed)
- Default port: 5432
- Database and user created automatically via environment variables
- **Endpoint**: `postgresql.psql.svc.cluster.local:5432`
- **Credentials**: Stored in secret `postgresql-credentials` in namespace `psql`
  - Username: `tfe`
  - Password: `tfepassword123`
  - Database: `tfe`
- **IMPORTANT**: Set `PGDATA` to a subdirectory (e.g., `/var/lib/postgresql/data/pgdata`)
  - PVC root may contain `lost+found` or other files that cause initialization issues
- Use `pg_isready` exec probe for health checks
- `POSTGRES_DB` environment variable auto-creates the database during initialization
- When testing with psql from pods, use `PGPASSWORD` environment variable
- Use `-i` flag (not `-it`) with `kubectl run` for non-interactive psql commands

### HashiCorp Vault
- Helm chart: `hashicorp/vault`
- Default port: 8200
- Dev mode is NOT recommended for TLS cert generation
- PKI secrets engine required for certificate generation
- OIDC auth method required for Workload Identity
- **Endpoint**: `vault.vault.svc.cluster.local:8200`
- **Credentials**: Stored in secret `vault-keys` in namespace `vault`
  - Root Token: `hvs.1MmdQ3PhmwE9SnX309vLwEj2`
  - Unseal Key: `3k6WXVbFLuGKNNIa45qmjsHHouaH6pCGnVZi+dr0tl0=`
- **Standalone mode**: Uses StatefulSet, creates vault-0 pod (only one pod for non-HA)
- **PKI Configuration**:
  - Root CA path: `pki/` (10-year TTL, 4096-bit RSA)
  - Intermediate CA path: `pki_int/` (5-year TTL, 4096-bit RSA)
  - Certificate role: `pki_int/roles/tfe-cert` for tfe.local domain
  - Max TTL: 720h (30 days), Default TTL: 24h
- **Intermediate CA Setup Process**:
  1. Generate intermediate CSR
  2. Sign CSR with Root CA
  3. Import signed certificate back into intermediate CA
- When running vault CLI in pods, use `sh -c` wrapper and set VAULT_TOKEN environment variable
- hashicorp/vault:1.21.2 image includes jq, but `apk add jq` may be needed for some operations
- The 'region' parameter in vault write commands produces a warning but doesn't affect functionality
- Certificate chains are returned automatically when issuing from intermediate CA

### nginx Ingress Controller
- Helm chart: `ingress-nginx/ingress-nginx`
- **Image**: `registry.k8s.io/ingress-nginx/controller:v1.12.1`
- **Namespace**: `ingress-nginx`
- **Service type**: LoadBalancer (for kind, uses nodePort forwarding)
- **Port mappings** (configured in kind cluster-config.yaml):
  - Host port 80 → Container port 80 (HTTP)
  - Host port 443 → Container port 443 (HTTPS)
- **Resources**: 100m CPU request, 500m CPU limit; 90Mi memory request, 256Mi limit
- **Node selector**: `ingress-ready: "true"` (required for kind clusters)
- Supports both TLS termination and TLS passthrough modes
- **Configuration files**:
  - `manifests/nginx/values.yaml` - Helm values configuration
  - `manifests/nginx/deploy-nginx.sh` - Deployment script
  - `manifests/nginx/example-ingress.yaml` - Example Ingress resources for TFE

**TLS Option 1: TLS Termination at nginx**
- nginx terminates TLS and forwards HTTP to TFE pods
- Use `nginx.ingress.kubernetes.io/backend-protocol: HTTP` annotation
- TFE service should expose HTTP port (80)
- Simpler certificate management

**TLS Option 2: TLS Passthrough**
- nginx forwards encrypted traffic to TFE pods
- Use `nginx.ingress.kubernetes.io/ssl-passthrough: "true"` annotation
- TFE service should expose HTTPS port (443)
- End-to-end encryption, TFE manages certificates

**Important nginx Annotations for TFE**:
- `nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"` - Long-running TFE operations
- `nginx.ingress.kubernetes.io/proxy-send-timeout: "600"`
- `nginx.ingress.kubernetes.io/proxy-read-timeout: "600"`
- `nginx.ingress.kubernetes.io/proxy-body-size: "100m"` - Large uploads
- `nginx.ingress.kubernetes.io/websocket-services: "terraform-enterprise"` - Real-time features

**Learnings/Gotchas**:
- Helm does NOT support `--context` flag like kubectl does
- Must use `kubectl config use-context` before running helm commands
- Ingress resources must use `spec.ingressClassName: nginx` (not annotation `kubernetes.io/ingress.class`)
- When testing from within cluster, include `Host:` header to match ingress rules
- nginx returns 404 when no ingress resources match the request (expected behavior)
- The default backend is disabled in our configuration (we use TFE as backend)
- **Vault PKI intermediate CA needs a default issuer set** after importing signed certificate
  - Use `vault write pki_int/config/issuers` to set default issuer
  - The default issuer should be set before trying to issue certificates
  - Use `vault list pki_int/issuers` to see available issuers
- **Vault PKI certificate issuance returns ca_chain array**:
  - Index 0: Intermediate CA certificate
  - Index 1: Root CA certificate (when using intermediate CA)
  - Use `jq -r ".data.ca_chain[1]"` to extract root CA separately

### Terraform Enterprise
- Helm chart: `hashicorp/terraform-enterprise`
- **Image**: `images.releases.hashicorp.com/hashicorp/terraform-enterprise:v202507-1`
- **CRITICAL ARCHITECTURE REQUIREMENT**: TFE images are **ONLY available for amd64** architecture
  - HashiCorp does NOT provide arm64 images for TFE
  - On Apple Silicon (arm64), you MUST use:
    - A cloud-based Kubernetes cluster with amd64 nodes (EKS, GKE, AKS, etc.)
    - A VM-based local cluster (minikube/docker-desktop with amd64 nodes)
    - Colima or Lima with amd64 architecture explicitly set
  - kind on Apple Silicon creates arm64 nodes by default and CANNOT run TFE
  - DO NOT try to use QEMU/binfmt emulation with kind - it causes control plane crashes
- **IMPORTANT**: The image tag format is `vYYYYMM-#` and must match the license version
- **Image pull secret**: Must create `terraform-enterprise` docker-registry secret using the license file as password
- **License file**: Must be base64 encoded and embedded in `env.secrets.TFE_LICENSE`
- **Namespace**: `tfe`
- **Service type**: LoadBalancer (port 443, nodePort 30443 for kind)
- **Resource requirements**:
  - Requests: 4Gi memory, 1000m CPU
  - Limits: 8Gi memory, 2000m CPU
- **Security context**: runAsNonRoot=true, runAsUser=1000, fsGroup=1012
- **Configuration files**:
  - `manifests/tfe/values.yaml` - Main Helm values
  - `manifests/tfe/setup-tls-from-vault.sh` - TLS certificate setup script

### TFE Environment Variables
- **TFE_HOSTNAME**: DNS hostname for TFE (e.g., `tfe.tfe.local`)
- **TFE_ENCRYPTION_PASSWORD**: Required! Set to a secure value
- **TFE_CAPACITY_CONCENCY**: Note the typo (CONCENCY vs CONCURRENCY) - this is from HashiCorp
- **TFE_IACT_SUBNETS**: Which subnets can create IACTs (`0.0.0.0/0` for no restriction)
- **TFE_IACT_TIME_LIMIT**: IACT expiration time in seconds (1209600 = 14 days)
- **TFE_DATABASE_PARAMETERS**: Extra database params (e.g., `sslmode=disable`)
- **Two types of env vars in Helm chart**:
  - `env.variables`: Non-sensitive values (created as ConfigMap)
  - `env.secrets`: Sensitive values (created as Kubernetes Secrets)

### TFE TLS Certificate Setup
- Use Vault PKI intermediate CA to issue certificates
- Script `setup-tls-from-vault.sh` automates the process:
  1. Retrieves Vault root token from `vault-keys` secret
  2. Issues certificate from Vault PKI intermediate CA
  3. Creates `terraform-enterprise-certificates` secret with cert, key, and CA
- Secret must contain: `cert.pem`, `key.pem`, `ca.pem`
- Certificate TTL: 90 days (2160h) recommended
- Common name should match `TFE_HOSTNAME` (e.g., `tfe.tfe.local`)

---

## TFE Configuration Requirements

### Required External Services
- PostgreSQL database
- Redis for caching
- S3-compatible storage (MinIO)
- TLS certificates

### TFE Helm Values Key Settings
```yaml
# Service type
service:
  type: LoadBalancer

# Database
database:
  host: postgresql.psql.svc.cluster.local
  port: 5432
  name: tfe
  user: tfe
  password: tfepassword123  # From secret postgresql-credentials

# Redis
redis:
  host: redis.redis.svc.cluster.local
  port: 6379
  password: redispassword123  # From secret redis-credentials

# S3 Storage
objectStorage:
  type: s3
  s3:
    endpoint: http://minio.s3.svc.cluster.local:9000
    bucket: tfe
    region: us-east-1
```

---

## Vault PKI Configuration

### Enable PKI
```bash
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
```

### Generate Root CA
```bash
vault write pki/root/generate/internal \
    common_name="TFE Root CA" \
    ttl=87600h
```

### Create Role for TFE Certificates
```bash
vault write pki/roles/tfe-cert \
    allowed_domains="tfe.local" \
    allow_subdomains=true \
    max_ttl=72h
```

### Issue Certificate
```bash
vault write pki/issue/tfe-cert \
    common_name="tfe.tfe.local" \
    ttl=24h
```

---

## Vault OIDC for Workload Identity

### Enable OIDC Auth
```bash
vault auth enable oidc
```

### Configure OIDC
```bash
vault write auth/oidc/config \
    oidc_discovery_url="https://tfe.tfe.local" \
    oidc_client_id="vault" \
    oidc_client_secret="secret" \
    default_role="tfe-workload"
```

### Create Role for TFE Workloads
```bash
vault write auth/oidc/role/tfe-workload \
    bound_audiences="vault" \
    user_claim="terraform_organization_name" \
    role_type="jwt" \
    policies="tfe-policy" \
    ttl=1h
```

---

## DNS Configuration with dnsmasq

### Important: dnsmasq vs CoreDNS
- **CoreDNS** (built into Kubernetes): handles internal K8s service discovery (*.svc.cluster.local)
- **dnsmasq** (our custom deployment): handles custom .local domain resolution for TFE services
- Do NOT try to use dnsmasq to resolve Kubernetes internal services - it will return NXDOMAIN

### Accessing dnsmasq from other namespaces
```bash
# Use the service FQDN
nslookup example.com dnsmasq.dns.svc.cluster.local

# Or use the ClusterIP directly (get with: kubectl get svc -n dns)
nslookup example.com 10.96.x.x
```

### Testing DNS resolution
```bash
# Quick test from any namespace
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup google.com dnsmasq.dns.svc.cluster.local
```

### dnsmasq Deployment Pattern
- Use `dockurr/dnsmasq:latest` image (lightweight and works well)
- Requires NET_ADMIN capability to bind to port 53
- Use ConfigMap with:
  - `dnsmasq.conf`: main configuration
  - `hosts`: custom DNS entries (updated as services are deployed)

### ConfigMap for dnsmasq
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dnsmasq-config
data:
  dnsmasq.conf: |
    no-resolv
    server=8.8.8.8
    server=8.8.4.4
    local=/local/
    expand-hosts
    domain=local
    cache-size=1000
    no-hosts
    addn-hosts=/etc/dnsmasq.d/hosts
  hosts: |
    # Add entries like: 10.96.x.x tfe.local
```

---

## Troubleshooting Commands

### Check Pod Status
```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Check Services
```bash
kubectl get svc -n <namespace>
kubectl get endpoints -n <namespace>
```

### Test Connectivity
```bash
# From within cluster
kubectl run test-pod --rm -it --image=busybox -- /bin/sh
# Then: wget -qO- http://service.namespace.svc.cluster.local:port
```

### Port Forwarding for Testing
```bash
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>
```

---

## Story Dependencies

Stories are ordered so each can be fully tested before moving to the next.

```
story-1 (Kind Cluster)
    └── Foundation for all other stories

story-2 (dnsmasq DNS)
    └── Depends on: story-1
    └── Enables: DNS resolution for all services

story-3 (MinIO/S3)
    └── Depends on: story-1, story-2
    └── Enables: story-7 (TFE needs storage)

story-4 (Redis)
    └── Depends on: story-1
    └── Enables: story-7 (TFE needs Redis)

story-5 (PostgreSQL)
    └── Depends on: story-1
    └── Enables: story-7 (TFE needs database)

story-6 (Vault for TLS)
    └── Depends on: story-1
    └── Enables: story-7, story-10, story-11, story-12 (TLS certs, OIDC)

story-7 (TFE Helm Values)
    └── Depends on: story-3, story-4, story-5, story-6
    └── Enables: story-8 (configuration for TFE deployment)

story-8 (Deploy TFE)
    └── Depends on: story-7
    └── Enables: story-9, story-10, story-11, story-12 (TFE must be running)

story-9 (nginx NLB)
    └── Depends on: story-8 (TFE must be running to test routing)
    └── Enables: story-10, story-11 (TLS options)

story-10 (TLS Option 1 - NLB Terminates)
    └── Depends on: story-6, story-9
    └── Tests: HTTPS with nginx TLS termination
    └── Note: Can be configured without TFE running, but requires TFE for end-to-end verification

story-11 (TLS Option 2 - Passthrough)
    └── Depends on: story-6, story-9
    └── Tests: HTTPS with TFE handling TLS

story-12 (Vault OIDC Auth)
    └── Depends on: story-6, story-8 (needs TFE running for JWKS URL)
    └── Enables: story-13

story-13 (Workload Identity Test)
    └── Depends on: story-8, story-12
    └── Tests: TFE runs authenticating to Vault

story-14 (Final Integration)
    └── Depends on: All previous stories
    └── Comprehensive end-to-end validation
```

---

## Useful Links

- TFE Kubernetes Deployment: https://developer.hashicorp.com/terraform/enterprise/deploy/kubernetes
- TFE Helm Chart: https://github.com/hashicorp/terraform-enterprise-helm
- Workload Identity: https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens
- Kind: https://kind.sigs.k8s.io/
- Vault PKI: https://developer.hashicorp.com/vault/docs/secrets/pki
- Vault OIDC Auth: https://developer.hashicorp.com/vault/docs/auth/jwt

---

## Notes

### Iteration 3 (MinIO) Notes
- Simple manifest-based deployment works better than Helm for MinIO in kind clusters
- The 'standard' storageClassName works out-of-the-box with kind's local-path-provisioner
- Jobs with `ttlSecondsAfterFinished: 300` auto-cleanup after completion (good for one-time setup tasks)
- S3 API returning 400 Bad Request for unauthenticated requests is expected (confirms API is working)
- When testing S3 with AWS CLI, use `--endpoint-url` flag to point to MinIO
