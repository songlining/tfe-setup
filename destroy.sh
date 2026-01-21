#!/bin/bash
# destroy.sh - Cleanup script for TFE on Kind
#
# This script destroys the Kind cluster and all resources.
#
# Usage: ./destroy.sh

set -e

CLUSTER_NAME="tfe"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${YELLOW}This will delete the Kind cluster '$CLUSTER_NAME' and all its resources.${NC}"
read -p "Are you sure? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Deleting Kind cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME"
    info "Cluster deleted successfully"
else
    warn "Kind cluster '$CLUSTER_NAME' does not exist"
fi

# Clean up any local temp files
rm -f /tmp/cert.pem /tmp/key.pem /tmp/ca.pem /tmp/tls.crt /tmp/tls.key /tmp/vault-cert-output.txt 2>/dev/null || true

info "Cleanup complete!"
echo ""
echo "To remove the /etc/hosts entry, run:"
echo "  sudo sed -i '' '/tfe.tfe.local/d' /etc/hosts"
