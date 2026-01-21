#!/bin/bash
# deploy.sh - One-click deployment script for TFE on Kind
#
# This script deploys Terraform Enterprise and all dependencies on a Kind cluster.
# It orchestrates all components in the correct order with proper wait conditions.
#
# Prerequisites:
#   - Docker Desktop running
#   - kind, kubectl, helm installed
#   - tfe.license file in the repository root
#
# Usage: ./deploy.sh

set -e

# Configuration
CLUSTER_NAME="tfe"
CONTEXT="kind-$CLUSTER_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}$1${NC}"; echo -e "${BLUE}========================================${NC}\n"; }

# Wait for pod to be ready
wait_for_pod() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    info "Waiting for pod with label '$label' in namespace '$namespace'..."
    kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --context "$CONTEXT" --timeout="${timeout}s"
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}
    info "Waiting for deployment '$deployment' in namespace '$namespace'..."
    kubectl rollout status deployment/"$deployment" -n "$namespace" --context "$CONTEXT" --timeout="${timeout}s"
}

# Check prerequisites
section "Checking Prerequisites"

if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install Docker Desktop."
fi

if ! docker info &> /dev/null; then
    error "Docker is not running. Please start Docker Desktop."
fi

if ! command -v kind &> /dev/null; then
    error "kind is not installed. Install with: brew install kind"
fi

if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed. Install with: brew install kubectl"
fi

if ! command -v helm &> /dev/null; then
    error "helm is not installed. Install with: brew install helm"
fi

if [ ! -f "$SCRIPT_DIR/tfe.license" ]; then
    error "TFE license file not found. Please place 'tfe.license' in the repository root."
fi

info "All prerequisites satisfied"

# Step 1: Create Kind cluster
section "Step 1: Creating Kind Cluster"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Kind cluster '$CLUSTER_NAME' already exists"
else
    info "Creating Kind cluster '$CLUSTER_NAME'..."
    kind create cluster --config "$SCRIPT_DIR/manifests/kind/cluster-config.yaml"
fi

# Verify cluster is accessible
kubectl cluster-info --context "$CONTEXT"
info "Kind cluster is ready"

# Step 2: Deploy dnsmasq
section "Step 2: Deploying dnsmasq DNS Server"

kubectl apply -k "$SCRIPT_DIR/manifests/dns/" --context "$CONTEXT"
wait_for_deployment "dns" "dnsmasq" 120
info "dnsmasq deployed successfully"

# Step 3: Deploy MinIO (S3)
section "Step 3: Deploying MinIO (S3 Storage)"

kubectl apply -k "$SCRIPT_DIR/manifests/s3/" --context "$CONTEXT"
wait_for_deployment "s3" "minio" 120
info "MinIO deployed successfully"

# Step 4: Deploy Redis
section "Step 4: Deploying Redis"

kubectl apply -k "$SCRIPT_DIR/manifests/redis/" --context "$CONTEXT"
wait_for_deployment "redis" "redis" 120
info "Redis deployed successfully"

# Step 5: Deploy PostgreSQL
section "Step 5: Deploying PostgreSQL"

kubectl apply -k "$SCRIPT_DIR/manifests/psql/" --context "$CONTEXT"
wait_for_deployment "psql" "postgresql" 120
info "PostgreSQL deployed successfully"

# Step 6: Deploy Vault
section "Step 6: Deploying Vault"

helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

if helm status vault -n vault --kube-context "$CONTEXT" &>/dev/null; then
    warn "Vault is already installed"
else
    kubectl create namespace vault --context "$CONTEXT" 2>/dev/null || true
    helm install vault hashicorp/vault \
        -n vault \
        --kube-context "$CONTEXT" \
        -f "$SCRIPT_DIR/manifests/vault/values.yaml" \
        --wait --timeout 5m
fi

wait_for_pod "vault" "app.kubernetes.io/name=vault" 300
info "Vault deployed successfully"

# Step 7: Initialize Vault and setup PKI
section "Step 7: Configuring Vault PKI"

info "Running Vault PKI setup script..."
"$SCRIPT_DIR/scripts/vault-pki-setup.sh"
info "Vault PKI configured successfully"

# Step 8: Deploy nginx Ingress Controller
section "Step 8: Deploying nginx Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

if helm status ingress-nginx -n ingress-nginx --kube-context "$CONTEXT" &>/dev/null; then
    warn "nginx ingress controller is already installed, upgrading..."
    helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
        -n ingress-nginx \
        --kube-context "$CONTEXT" \
        -f "$SCRIPT_DIR/manifests/nginx/values.yaml" \
        --wait --timeout 5m
else
    kubectl create namespace ingress-nginx --context "$CONTEXT" 2>/dev/null || true
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        -n ingress-nginx \
        --kube-context "$CONTEXT" \
        -f "$SCRIPT_DIR/manifests/nginx/values.yaml" \
        --set controller.extraArgs.enable-ssl-passthrough=true \
        --wait --timeout 5m
fi

wait_for_pod "ingress-nginx" "app.kubernetes.io/component=controller" 300
info "nginx ingress controller deployed successfully"

# Step 9: Setup TLS certificates
section "Step 9: Setting up TLS Certificates"

# Create TFE namespace
kubectl create namespace tfe --context "$CONTEXT" 2>/dev/null || true

# Setup TLS certificate from Vault
info "Issuing TLS certificate from Vault PKI..."
"$SCRIPT_DIR/manifests/nginx/setup-tls-cert.sh"
info "TLS certificate created successfully"

# Step 10: Deploy TFE
section "Step 10: Deploying Terraform Enterprise"

# Create license secret
info "Creating TFE license secret..."
kubectl create secret generic terraform-enterprise-license \
    -n tfe \
    --context "$CONTEXT" \
    --from-file=license="$SCRIPT_DIR/tfe.license" \
    --dry-run=client -o yaml | kubectl apply --context "$CONTEXT" -f -

# Setup TFE TLS certificate
info "Setting up TFE TLS certificate..."
"$SCRIPT_DIR/manifests/tfe/setup-tls-from-vault.sh"

# Deploy TFE with Helm
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true

if helm status terraform-enterprise -n tfe --kube-context "$CONTEXT" &>/dev/null; then
    warn "TFE is already installed, upgrading..."
    helm upgrade terraform-enterprise hashicorp/terraform-enterprise \
        -n tfe \
        --kube-context "$CONTEXT" \
        -f "$SCRIPT_DIR/manifests/tfe/values.yaml" \
        --wait --timeout 10m
else
    helm install terraform-enterprise hashicorp/terraform-enterprise \
        -n tfe \
        --kube-context "$CONTEXT" \
        -f "$SCRIPT_DIR/manifests/tfe/values.yaml" \
        --wait --timeout 10m
fi

info "Waiting for TFE pod to be ready (this may take several minutes on Apple Silicon)..."
kubectl wait --for=condition=ready pod -l app=terraform-enterprise -n tfe --context "$CONTEXT" --timeout=600s || {
    warn "TFE pod not ready yet. Check status with: kubectl get pods -n tfe --context $CONTEXT"
}

# Step 11: Apply Ingress
section "Step 11: Configuring Ingress"

info "Applying TLS passthrough ingress..."
kubectl apply -f "$SCRIPT_DIR/manifests/nginx/tls-passthrough-ingress.yaml" --context "$CONTEXT"
info "Ingress configured successfully"

# Step 12: Configure Vault JWT Auth (for Workload Identity)
section "Step 12: Configuring Vault JWT Auth for Workload Identity"

info "Configuring Vault JWT auth method..."
"$SCRIPT_DIR/manifests/vault/oidc/configure-vault-jwt.sh" || {
    warn "JWT JWKS configuration may need to be updated after TFE is fully running"
}
info "Vault JWT auth configured"

# Final Summary
section "Deployment Complete!"

echo -e "${GREEN}All components have been deployed successfully!${NC}"
echo ""
echo "Services deployed:"
echo "  - Kind cluster: $CLUSTER_NAME"
echo "  - dnsmasq: dns namespace"
echo "  - MinIO: s3 namespace"
echo "  - Redis: redis namespace"
echo "  - PostgreSQL: psql namespace"
echo "  - Vault: vault namespace"
echo "  - nginx: ingress-nginx namespace"
echo "  - TFE: tfe namespace"
echo ""
echo "To access TFE:"
echo "  1. Add to /etc/hosts on your Mac (if not already done):"
echo "     sudo sh -c 'echo \"127.0.0.1 tfe.tfe.local\" >> /etc/hosts'"
echo ""
echo "  2. Open in browser: https://tfe.tfe.local"
echo ""
echo "  3. Get IACT token for initial admin setup:"
echo "     kubectl exec -n tfe deployment/terraform-enterprise --context $CONTEXT -- tfectl admin token"
echo ""
echo "Troubleshooting:"
echo "  - Check pod status: kubectl get pods -A --context $CONTEXT"
echo "  - Check TFE logs: kubectl logs -n tfe -l app=terraform-enterprise --context $CONTEXT"
echo "  - Test health: curl -k https://tfe.tfe.local/_health_check"
echo ""
warn "Note: TFE on Apple Silicon runs via QEMU emulation and may be slow to start."
