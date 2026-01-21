#!/bin/bash
# Script to deploy nginx Ingress Controller for TFE on Kubernetes
# This script uses Helm to install/upgrade the nginx ingress controller

set -e

# Configuration
HELM_REPO="https://kubernetes.github.io/ingress-nginx"
HELM_CHART="ingress-nginx"
HELM_RELEASE="ingress-nginx"
NAMESPACE="ingress-nginx"
VALUES_FILE="$(dirname "$0")/values.yaml"
CONTEXT="kind-tfe"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "nginx Ingress Controller Deployment"
echo "=========================================="
echo ""

# Check if kubectl can connect to cluster
echo -e "${YELLOW}Checking cluster connection...${NC}"
if ! kubectl cluster-info --context "$CONTEXT" &> /dev/null; then
    echo -e "${RED}ERROR: Cannot connect to cluster with context '$CONTEXT'${NC}"
    exit 1
fi
echo -e "${GREEN}Cluster connection OK${NC}"
echo ""

# Set kubectl context
echo -e "${YELLOW}Setting kubectl context...${NC}"
kubectl config use-context "$CONTEXT"
echo -e "${GREEN}Context set to $CONTEXT${NC}"
echo ""

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}ERROR: helm is not installed${NC}"
    echo "Please install helm: https://helm.sh/docs/intro/install/"
    exit 1
fi

# Add ingress-nginx helm repo
echo -e "${YELLOW}Adding ingress-nginx Helm repository...${NC}"
helm repo add ingress-nginx "$HELM_REPO" || helm repo update ingress-nginx
echo -e "${GREEN}Helm repository configured${NC}"
echo ""

# Create namespace if it doesn't exist
echo -e "${YELLOW}Creating namespace '$NAMESPACE'...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}Namespace ready${NC}"
echo ""

# Check if release is already installed
if helm list -n "$NAMESPACE" | grep -q "$HELM_RELEASE"; then
    echo -e "${YELLOW}Upgrading existing Helm release...${NC}"
    helm upgrade "$HELM_RELEASE" ingress-nginx/"$HELM_CHART" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE"
else
    echo -e "${YELLOW}Installing new Helm release...${NC}"
    helm install "$HELM_RELEASE" ingress-nginx/"$HELM_CHART" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE"
fi
echo ""

# Wait for deployment to be ready
echo -e "${YELLOW}Waiting for nginx ingress controller to be ready...${NC}"
kubectl wait --for=condition=available deployment/ingress-nginx-controller \
    -n "$NAMESPACE" \
    --timeout=120s
echo -e "${GREEN}nginx ingress controller is ready${NC}"
echo ""

# Display status
echo "=========================================="
echo "Deployment Status"
echo "=========================================="
kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get svc -n "$NAMESPACE"
echo ""

# Display access information
echo "=========================================="
echo "Access Information"
echo "=========================================="
echo -e "${GREEN}nginx ingress controller deployed successfully${NC}"
echo ""
echo "Services:"
echo "  HTTP:  http://localhost"
echo "  HTTPS: https://localhost"
echo ""
echo "To check logs:"
echo "  kubectl logs -n $NAMESPACE deployment/ingress-nginx-controller --context $CONTEXT"
echo ""
echo "To create an Ingress resource for TFE, use example-ingress.yaml"
echo ""
