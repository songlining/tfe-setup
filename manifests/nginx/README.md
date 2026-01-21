# nginx Ingress Controller for TFE on Kubernetes

This directory contains the configuration for deploying nginx as a Network Load Balancer to handle traffic routing to Terraform Enterprise.

## Overview

nginx ingress controller is deployed as a LoadBalancer to provide:
- External access to TFE from outside the cluster
- TLS termination OR TLS passthrough options
- HTTP/HTTPS routing to TFE pods
- Load balancing across multiple TFE pods (if scaled)

## Architecture

```
External Traffic
       |
       v
[ nginx Ingress Controller ] (LoadBalancer - ports 80, 443)
       |
       +-- Option 1: TLS Termination (nginx terminates TLS, forwards HTTP to TFE)
       |
       +-- Option 2: TLS Passthrough (nginx forwards encrypted traffic to TFE)
                |
                v
         [ TFE Pods ]
```

## Files

- `values.yaml` - Helm chart configuration for nginx ingress controller
- `deploy-nginx.sh` - Deployment script
- `setup-tls-cert.sh` - Script to fetch TLS certificate from Vault PKI
- `tls-termination-ingress.yaml` - Ingress resource for TLS termination mode (Story-10)
- `tls-passthrough-ingress.yaml` - Complete configuration for TLS passthrough mode (Story-11)
- `example-ingress.yaml` - Example Ingress resources for TFE (both TLS options)
- `README.md` - This file

## Prerequisites

1. kind cluster with port mappings configured (already done in cluster-config.yaml)
2. Helm 3.x installed
3. kubectl configured to connect to kind-tfe cluster

## Deployment

### Quick Deploy

```bash
cd /Users/larry.song/work/hashicorp/tfe-setup/manifests/nginx
./deploy-nginx.sh
```

### Manual Deploy

```bash
# Add nginx ingress Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Create namespace
kubectl create namespace ingress-nginx --context kind-tfe --dry-run=client -o yaml | kubectl apply --context kind-tfe -f -

# Install nginx ingress controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values values.yaml \
  --context kind-tfe

# Wait for deployment
kubectl wait --for=condition=available deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s --context kind-tfe
```

## Verification

### Check Pod Status

```bash
kubectl get pods -n ingress-nginx --context kind-tfe
```

Expected output:
```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
```

### Check Service

```bash
kubectl get svc -n ingress-nginx --context kind-tfe
```

Expected output:
```
NAME                       TYPE           EXTERNAL-IP      PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.96.xxx.xxx    80:30080/TCP,443:30443/TCP   1m
ingress-nginx-admission    ClusterIP      10.96.xxx.xxx    443/TCP                      1m
```

### Check Logs

```bash
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --context kind-tfe
```

### Test HTTP Access

```bash
# Test from host machine
curl -I http://localhost

# Should return 404 (default backend is disabled) or nginx error page
```

### Test HTTPS Access

```bash
# Test from host machine
curl -kI https://localhost

# Should return 404 or SSL error (no certificate configured yet)
```

## Configuration Options

### Option 1: TLS Termination at nginx (Story-10 - IMPLEMENTED)

In this mode:
- nginx handles TLS termination
- TFE receives unencrypted HTTP traffic
- Simpler certificate management
- nginx handles all HTTPS-related work

**Files:**
- `setup-tls-cert.sh` - Script to fetch TLS certificate from Vault PKI
- `tls-termination-ingress.yaml` - Ingress resource for TLS termination

**Setup Steps:**

1. **Fetch TLS certificate from Vault:**
   ```bash
   cd /Users/larry.song/work/hashicorp/tfe-setup/manifests/nginx
   ./setup-tls-cert.sh
   ```
   This script:
   - Retrieves Vault root token from `vault-keys` secret
   - Issues certificate from Vault PKI intermediate CA
   - Creates `tfe-tls-cert` secret with cert and key
   - Certificate TTL: 90 days (2160h)

2. **Apply Ingress resource:**
   ```bash
   kubectl apply -f tls-termination-ingress.yaml --context kind-tfe
   ```

3. **Verify Ingress:**
   ```bash
   kubectl get ingress -n tfe --context kind-tfe
   kubectl describe ingress tfe-ingress-termination -n tfe --context kind-tfe
   ```

**Important Notes:**
- TFE service should expose HTTP port (80)
- TLS certificate is stored in `tfe-tls-cert` secret in `tfe` namespace
- Certificate must include `tfe.tfe.local` in SAN or CN
- Vault PKI role `tfe-cert` is configured for `tfe.local` domain
- Certificate includes full chain (intermediate + root CA)

**Verification (once TFE is running):**
```bash
# Add entry to /etc/hosts
echo "127.0.0.1 tfe.tfe.local" | sudo tee -a /etc/hosts

# Test HTTPS access (should work once TFE is deployed)
curl -Iv https://tfe.tfe.local

# Should see TFE web UI in browser
open https://tfe.tfe.local
```

### Option 2: TLS Passthrough (Story-11 - IMPLEMENTED)

In this mode:
- nginx forwards encrypted traffic to TFE
- TFE handles TLS termination with Vault-issued certificate
- End-to-end encryption
- TFE manages its own certificates
- Client sees TFE certificate directly

**Architecture:**
```
Client --[TLS]--> nginx (passthrough) --[TLS]--> TFE pods (terminates TLS)
```

**Files:**
- `tls-passthrough-ingress.yaml` - Complete configuration for TLS passthrough mode
- Includes TCP services ConfigMap and Ingress resources

**Setup Steps:**

1. **Remove TLS termination ingress (if active):**
   ```bash
   kubectl delete -f tls-termination-ingress.yaml --context kind-tfe
   ```

2. **Apply TLS passthrough configuration:**
   ```bash
   kubectl apply -f tls-passthrough-ingress.yaml --context kind-tfe
   ```

3. **Verify configuration:**
   ```bash
   # Check tcp-services ConfigMap
   kubectl get configmap tcp-services -n ingress-nginx --context kind-tfe -o yaml

   # Check ingress resources
   kubectl get ingress -n tfe --context kind-tfe

   # Verify nginx loaded tcp-services
   kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --context kind-tfe | grep -i "tcp\|443"
   ```

**Important Notes:**
- TFE service must expose HTTPS port (443)
- TFE must have TLS certificate from Vault in `terraform-enterprise-certificates` secret
- The tcp-services ConfigMap configures nginx to passthrough TCP traffic on port 443
- Only ONE TLS option can be active at a time (termination OR passthrough)

**Switching Between Options:**

To switch from TLS termination to TLS passthrough:
```bash
kubectl delete -f tls-termination-ingress.yaml --context kind-tfe
kubectl apply -f tls-passthrough-ingress.yaml --context kind-tfe
```

To switch from TLS passthrough to TLS termination:
```bash
kubectl delete -f tls-passthrough-ingress.yaml --context kind-tfe
kubectl apply -f tls-termination-ingress.yaml --context kind-tfe
```

**Verification (once TFE is running):**
```bash
# Add entry to /etc/hosts
echo "127.0.0.1 tfe.tfe.local" | sudo tee -a /etc/hosts

# Test HTTPS access (should work once TFE is deployed)
curl -Iv https://tfe.tfe.local

# Should see TFE web UI in browser
open https://tfe.tfe.local
```

**Difference Between Options:**

| Feature | TLS Termination | TLS Passthrough |
|---------|----------------|-----------------|
| Certificate location | nginx secret | TFE secret |
| TLS termination | nginx | TFE |
| Backend protocol | HTTP | HTTPS |
| End-to-end encryption | No | Yes |
| Certificate management | nginx + Vault | TFE + Vault |
| Complexity | Simpler | More complex |

## Accessing TFE

Once TFE is deployed and Ingress is configured:

```bash
# Add entry to /etc/hosts (on macOS/Linux)
echo "127.0.0.1 tfe.tfe.local" | sudo tee -a /etc/hosts

# Access TFE web UI
open https://tfe.tfe.local
```

## TLS Certificate Setup

### Using Vault PKI (Recommended)

The easiest way to get a TLS certificate is to use the provided script:

```bash
cd /Users/larry.song/work/hashicorp/tfe-setup/manifests/nginx
./setup-tls-cert.sh
```

This script:
- Retrieves Vault root token from `vault-keys` secret
- Issues certificate from Vault PKI intermediate CA
- Creates `tfe-tls-cert` secret with cert and key
- Certificate TTL: 90 days (2160h)

**Manual Certificate Issuance:**

See `manifests/vault/README.md` for instructions on setting up Vault PKI.

To issue certificate for TFE manually:

```bash
# Run from k8s cluster
kubectl run vault-cert-issue --rm -i --restart=Never \
  --image=hashicorp/vault:1.21.2 \
  --env="VAULT_ADDR=http://vault.vault.svc.cluster.local:8200" \
  --env="VAULT_TOKEN=$(kubectl get secret vault-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d)" \
  --context kind-tfe -- sh -c '
    apk add jq
    vault write pki_int/issue/tfe-cert \
      common_name="tfe.tfe.local" \
      ttl=2160h | jq -r ".data.certificate" > /tmp/cert.pem
    vault write pki_int/issue/tfe-cert \
      common_name="tfe.tfe.local" \
      ttl=2160h | jq -r ".data.private_key" > /tmp/key.pem
    vault read pki_int/cert/ca | jq -r ".data.certificate" > /tmp/ca.pem
  '
```

Then create the secret:

```bash
kubectl create secret tls tfe-tls-cert \
  --cert=/tmp/cert.pem \
  --key=/tmp/key.pem \
  -n tfe \
  --context kind-tfe
```

### Using Self-Signed Certificate (for testing)

```bash
# Generate self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tfe.key \
  -out tfe.crt \
  -subj "/CN=tfe.tfe.local/O=TFE"

# Create secret
kubectl create secret tls tfe-tls-cert \
  --cert=tfe.crt \
  --key=tfe.key \
  -n tfe \
  --context kind-tfe
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n ingress-nginx --context kind-tfe

# Check logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --context kind-tfe
```

### Service Not Accessible

```bash
# Check service endpoints
kubectl get endpoints -n ingress-nginx --context kind-tfe

# Check node port mappings
kubectl get svc -n ingress-nginx -o yaml --context kind-tfe

# Test from within cluster
kubectl run test-nginx --rm -it --image=busybox --context kind-tfe -- wget -qO- http://ingress-nginx-controller.ingress-nginx
```

### Ingress Not Working

```bash
# Check ingress resource
kubectl get ingress -n tfe --context kind-tfe

# Describe ingress
kubectl describe ingress -n tfe --context kind-tfe

# Check nginx configuration
kubectl exec -n ingress-nginx deployment/ingress-nginx-controller -- cat /etc/nginx/nginx.conf
```

## Port Mappings for kind

The kind cluster is configured with the following port mappings:
- Host port 80 → Container port 80 (HTTP)
- Host port 443 → Container port 443 (HTTPS)
- Host port 30443 → Container port 30443 (Additional TFE port)

These mappings are defined in `manifests/kind/cluster-config.yaml`.

## References

- nginx Ingress Controller: https://kubernetes.github.io/ingress-nginx/
- nginx Ingress Helm Chart: https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx
- TFE Kubernetes Deployment: https://developer.hashicorp.com/terraform/enterprise/deploy/kubernetes
