# TFE on Kubernetes Setup

A complete Terraform Enterprise deployment on Kubernetes using Kind (Kubernetes IN Docker), with all necessary dependencies including S3 storage, Redis, PostgreSQL, Vault for TLS/PKI, nginx as Network Load Balancer, and dnsmasq for DNS.

## Overview

This repository automates the deployment of Terraform Enterprise in a local Kubernetes environment for development and home lab use. It includes:

- **Terraform Enterprise** - The main application
- **MinIO** - S3-compatible object storage
- **Redis** - Caching and session storage
- **PostgreSQL** - Database backend
- **Vault** - PKI for TLS certificates and JWT/OIDC auth for Workload Identity
- **nginx** - Ingress controller / Network Load Balancer
- **dnsmasq** - DNS server for .local domain resolution

## Architecture

```
MacBook Pro (host)
    │
    │ https://tfe.tfe.local:443
    │ (resolved via /etc/hosts → 127.0.0.1)
    ▼
Docker Desktop
    │
    │ Port forwarding: 0.0.0.0:443 → container:443
    ▼
Kind cluster (tfe-control-plane container)
    │
    │ nginx with hostNetwork: true (binds directly to port 443)
    ▼
nginx Ingress Controller
    │
    │ Ingress rule: tfe.tfe.local → terraform-enterprise:443
    ▼
TFE Service (port 443)
    │
    ▼
TFE Pod (port 8443)
```

### Namespace Reference

| Service    | Namespace     | Description                          |
|------------|---------------|--------------------------------------|
| dnsmasq    | dns           | DNS server for .local domains        |
| MinIO      | s3            | S3-compatible object storage         |
| Redis      | redis         | Cache and session storage            |
| PostgreSQL | psql          | TFE database backend                 |
| Vault      | vault         | PKI and JWT/OIDC authentication      |
| nginx      | ingress-nginx | Network Load Balancer                |
| TFE        | tfe           | Terraform Enterprise application     |

## Prerequisites

1. **Docker Desktop** with Kubernetes enabled
2. **Kind** - `brew install kind`
3. **kubectl** - `brew install kubectl`
4. **Helm** - `brew install helm`
5. **TFE License** - Place `tfe.license` in the repository root

## Quick Start

### Option A: One-Click Deploy (Experimental)

> **Warning**: The `deploy.sh` script was created as an afterthought and has never been fully tested. It may not work correctly. Use the manual deployment steps below for a reliable setup.

```bash
# Place your TFE license file in the repo root
cp /path/to/your/license tfe.license

# Run the deployment script
./deploy.sh

# Cleanup when done
./destroy.sh
```

### Option B: Manual Deployment (Recommended)

#### 1. Create Kind Cluster

```bash
kind create cluster --config manifests/kind/cluster-config.yaml
```

#### 2. Deploy Components

Deploy in this order (each component has its own manifests directory):

```bash
# DNS
kubectl apply -k manifests/dns/

# S3 (MinIO)
kubectl apply -k manifests/s3/

# Redis
kubectl apply -k manifests/redis/

# PostgreSQL
kubectl apply -k manifests/psql/

# Vault (using Helm)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault -n vault --create-namespace -f manifests/vault/values.yaml

# Initialize Vault and configure PKI
./scripts/vault-pki-setup.sh

# nginx Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f manifests/nginx/values.yaml \
  --set controller.extraArgs.enable-ssl-passthrough=true

# Setup TLS certificates
./manifests/nginx/setup-tls-cert.sh
./manifests/tfe/setup-tls-from-vault.sh

# TFE
kubectl create namespace tfe
kubectl create secret generic terraform-enterprise-license -n tfe --from-file=license=tfe.license
helm install terraform-enterprise hashicorp/terraform-enterprise \
  -n tfe \
  -f manifests/tfe/values.yaml

# Apply ingress
kubectl apply -f manifests/nginx/tls-passthrough-ingress.yaml

# Configure Vault JWT auth for Workload Identity
./manifests/vault/oidc/configure-vault-jwt.sh
```

#### 3. Configure Host Access

Add to `/etc/hosts` on your Mac:

```bash
sudo sh -c 'echo "127.0.0.1 tfe.tfe.local" >> /etc/hosts'
```

### 4. Access TFE

Open in browser: **https://tfe.tfe.local**

Accept the self-signed certificate warning (click Advanced → Proceed).

## Initial Admin Setup

On first access, create an admin account using an IACT (Initial Admin Creation Token).

### Get the IACT Token

```bash
kubectl exec -n tfe deployment/terraform-enterprise --context kind-tfe -- tfectl admin token
```

### Create Admin Account

Navigate to:
```
https://tfe.tfe.local/admin/account/new?token=<IACT_TOKEN>
```

## Components Detail

### MinIO (S3)
- **Endpoint**: `minio.s3.svc.cluster.local:9000`
- **Credentials**: minioadmin / minioadmin123
- **Bucket**: `tfe-bucket`

### Redis
- **Endpoint**: `redis.redis.svc.cluster.local:6379`
- **Password**: redispassword123

### PostgreSQL
- **Endpoint**: `postgresql.psql.svc.cluster.local:5432`
- **Database**: tfe
- **User**: tfe / tfepassword123

### Vault
- **Endpoint**: `vault.vault.svc.cluster.local:8200`
- **PKI**: Configured with Root CA and Intermediate CA
- **JWT Auth**: Configured for TFE Workload Identity

## TLS Configuration

Two TLS modes are supported:

### Option 1: TLS Termination at nginx
nginx terminates TLS and forwards HTTP to TFE.

```bash
kubectl apply -f manifests/nginx/tls-termination-ingress.yaml
```

### Option 2: TLS Passthrough
nginx passes encrypted traffic directly to TFE (end-to-end encryption).

```bash
kubectl apply -f manifests/nginx/tls-passthrough-ingress.yaml
```

## Workload Identity

TFE Workload Identity is configured to authenticate with Vault using JWT/OIDC:

1. JWT auth method enabled at `tfe-jwt` path
2. Vault roles configured for workspace-scoped access
3. Policies grant access to secrets, dynamic credentials, PKI

Test configurations available in `manifests/tfe/workload-identity-test/`.

## Troubleshooting

### Check nginx ingress controller
```bash
kubectl get pods -n ingress-nginx --context kind-tfe
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50 --context kind-tfe
```

### Check TFE pod status
```bash
kubectl get pods -n tfe --context kind-tfe
```

### Check TFE logs
```bash
kubectl logs -n tfe deployment/terraform-enterprise --tail=50 --context kind-tfe
```

### Test TFE health
```bash
curl -k https://tfe.tfe.local/_health_check
```
Should return: `OK`

### Verify nginx is listening on port 443
```bash
docker exec tfe-control-plane ss -tlnp | grep :443
```

### If port 443 is not working

Re-deploy nginx with the correct settings:
```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values manifests/nginx/values.yaml \
  --kube-context kind-tfe
```

Key settings in `manifests/nginx/values.yaml`:
- `hostNetwork: true` - binds nginx directly to ports 80/443 on the node
- `dnsPolicy: ClusterFirstWithHostNet` - required when using hostNetwork

## Project Structure

```
tfe-setup/
├── README.md                 # This file
├── deploy.sh                 # One-click deploy (experimental, untested)
├── destroy.sh                # Cleanup script
├── prd.json                  # Story tracking (14 stories)
├── prompt.md                 # Project requirements
├── progress.txt              # Iteration log
├── AGENTS.md                 # Knowledge base for agents
├── ralph-claude.sh           # Ralph Loop orchestrator
├── tfe.license               # TFE license (not in git)
│
├── manifests/
│   ├── kind/                 # Kind cluster configuration
│   ├── dns/                  # dnsmasq DNS server
│   ├── s3/                   # MinIO S3 storage
│   ├── redis/                # Redis cache
│   ├── psql/                 # PostgreSQL database
│   ├── vault/                # Vault PKI and OIDC
│   │   └── oidc/             # JWT auth configuration
│   ├── nginx/                # nginx ingress controller
│   ├── tfe/                  # Terraform Enterprise
│   │   └── workload-identity-test/
│   └── integration-test/     # Integration test suite
│
└── scripts/                  # Utility scripts
```

## How This Repo Was Created

This repository was built using the **Ralph Loop** autonomous agent iteration system:

1. **Stories** defined in `prd.json` with acceptance criteria
2. **Agents** implement one story at a time
3. **Progress** tracked in `progress.txt`
4. **Knowledge** accumulated in `AGENTS.md`
5. Each completed story committed to git

All 14 stories have been completed and verified.

## Documentation Links

- [TFE Kubernetes Deployment](https://developer.hashicorp.com/terraform/enterprise/deploy/kubernetes)
- [TFE Helm Chart](https://github.com/hashicorp/terraform-enterprise-helm)
- [Workload Identity](https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens)
- [Kind](https://kind.sigs.k8s.io/)
- [Vault PKI](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [Vault JWT Auth](https://developer.hashicorp.com/vault/docs/auth/jwt)

## Notes

- This project was built and tested on a **MacBook Pro M4 (Apple Silicon)**
- TFE images are amd64-only; on Apple Silicon they run via QEMU emulation (slower performance)
- This is a lab environment - credentials are not production-ready
- The Kind cluster maps ports 80, 443, and 30443 to the host
