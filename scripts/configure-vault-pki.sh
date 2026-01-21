#!/bin/bash
# Vault PKI Configuration Script for TFE on Kubernetes
# This script configures Vault as a PKI for TFE TLS certificates

set -e

# Vault configuration
VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"
VAULT_TOKEN="hvs.1MmdQ3PhmwE9SnX309vLwEj2"

# TFE domain configuration
TFE_DOMAIN="tfe.local"
TFE_NAMESPACE="tfe"

echo "=== Vault PKI Configuration for TFE ==="
echo "Vault Address: $VAULT_ADDR"
echo "TFE Domain: $TFE_DOMAIN"
echo ""

# Export VAULT_ADDR and VAULT_TOKEN for vault CLI
export VAULT_ADDR
export VAULT_TOKEN

echo "Step 1: Generating Root CA certificate..."
# Generate Root CA certificate
vault write pki/root/generate/internal \
    common_name="TFE Root CA" \
    ttl=87600h \
    key_bits=4096 \
    organization="HashiCorp TFE Lab" \
    ou="PKI" \
    locality="San Francisco" \
    region="California" \
    country=US

echo ""
echo "Step 2: Configuring Root CA URLs..."
vault write pki/config/urls \
    issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
    crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki/crl"

echo ""
echo "Step 3: Generating Intermediate CA certificate..."
# First, generate a CSR from the intermediate CA
vault write -format=json pki_int/intermediate/generate/internal \
    common_name="TFE Intermediate CA" \
    ttl=43800h \
    key_bits=4096 \
    organization="HashiCorp TFE Lab" \
    ou="PKI" \
    locality="San Francisco" \
    region="California" \
    country=US > /tmp/int_csr.json

INTERMEDIATE_CSR=$(cat /tmp/int_csr.json | jq -r '.data.csr')

# Sign the intermediate CSR with the Root CA
vault write -format=json pki/root/sign-intermediate \
    csr="$INTERMEDIATE_CSR" \
    use_csr_values=true \
    ttl=43800h > /tmp/int_cert.json

INTERMEDIATE_CERT=$(cat /tmp/int_cert.json | jq -r '.data.certificate')
echo "$INTERMEDIATE_CERT" > /tmp/int_cert.pem

# Import the signed certificate back into the intermediate CA
vault write pki_int/intermediate/set-signed certificate=@/tmp/int_cert.pem

echo ""
echo "Step 4: Configuring Intermediate CA URLs..."
vault write pki_int/config/urls \
    issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki_int/ca" \
    crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki_int/crl"

echo ""
echo "Step 5: Creating TFE certificate role in Intermediate CA..."
vault write pki_int/roles/tfe-cert \
    allowed_domains="$TFE_DOMAIN" \
    allow_subdomains=true \
    allow_bare_domains=true \
    max_ttl=720h \
    ttl=24h \
    key_bits=2048 \
    key_type=rsa \
    organization="HashiCorp TFE Lab" \
    ou="Applications"

echo ""
echo "Step 6: Verifying Root CA certificate..."
vault read pki/cert/ca

echo ""
echo "Step 7: Verifying Intermediate CA certificate..."
vault read pki_int/cert/ca

echo ""
echo "Step 8: Listing PKI roles..."
vault list pki_int/roles

echo ""
echo "Step 9: Testing certificate issuance for TFE domain..."
vault write -format=json pki_int/issue/tfe-cert \
    common_name="tfe.$TFE_DOMAIN" \
    ttl=24h

echo ""
echo "=== Vault PKI Configuration Complete ==="
echo "Root CA and Intermediate CA are configured"
echo "You can now issue certificates for TFE domain using:"
echo "  vault write pki_int/issue/tfe-cert common_name=<your-domain>.$TFE_DOMAIN"
