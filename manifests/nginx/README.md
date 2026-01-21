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
- `example-ingress.yaml` - Example Ingress resources for TFE
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

### Option 1: TLS Termination at nginx

In this mode:
- nginx handles TLS termination
- TFE receives unencrypted HTTP traffic
- Simpler certificate management
- nginx handles all HTTPS-related work

Setup:
1. Create TLS certificate secret
2. Apply Ingress resource with tls section
3. TFE service should expose HTTP port (80)

### Option 2: TLS Passthrough

In this mode:
- nginx forwards encrypted traffic to TFE
- TFE handles TLS termination
- End-to-end encryption
- TFE manages its own certificates

Setup:
1. Configure TCP services ConfigMap (included in example-ingress.yaml)
2. Apply Ingress resource with ssl-passthrough annotation
3. TFE service should expose HTTPS port (443)

## Accessing TFE

Once TFE is deployed and Ingress is configured:

```bash
# Add entry to /etc/hosts (on macOS/Linux)
echo "127.0.0.1 tfe.tfe.local" | sudo tee -a /etc/hosts

# Access TFE web UI
open https://tfe.tfe.local
```

## TLS Certificate Setup

### Using Vault PKI

See `manifests/vault/README.md` for instructions on setting up Vault PKI.

To issue certificate for TFE:

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
