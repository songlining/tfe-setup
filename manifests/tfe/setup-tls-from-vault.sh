#!/bin/bash
# setup-tls-from-vault.sh
#
# This script fetches TLS certificates from Vault and creates
# the Kubernetes secret required for TFE deployment.
#
# Usage: ./setup-tls-from-vault.sh

set -e

# Configuration
NAMESPACE="${TFE_NAMESPACE:-tfe}"
SECRET_NAME="${TFE_TLS_SECRET:-terraform-enterprise-certificates}"
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
COMMON_NAME="${TFE_COMMON_NAME:-tfe.tfe.local}"
TLS_TTL="${TFE_TLS_TTL:-2160h}"  # 90 days

echo "=========================================="
echo "TFE TLS Certificate Setup from Vault"
echo "=========================================="
echo "Namespace: $NAMESPACE"
echo "Secret Name: $SECRET_NAME"
echo "Common Name: $COMMON_NAME"
echo "TLS TTL: $TLS_TTL"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

# Check if the TFE namespace exists
if ! kubectl get namespace "$NAMESPACE" --context kind-tfe &> /dev/null; then
    echo "Creating TFE namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --context kind-tfe
fi

# Check if Vault is running
echo "Checking Vault status..."
if ! kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" --context kind-tfe &> /dev/null; then
    echo "Error: Vault pod $VAULT_POD not found in namespace $VAULT_NAMESPACE"
    exit 1
fi

# Get Vault root token from secret
echo "Fetching Vault credentials..."
VAULT_TOKEN=$(kubectl get secret vault-keys -n "$VAULT_NAMESPACE" --context kind-tfe -o jsonpath='{.data.root_token}' | base64 -d)

if [ -z "$VAULT_TOKEN" ]; then
    echo "Error: Could not retrieve Vault root token from vault-keys secret"
    exit 1
fi

# Issue certificate from Vault Root CA (fallback)
# Note: For production, use intermediate CA. This uses root CA for simplicity.
echo "Issuing certificate from Vault PKI Root CA..."
CERT_RESPONSE=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" --context kind-tfe -- \
    sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault write pki/issue/tfe-cert \
        common_name='$COMMON_NAME' \
        ttl='$TLS_TTL' \
        format=pem_bundle" 2>&1)

if [ $? -ne 0 ]; then
    echo "Error issuing certificate from Vault:"
    echo "$CERT_RESPONSE"
    exit 1
fi

# Extract the certificate data
CERTIFICATE=$(echo "$CERT_RESPONSE" | grep -A 1000 "certificate" | sed -n '/^certificate/,/^$/p' | sed 's/^certificate //' | tr -d ' ')
PRIVATE_KEY=$(echo "$CERT_RESPONSE" | grep -A 1000 "private_key" | sed -n '/^private_key/,/^$/p' | sed 's/^private_key //' | tr -d ' ')
ISSUING_CA=$(echo "$CERT_RESPONSE" | grep -A 1000 "issuing_ca" | sed -n '/^issuing_ca/,/^$/p' | sed 's/^issuing_ca //' | tr -d ' ')

if [ -z "$CERTIFICATE" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$ISSUING_CA" ]; then
    echo "Error: Could not extract certificate data from Vault response"
    echo "Response:"
    echo "$CERT_RESPONSE"
    exit 1
fi

echo "Certificate issued successfully!"
echo ""

# Create the Kubernetes secret
echo "Creating Kubernetes secret: $SECRET_NAME"
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" --context kind-tfe \
    --from-literal="cert.pem=$CERTIFICATE" \
    --from-literal="key.pem=$PRIVATE_KEY" \
    --from-literal="ca.pem=$ISSUING_CA" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=========================================="
echo "TLS Certificate Setup Complete!"
echo "=========================================="
echo ""
echo "Secret created: $SECRET_NAME in namespace $NAMESPACE"
echo ""
echo "You can verify the secret with:"
echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE --context kind-tfe"
echo ""
echo "To view the certificate details:"
echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE --context kind-tfe -o jsonpath='{.data.cert\.pem}' | base64 -d | openssl x509 -text -noout"
echo ""
