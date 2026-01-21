#!/bin/bash
# Setup TLS Certificate for nginx Ingress (TLS Termination Mode)
# This script fetches a TLS certificate from Vault PKI and creates a Kubernetes secret

set -e

# Context and namespace
CONTEXT=${CONTEXT:-"kind-tfe"}
NAMESPACE=${NAMESPACE:-"tfe"}
SECRET_NAME=${SECRET_NAME:-"tfe-tls-cert"}
HOSTNAME=${HOSTNAME:-"tfe.tfe.local"}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-"vault"}

# Get Vault root token
echo "=== Getting Vault root token ==="
VAULT_TOKEN=$(kubectl get secret vault-keys -n "$VAULT_NAMESPACE" --context "$CONTEXT" -o jsonpath='{.data.root_token}' | base64 -d)
VAULT_ADDR="http://vault.$VAULT_NAMESPACE.svc.cluster.local:8200"

echo "=== Issuing certificate from Vault PKI for $HOSTNAME ==="
# Issue certificate with 90-day TTL (2160h)
kubectl run vault-cert-issue --rm -i --restart=Never --image=hashicorp/vault:1.21.2 \
  --env="VAULT_ADDR=$VAULT_ADDR" \
  --env="VAULT_TOKEN=$VAULT_TOKEN" \
  --context "$CONTEXT" -- sh -c '
    apk add --no-cache jq 2>/dev/null

    # Issue certificate
    vault write pki_int/issue/tfe-cert \
      common_name="'$HOSTNAME'" \
      ttl=2160h \
      -format=json > /tmp/cert_response.json

    # Extract certificate and private key
    jq -r ".data.certificate" /tmp/cert_response.json > /tmp/cert.pem
    jq -r ".data.private_key" /tmp/cert_response.json > /tmp/key.pem
    jq -r ".data.ca_chain[1]" /tmp/cert_response.json > /tmp/ca.pem  # Root CA is at index 1

    # Output files
    echo "=== Certificate ==="
    cat /tmp/cert.pem
    echo ""
    echo "=== Private Key ==="
    cat /tmp/key.pem
    echo ""
    echo "=== Root CA Certificate ==="
    cat /tmp/ca.pem
' 2>&1 | tee /tmp/vault-cert-output.txt

# Extract the certificate data from the output
sed -n '/=== Certificate ===/,/=== Private Key ===/p' /tmp/vault-cert-output.txt | sed '1d;$d' > /tmp/cert.pem
sed -n '/=== Private Key ===/,/=== Root CA Certificate ===/p' /tmp/vault-cert-output.txt | sed '1d;$d' > /tmp/key.pem
sed -n '/=== Root CA Certificate ===/,$p' /tmp/vault-cert-output.txt | sed '1d' > /tmp/ca.pem

echo ""
echo "=== Creating TLS secret in namespace $NAMESPACE ==="

# Create TLS secret with certificate and key
# Note: We use the certificate chain (cert + intermediate + CA) for tls.crt
cat /tmp/cert.pem > /tmp/tls.crt
cat /tmp/key.pem > /tmp/tls.key

# Create or update the secret
kubectl create secret tls "$SECRET_NAME" \
  --cert=/tmp/tls.crt \
  --key=/tmp/tls.key \
  -n "$NAMESPACE" \
  --context "$CONTEXT" \
  --dry-run=client -o yaml | kubectl apply --context "$CONTEXT" -f -

echo ""
echo "=== Verifying secret ==="
kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" --context "$CONTEXT"

echo ""
echo "=== Done! TLS certificate secret '$SECRET_NAME' is ready in namespace '$NAMESPACE' ==="
echo ""
echo "Certificate details:"
openssl x509 -in /tmp/cert.pem -noout -subject -dates

# Cleanup
rm -f /tmp/cert.pem /tmp/key.pem /tmp/ca.pem /tmp/tls.crt /tmp/tls.key /tmp/vault-cert-output.txt
