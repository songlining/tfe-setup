# MinIO S3-Compatible Storage for TFE

## Overview

MinIO provides S3-compatible object storage for Terraform Enterprise blob storage.

## Deployment

```bash
# Deploy MinIO
kubectl apply -k /Users/larry.song/work/hashicorp/tfe-setup/manifests/s3 --context kind-tfe

# Wait for deployment to be ready
kubectl wait --for=condition=available deployment/minio -n s3 --timeout=120s --context kind-tfe
```

## Service Endpoints

| Service | Endpoint | Port |
|---------|----------|------|
| S3 API | `minio.s3.svc.cluster.local` | 9000 |
| Console | `minio.s3.svc.cluster.local` | 9001 |

## Access Credentials

The credentials are stored in the Kubernetes secret `minio-credentials` in the `s3` namespace.

**Default Lab Credentials (DO NOT USE IN PRODUCTION):**

| Setting | Value |
|---------|-------|
| Access Key | `minioadmin` |
| Secret Key | `minioadmin123` |

To retrieve credentials:
```bash
kubectl get secret minio-credentials -n s3 -o jsonpath='{.data.MINIO_ROOT_USER}' --context kind-tfe | base64 -d
kubectl get secret minio-credentials -n s3 -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' --context kind-tfe | base64 -d
```

## TFE Bucket

A bucket named `tfe` has been created for Terraform Enterprise use.

## TFE Configuration

When configuring TFE Helm values, use:

```yaml
objectStorage:
  type: s3
  s3:
    endpoint: http://minio.s3.svc.cluster.local:9000
    bucket: tfe
    region: us-east-1
    accessKeyId: minioadmin
    secretAccessKey: minioadmin123
    # or use secretRef to reference the Kubernetes secret
```

## Testing S3 Operations

Test from within the cluster:

```bash
# Using MinIO client
kubectl run mc-test --rm -it --restart=Never --image=minio/mc:latest --context kind-tfe -- \
  sh -c 'mc alias set myminio http://minio.s3.svc.cluster.local:9000 minioadmin minioadmin123 && mc ls myminio'

# Using AWS CLI
kubectl run aws-test --restart=Never --image=amazon/aws-cli:latest --context kind-tfe \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin123" \
  -- --endpoint-url http://minio.s3.svc.cluster.local:9000 s3 ls
kubectl logs aws-test --context kind-tfe
kubectl delete pod aws-test --context kind-tfe
```

## Port Forwarding (Optional)

To access MinIO console locally:

```bash
kubectl port-forward svc/minio 9001:9001 -n s3 --context kind-tfe
# Then open http://localhost:9001 in your browser
```

## Files

- `secret.yaml` - MinIO root credentials
- `pvc.yaml` - Persistent volume claim for MinIO data
- `deployment.yaml` - MinIO deployment
- `service.yaml` - MinIO ClusterIP service
- `create-bucket-job.yaml` - Job to create the TFE bucket
- `test-s3-operations-job.yaml` - Job to test S3 operations
- `kustomization.yaml` - Kustomize configuration
