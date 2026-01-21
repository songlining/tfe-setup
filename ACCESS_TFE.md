# Accessing Terraform Enterprise on Kind Cluster

## Prerequisites

1. **Kind cluster running** with TFE deployed
2. **`/etc/hosts` entry** on your Mac:
   ```
   127.0.0.1 tfe.tfe.local
   ```
   Add with: `sudo sh -c 'echo "127.0.0.1 tfe.tfe.local" >> /etc/hosts'`

## Access TFE

With the nginx ingress controller configured with `hostNetwork: true`, TFE is directly accessible on port 443 without any port forwarding.

### Open Browser

Navigate to: **https://tfe.tfe.local**

- Accept the self-signed certificate warning (click Advanced → Proceed)

### Or Test with curl

```bash
curl -k https://tfe.tfe.local
```

## Initial Admin Setup

On first access, you need to create an admin account using an IACT (Initial Admin Creation Token).

### Get the IACT Token

```bash
kubectl exec -n tfe deployment/terraform-enterprise --context kind-tfe -- tfectl admin token
```

### Create Admin Account

Use the token in this URL:
```
https://tfe.tfe.local/admin/account/new?token=<IACT_TOKEN>
```

Or navigate to the TFE UI and enter the token when prompted.

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
