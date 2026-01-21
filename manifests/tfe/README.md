# TFE (Terraform Enterprise) on Kubernetes

This directory contains the Helm configuration for deploying Terraform Enterprise on Kubernetes.

## Prerequisites

Before deploying TFE, ensure the following are installed and configured:

1. **Kind Cluster** - Running `kind-tfe` cluster
2. **MinIO (S3)** - S3-compatible storage in the `s3` namespace
3. **Redis** - Cache storage in the `redis` namespace
4. **PostgreSQL** - Database in the `psql` namespace
5. **Vault** - PKI for TLS certificates in the `vault` namespace

## Configuration Files

### values.yaml
The main Helm values file for TFE deployment. This file configures:

- **Image**: Terraform Enterprise container image from HashiCorp registry
- **Resources**: CPU and memory requests/limits
- **TLS**: Certificate configuration (certificates from Vault PKI)
- **Database**: PostgreSQL connection settings
- **Redis**: Cache connection settings
- **Object Storage**: MinIO S3-compatible storage settings
- **Environment Variables**: All required TFE configuration variables

### setup-tls-from-vault.sh
Script to fetch TLS certificates from Vault and create the Kubernetes secret required for TFE.

## Credentials

### Database (PostgreSQL)
- **Host**: `postgresql.psql.svc.cluster.local:5432`
- **Database**: `tfe`
- **User**: `tfe`
- **Password**: `tfepassword123` (from secret `postgresql-credentials` in namespace `psql`)

### Redis
- **Host**: `redis.redis.svc.cluster.local:6379`
- **Password**: `redispassword123` (from secret `redis-credentials` in namespace `redis`)

### Object Storage (MinIO)
- **Endpoint**: `http://minio.s3.svc.cluster.local:9000`
- **Bucket**: `tfe`
- **Access Key**: `minioadmin`
- **Secret Key**: `minioadmin123` (from secret `minio-credentials` in namespace `s3`)
- **Region**: `us-east-1`

### Vault (PKI)
- **Endpoint**: `http://vault.vault.svc.cluster.local:8200`
- **Root Token**: `hvs.1MmdQ3PhmwE9SnX309vLwEj2` (from secret `vault-keys` in namespace `vault`)
- **Intermediate CA Path**: `pki_int/`
- **Certificate Role**: `tfe-cert`

### TFE License
- **Location**: `/Users/larry.song/work/hashicorp/tfe-setup/tfe.license`
- **Base64 encoded**: Included in `values.yaml` as `TFE_LICENSE` secret

## Deployment Steps

### 1. Create TFE Namespace
```bash
kubectl create namespace tfe --context kind-tfe --dry-run=client -o yaml | kubectl apply -f -
```

### 2. Create Image Pull Secret
```bash
cat /Users/larry.song/work/hashicorp/tfe-setup/tfe.license | \
  kubectl create secret docker-registry terraform-enterprise \
  --docker-server=images.releases.hashicorp.com \
  --docker-username=terraform \
  --docker-password=$(cat /Users/larry.song/work/hashicorp/tfe-setup/tfe.license) \
  -n tfe --context kind-tfe
```

### 3. Setup TLS Certificates from Vault
```bash
chmod +x setup-tls-from-vault.sh
./setup-tls-from-vault.sh
```

This will:
- Issue a certificate for `tfe.tfe.local` from Vault's intermediate CA
- Create the `terraform-enterprise-certificates` secret with cert, key, and CA

### 4. Update values.yaml with Certificate Data

After running the TLS setup script, update the `tls` section in `values.yaml`:

```bash
# Get the certificate data and update values.yaml
CERT_DATA=$(kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tfe -o jsonpath='{.data.cert\.pem}')
KEY_DATA=$(kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tse -o jsonpath='{.data.key\.pem}')
CA_DATA=$(kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tfe -o jsonpath='{.data.ca\.pem}')
```

Edit `values.yaml` and set:
```yaml
tls:
  certData: "<CERT_DATA>"
  keyData: "<KEY_DATA>"
  caCertData: "<CA_DATA>"
```

### 5. Add HashiCorp Helm Repository
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### 6. Install TFE
```bash
helm install terraform-enterprise hashicorp/terraform-enterprise \
  -n tfe \
  --values values.yaml \
  --context kind-tfe
```

### 7. Verify Deployment
```bash
# Check pods
kubectl get pods -n tfe --context kind-tfe

# Check service
kubectl get svc -n tfe --context kind-tfe

# Check logs
kubectl logs -n tfe -l app=terraform-enterprise --context kind-tfe
```

## Configuration Reference

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `TFE_HOSTNAME` | `tfe.tfe.local` | DNS hostname for accessing TFE |
| `TFE_DATABASE_HOST` | `postgresql.psql.svc.cluster.local:5432` | PostgreSQL endpoint |
| `TFE_DATABASE_NAME` | `tfe` | Database name |
| `TFE_DATABASE_USER` | `tfe` | Database user |
| `TFE_REDIS_HOST` | `redis.redis.svc.cluster.local:6379` | Redis endpoint |
| `TFE_REDIS_USE_AUTH` | `true` | Enable Redis authentication |
| `TFE_OBJECT_STORAGE_TYPE` | `s3` | Object storage type |
| `TFE_OBJECT_STORAGE_S3_BUCKET` | `tfe` | S3 bucket name |
| `TFE_OBJECT_STORAGE_S3_ENDPOINT` | `http://minio.s3.svc.cluster.local:9000` | MinIO endpoint |
| `TFE_OBJECT_STORAGE_S3_REGION` | `us-east-1` | S3 region |
| `TFE_CAPACITY_CONCENCY` | `10` | Concurrent runs |
| `TFE_CAPACITY_CPU` | `1000` | CPU per run (millicores) |
| `TFE_CAPACITY_MEMORY` | `4096` | Memory per run (MB) |

### TLS Configuration

TFE uses TLS for secure communication. Certificates are issued by Vault PKI:

- **Root CA**: Vault Root CA (10-year validity)
- **Intermediate CA**: Vault Intermediate CA (5-year validity)
- **Certificate**: Issued for `tfe.tfe.local` (90-day validity)

To view certificate details:
```bash
kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tfe \
  -o jsonpath='{.data.cert\.pem}' | base64 -d | openssl x509 -text -noout
```

## Troubleshooting

### TFE Pod Not Starting
```bash
kubectl describe pod -n tfe -l app=terraform-enterprise --context kind-tfe
kubectl logs -n tfe -l app=terraform-enterprise --context kind-tfe
```

### Database Connection Issues
```bash
kubectl run postgres-test --rm -it --image=postgres:15-alpine \
  --env="PGPASSWORD=tfepassword123" --context kind-tfe --restart=Never -- \
  psql -h postgresql.psql.svc.cluster.local -U tfe -d tfe -c 'SELECT 1'
```

### Redis Connection Issues
```bash
kubectl run redis-test --rm -it --image=redis:7-alpine --context kind-tfe --restart=Never -- \
  redis-cli -h redis.redis.svc.cluster.local -a redispassword123 PING
```

### S3 Connection Issues
```bash
kubectl run s3-test --rm -it --image=minio/mc --context kind-tfe --restart=Never -- \
  sh -c "mc alias set minio http://minio.s3.svc.cluster.local:9000 minioadmin minioadmin123 && mc ls minio/tfe"
```

### TLS Certificate Issues
```bash
# Check secret exists
kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tfe

# View certificate expiration
kubectl get secret terraform-enterprise-certificates -n tfe --context kind-tfe \
  -o jsonpath='{.data.cert\.pem}' | base64 -d | openssl x509 -noout -dates

# Re-issue certificate from Vault
./setup-tls-from-vault.sh
```

## Accessing TFE

Once TFE is running, access it at:

- **URL**: `https://tfe.tfe.local`
- **Health Check**: `https://tfe.tfe.local/_health_check`

For local development, you may need to add an entry to your `/etc/hosts` file:
```
<LoadBalancer IP> tfe.tfe.local
```

## Post-Installation

After TFE is deployed:

1. **Create Initial Admin User**: Navigate to the TFE URL and create the first admin user
2. **Verify Health Check**: `curl https://tfe.tfe.local/_health_check`
3. **Configure Workload Identity**: Set up Vault OIDC auth for dynamic credentials
4. **Set up nginx NLB**: Configure ingress/load balancer for external access

## Cleanup

```bash
# Uninstall TFE
helm uninstall terraform-enterprise -n tfe --context kind-tfe

# Delete namespace
kubectl delete namespace tfe --context kind-tfe
```
