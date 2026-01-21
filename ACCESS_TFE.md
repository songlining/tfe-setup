# Accessing Terraform Enterprise on Kind Cluster

## Prerequisites

1. **Kind cluster running** with TFE deployed
2. **`/etc/hosts` entry** on your Mac:
   ```
   127.0.0.1 tfe.tfe.local
   ```
   Add with: `sudo sh -c 'echo "127.0.0.1 tfe.tfe.local" >> /etc/hosts'`

## Access TFE

### Step 1: Start Port Forward (requires sudo for port 443)

```bash
sudo kubectl port-forward -n tfe svc/terraform-enterprise 443:443 --context kind-tfe
```

Keep this terminal open while accessing TFE.

### Step 2: Open Browser

Navigate to: **https://tfe.tfe.local**

- Accept the self-signed certificate warning (click Advanced → Proceed)

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

## Troubleshooting

### Port already in use
```bash
sudo lsof -i :443
sudo kill <PID>
```

### Check TFE pod status
```bash
kubectl get pods -n tfe --context kind-tfe
```

### Check TFE logs
```bash
kubectl logs -n tfe deployment/terraform-enterprise --tail=50 --context kind-tfe
```

### Test TFE health (from another terminal)
```bash
curl -k https://tfe.tfe.local/_health_check
```
Should return: `OK`

## Why sudo is required

TFE is configured with `TFE_HOSTNAME=tfe.tfe.local` (without a port). When you access TFE, it redirects to `https://tfe.tfe.local/` (port 443). Using a non-standard port like 8443 causes redirect loops because TFE drops the port in redirects.

Binding to port 443 requires root privileges on macOS, hence `sudo`.
