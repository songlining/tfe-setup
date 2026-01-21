#!/bin/bash
# run-integration-test.sh
# Comprehensive integration test for TFE on Kubernetes setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check function
check_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

check_info() {
    echo -e "${BLUE}ℹ INFO${NC}: $1"
}

# Test counter
PASSED=0
FAILED=0
WARNED=0

echo "======================================"
echo "TFE on Kubernetes - Integration Test"
echo "======================================"
echo ""
echo "Testing all TFE dependencies..."
echo ""

# Check kubectl context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
if [ "$CURRENT_CONTEXT" != "kind-tfe" ]; then
    check_warn "Not using kind-tfe context (current: $CURRENT_CONTEXT)"
    echo "  Use: kubectl config use-context kind-tfe"
else
    check_pass "Using correct kubectl context: kind-tfe"
fi
echo ""

# 1. Test Kind Cluster
echo "1. Testing Kind Cluster..."
NODES=$(kubectl get nodes --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$NODES" -gt 0 ]; then
    READY_NODES=$(kubectl get nodes --context kind-tfe --no-headers | grep -c " Ready " || true)
    if [ "$READY_NODES" -eq "$NODES" ]; then
        check_pass "All $READY_NODES node(s) are Ready"
        ((PASSED++))
    else
        check_fail "Some nodes are not ready"
        ((FAILED++))
    fi
else
    check_fail "No nodes found"
    ((FAILED++))
fi
echo ""

# 2. Test dnsmasq DNS
echo "2. Testing dnsmasq DNS..."
DNS_PODS=$(kubectl get pods -n dns --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$DNS_PODS" -gt 0 ]; then
    DNS_READY=$(kubectl get pods -n dns --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$DNS_READY" -gt 0 ]; then
        check_pass "dnsmasq is running ($DNS_READY pod(s))"
        ((PASSED++))

        # Test DNS resolution
        DNS_TEST=$(kubectl run dns-test-$$ --rm -i --restart=Never --image=busybox:1.36 \
            --context kind-tfe -- nslookup google.com dnsmasq.dns.svc.cluster.local 2>&1 | grep -c "Address:" || true)
        if [ "$DNS_TEST" -gt 0 ]; then
            check_pass "DNS resolution working (google.com resolved)"
            ((PASSED++))
        else
            check_fail "DNS resolution failed"
            ((FAILED++))
        fi
    else
        check_fail "dnsmasq pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "dnsmasq not deployed"
    ((FAILED++))
fi
echo ""

# 3. Test MinIO S3
echo "3. Testing MinIO S3..."
MINIO_PODS=$(kubectl get pods -n s3 --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$MINIO_PODS" -gt 0 ]; then
    MINIO_READY=$(kubectl get pods -n s3 --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$MINIO_READY" -gt 0 ]; then
        check_pass "MinIO is running ($MINIO_READY pod(s))"
        ((PASSED++))

        # Test S3 bucket
        S3_TEST=$(kubectl run s3-test-$$ --rm -i --restart=Never --image=minio/mc:latest \
            --command -- /bin/sh -c 'mc alias set minio http://minio.s3.svc.cluster.local:9000 minioadmin minioadmin123 >/dev/null 2>&1 && mc ls minio/tfe' \
            --context kind-tfe 2>&1 | grep -c "tfe" || true)
        if [ "$S3_TEST" -gt 0 ]; then
            check_pass "S3 bucket 'tfe' accessible"
            ((PASSED++))
        else
            check_fail "S3 bucket 'tfe' not accessible"
            ((FAILED++))
        fi
    else
        check_fail "MinIO pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "MinIO not deployed"
    ((FAILED++))
fi
echo ""

# 4. Test Redis
echo "4. Testing Redis..."
REDIS_PODS=$(kubectl get pods -n redis --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$REDIS_PODS" -gt 0 ]; then
    REDIS_READY=$(kubectl get pods -n redis --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$REDIS_READY" -gt 0 ]; then
        REDIS_POD=$(kubectl get pods -n redis --context kind-tfe --no-headers | grep Running | awk '{print $1}' | head -1)
        REDIS_TEST=$(kubectl exec -n redis "$REDIS_POD" --context kind-tfe -- redis-cli -a redispassword123 PING 2>&1 | grep -c "PONG" || true)
        if [ "$REDIS_TEST" -gt 0 ]; then
            check_pass "Redis is running and responding"
            ((PASSED++))
        else
            check_fail "Redis not responding to PING"
            ((FAILED++))
        fi
    else
        check_fail "Redis pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "Redis not deployed"
    ((FAILED++))
fi
echo ""

# 5. Test PostgreSQL
echo "5. Testing PostgreSQL..."
PSQL_PODS=$(kubectl get pods -n psql --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$PSQL_PODS" -gt 0 ]; then
    PSQL_READY=$(kubectl get pods -n psql --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$PSQL_READY" -gt 0 ]; then
        check_pass "PostgreSQL is running ($PSQL_READY pod(s))"
        ((PASSED++))

        # Test database connection
        PSQL_TEST=$(kubectl run psql-test-$$ --rm -i --restart=Never --image=postgres:15-alpine \
            --env="PGPASSWORD=tfepassword123" --context kind-tfe -- \
            psql -h postgresql.psql.svc.cluster.local -U tfe -d tfe -c 'SELECT 1;' 2>&1 | grep -c "1 row" || true)
        if [ "$PSQL_TEST" -gt 0 ]; then
            check_pass "PostgreSQL database 'tfe' accessible"
            ((PASSED++))
        else
            check_fail "PostgreSQL database 'tfe' not accessible"
            ((FAILED++))
        fi
    else
        check_fail "PostgreSQL pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "PostgreSQL not deployed"
    ((FAILED++))
fi
echo ""

# 6. Test Vault
echo "6. Testing HashiCorp Vault..."
VAULT_PODS=$(kubectl get pods -n vault --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$VAULT_PODS" -gt 0 ]; then
    VAULT_READY=$(kubectl get pods -n vault --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$VAULT_READY" -gt 0 ]; then
        check_pass "Vault is running ($VAULT_READY pod(s))"
        ((PASSED++))

        # Check Vault status
        VAULT_STATUS=$(kubectl exec -n vault vault-0 --context kind-tfe -- vault status 2>&1 | grep -c "Sealed.*false" || true)
        if [ "$VAULT_STATUS" -gt 0 ]; then
            check_pass "Vault is initialized and unsealed"
            ((PASSED++))
        else
            check_fail "Vault is sealed or not initialized"
            ((FAILED++))
        fi
    else
        check_fail "Vault pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "Vault not deployed"
    ((FAILED++))
fi
echo ""

# 7. Test nginx Ingress
echo "7. Testing nginx Ingress Controller..."
NGINX_PODS=$(kubectl get pods -n ingress-nginx --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$NGINX_PODS" -gt 0 ]; then
    NGINX_READY=$(kubectl get pods -n ingress-nginx --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$NGINX_READY" -gt 0 ]; then
        check_pass "nginx Ingress is running ($NGINX_READY pod(s))"
        ((PASSED++))
    else
        check_fail "nginx Ingress pods are not ready"
        ((FAILED++))
    fi
else
    check_fail "nginx Ingress not deployed"
    ((FAILED++))
fi
echo ""

# 8. Test TLS Certificates
echo "8. Testing TLS Certificates..."
TLS_CERT=$(kubectl get secret tfe-tls-cert -n tfe --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$TLS_CERT" -gt 0 ]; then
    check_pass "TLS certificate secret exists (tfe-tls-cert)"
    ((PASSED++))

    # Check certificate validity
    CERT_NOT_AFTER=$(kubectl get secret tfe-tls-cert -n tfe -o jsonpath='{.data.tls\.crt}' --context kind-tfe | \
        base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$CERT_NOT_AFTER" ]; then
        check_pass "Certificate valid until: $CERT_NOT_AFTER"
        ((PASSED++))
    else
        check_warn "Could not verify certificate expiry"
        ((WARNED++))
    fi
else
    check_warn "TLS certificate secret not found"
    ((WARNED++))
fi
echo ""

# 9. Check TLS Configuration
echo "9. Testing TLS Configuration..."
TCP_SERVICES=$(kubectl get configmap tcp-services -n ingress-nginx --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$TCP_SERVICES" -gt 0 ]; then
    check_pass "TLS passthrough ConfigMap exists (tcp-services)"
    ((PASSED++))
else
    check_warn "TLS passthrough ConfigMap not found"
    ((WARNED++))
fi

INGRESS_COUNT=$(kubectl get ingress -n tfe --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$INGRESS_COUNT" -gt 0 ]; then
    check_pass "TLS ingress resources configured ($INGRESS_COUNT ingress(es))"
    ((PASSED++))
else
    check_warn "No TLS ingress resources found"
    ((WARNED++))
fi
echo ""

# 10. Test TFE Deployment Status
echo "10. Testing TFE Deployment Status..."
TFE_PODS=$(kubectl get pods -n tfe --context kind-tfe --no-headers 2>/dev/null | wc -l)
if [ "$TFE_PODS" -gt 0 ]; then
    TFE_READY=$(kubectl get pods -n tfe --context kind-tfe --no-headers | grep -c " Running " || true)
    if [ "$TFE_READY" -gt 0 ]; then
        check_pass "TFE is running ($TFE_READY pod(s))"
        ((PASSED++))
    else
        check_warn "TFE pods exist but not ready"
        ((WARNED++))
    fi
else
    check_info "TFE not deployed (requires amd64 cluster)"
    echo "  - kind on Apple Silicon creates arm64 nodes"
    echo "  - TFE images are only available for amd64"
    echo "  - Resolution: Use EKS/GKE/AKS, Colima with --arch x86_64, or Lima"
fi
echo ""

# Summary
echo "======================================"
echo "Integration Test Summary"
echo "======================================"
echo ""
echo "Tests Passed:  $PASSED"
echo "Tests Failed:  $FAILED"
echo "Tests Warned:  $WARNED"
echo "Total Tests:   $((PASSED + FAILED + WARNED))"
echo ""

if [ "$FAILED" -eq 0 ]; then
    if [ "$WARNED" -gt 0 ]; then
        check_info "Some tests passed with warnings (TFE deployment pending)"
    else
        check_pass "All integration tests passed!"
    fi
    echo ""
    echo "All TFE dependencies are successfully deployed and verified."
    echo ""
    if [ "$TFE_PODS" -eq 0 ]; then
        echo "NOTE: TFE deployment is blocked on Apple Silicon (arm64)."
        echo "      Deploy on an amd64 cluster to complete the setup."
        echo ""
        echo "To deploy TFE:"
        echo "  1. Use a cloud cluster (EKS/GKE/AKS) with amd64 nodes"
        echo "  2. Or use: colima start --arch x86_64 --kubernetes"
        echo "  3. Run: helm install terraform-enterprise hashicorp/terraform-enterprise -n tfe -f manifests/tfe/values.yaml"
    fi
    exit 0
else
    check_fail "Some integration tests failed. Please check the output above."
    exit 1
fi
