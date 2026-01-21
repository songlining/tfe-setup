# TFE on Kubernetes Setup

## Project Goal

The goal is to create a Terraform Enterprise instance on k8s.

kind command is used to manage clusters.  The cluster name will be "tfe".

According to the documentation (https://developer.hashicorp.com/terraform/enterprise/deploy/kubernetes) and the helm chart (https://github.com/hashicorp/terraform-enterprise-helm), there are dependencies:

- S3 compatible storage: you will find a compatible one and install it on the same k8s cluster but with a different namespace called "s3".
- Redis: install on another namespace "redis" on the same cluster
- postgresql: install on another namespace "psql" on the same cluster

Service type in the helm values.yaml will be set to "LoadBalancer", so we need a loadbalancer for the end user to access the TFE service.  Install ngix as a Network Load Balancer (NLB).

We keep the two options:
1. NLB will terminate the TLS traffic and then forward it to HTTP port of the TFE pods.
2. NLB will not terminate the TLS traffic and just forward it to the HTTPS port of the TFE pods.

To make HTTPS work, we need the TLS certificates, which will be provided by the Hashicorp Vault instance on the same k8s cluster, in the namespace "vault". So this is another dependency you need to take care of.

Make sure you will test all the building blocks before moving forward.   You will also do the final integration test to make sure the whole system works together.

One feature we need to make sure to work properly is Workload Identity (https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens).  Make sure you will have enough testing on it.  You will test it against Vault OIDC auth method.

Since this is a home lab running on Docker Desktop k8s cluster, we don't have the DNS service by default.  We need to install another dependency that is a dnsmasq server in another namespace called "dns".

So in summary, this is what we will install:
- S3 compatible storage
- Redis
- postgresql
- ngix as NLB
- dnsmasq as DNS server
- TFE service

---

## Ralph Loop Instructions

This project uses the Ralph Loop autonomous agent iteration system. Each agent iteration should follow these instructions.

### Critical Rules - READ FIRST

1. **ALWAYS read these files before starting any work:**
   - `prompt.md` (this file) - Project requirements and context
   - `progress.txt` - Learnings from previous iterations
   - `AGENTS.md` - Patterns and gotchas to follow/avoid

2. **Story completion requirements:**
   - A story is only complete when ALL acceptance criteria are met
   - Code/configuration must work without errors
   - All changes must be tested and verified
   - `prd.json` must be updated with `passes: true`
   - Learnings must be appended to `progress.txt`

3. **Never skip verification:**
   - Test each component after installation
   - Verify connectivity between services
   - Check logs for errors
   - Document any issues encountered

### Workflow for Each Iteration

1. **Read Phase**
   - Read `prompt.md`, `progress.txt`, and `AGENTS.md`
   - Understand what has been done and what patterns to follow

2. **Select Phase**
   - Find the first story in `prd.json` where `passes: false`
   - Review acceptance criteria carefully

3. **Implement Phase**
   - Create necessary YAML files, scripts, or configurations
   - Use Helm charts where appropriate
   - Follow Kubernetes best practices
   - Use proper namespaces as specified

4. **Verify Phase**
   - Test the implementation thoroughly
   - Verify all acceptance criteria are met
   - Check connectivity and functionality

5. **Update State Phase**
   - Update `prd.json`: set `passes: true` for completed story
   - Append to `progress.txt` with format:
     ```
     [ITERATION N] Story-X: Title - COMPLETE
     -------------------------------------------
     What was implemented:
     - Key changes made
     - Files created

     Learnings/Gotchas:
     - Issues encountered and solutions
     - Tips for future stories
     ```
   - Update `AGENTS.md` if new patterns or gotchas discovered

6. **Git Commit Phase (REQUIRED)**
   - Commit all changes after completing a story:
     ```bash
     git add -A && git commit -m "Complete story-X: <title>

     <brief description of changes>

     Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
     ```
   - Each story should have its own commit for easy tracking

### File Organization

Store configuration files in organized directories:
```
tfe-setup/
├── prd.json              # Story tracking
├── prompt.md             # This file
├── progress.txt          # Iteration log
├── AGENTS.md             # Knowledge base
├── ralph-claude.sh       # Orchestrator script
├── manifests/            # Kubernetes manifests
│   ├── dns/              # dnsmasq configs
│   ├── s3/               # MinIO configs
│   ├── redis/            # Redis configs
│   ├── psql/             # PostgreSQL configs
│   ├── vault/            # Vault configs
│   ├── nginx/            # nginx ingress configs
│   └── tfe/              # TFE configs
└── scripts/              # Helper scripts
```

### Namespace Reference

| Service    | Namespace |
|------------|-----------|
| dnsmasq    | dns       |
| MinIO      | s3        |
| Redis      | redis     |
| PostgreSQL | psql      |
| Vault      | vault     |
| nginx      | ingress-nginx |
| TFE        | tfe       |

### Useful Commands

```bash
# Check cluster status
kubectl cluster-info --context kind-tfe

# Check all pods across namespaces
kubectl get pods -A

# Check services
kubectl get svc -A

# View logs
kubectl logs -n <namespace> <pod-name>

# Port forward for testing
kubectl port-forward -n <namespace> svc/<service> <local>:<remote>
```

### Documentation Links

- TFE Kubernetes Deployment: https://developer.hashicorp.com/terraform/enterprise/deploy/kubernetes
- TFE Helm Chart: https://github.com/hashicorp/terraform-enterprise-helm
- Workload Identity: https://developer.hashicorp.com/terraform/enterprise/workspaces/dynamic-provider-credentials/workload-identity-tokens
- Kind: https://kind.sigs.k8s.io/
- Vault PKI: https://developer.hashicorp.com/vault/docs/secrets/pki
- Vault OIDC Auth: https://developer.hashicorp.com/vault/docs/auth/jwt