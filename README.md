# cd-homelab

Local Kubernetes cluster on macOS with Podman or Docker Desktop + k3d + GitOps stack (ArgoCD, Sealed Secrets, External Secrets with Azure Key Vault).

> **Update**: Based on community feedback, the project now supports both **Podman** and **Docker Desktop** as container runtimes. The Makefile auto-detects which runtime is available.

## Architecture

```
macOS
└── Podman (rootful) or Docker Desktop
    └── k3d cluster "homelab"
        ├── 1 server + 3 agents
        ├── kubeAPI on Tailscale IP (remote access)
        ├── Ingress: ports 80/443
        ├── Storage:
        │   ├── local-path (RWO) - default
        │   └── nfs-rwx (RWX) → Synology NAS
        └── GitOps Stack:
            ├── ArgoCD (GitOps engine)
            ├── Sealed Secrets (encrypt secrets for Git)
            └── External Secrets → Azure Key Vault
```

## Prerequisites

- macOS (Apple Silicon / Intel)
- Homebrew
- **Container runtime** (choose one):
  - Podman (`brew install podman`) - open source, lightweight
  - Docker Desktop (`brew install --cask docker`) - familiar, stable
- k3d (`brew install k3d`)
- helm (`brew install helm`)
- kubectl (`brew install kubectl`)
- kubeseal (`brew install kubeseal`) - for Sealed Secrets
- Tailscale (optional, for remote access)
- NFS share from NAS (for RWX storage)
- Azure CLI (`brew install azure-cli`) - for Azure Key Vault
- Azure Key Vault with Service Principal credentials

## Setup

### 1. Container Runtime

**Option A: Docker Desktop (recommended for simplicity)**

```bash
brew install --cask docker
# Start Docker Desktop from Applications
```

**Option B: Podman**

```bash
# Initialize with NFS mount (optional)
podman machine init --cpus 6 --memory 8192 --disk-size 50 \
  --volume /private/nfs/k8s-volumes:/private/nfs/k8s-volumes

# Switch to rootful mode (required for ports 80/443)
podman machine set --rootful

# Start
podman machine start
```

### 2. Docker Context

If you have Docker Desktop installed, switch context to Podman:

```bash
docker context use default
```

Verify:
```bash
docker context list
# default * should point to unix:///var/run/docker.sock
```

### 3. Configure k3d

Edit `k3d/config.yaml` - set your Tailscale IP:

```yaml
kubeAPI:
  host: "YOUR_TAILSCALE_IP"  # tailscale ip -4
  hostPort: "6443"
```

### 4. Create Cluster

```bash
k3d cluster create --config k3d/config.yaml
```

### 5. Kubeconfig

```bash
k3d kubeconfig merge homelab --kubeconfig-switch-context
export KUBECONFIG=~/.config/k3d/kubeconfig-homelab.yaml
```

Verify:
```bash
kubectl get nodes
```

### 6. NFS CSI Driver (for RWX storage)

**Option A: GitOps with ArgoCD (recommended)**

NFS CSI driver is managed via ApplicationSet. First, apply the ArgoCD project and ApplicationSet:

```bash
# Apply ArgoCD project
kubectl apply -f bootstrap/argocd-projects/platform-storage.yaml

# Apply ApplicationSet
kubectl apply -f applicationsets/csi-driver-nfs.yaml
```

The ApplicationSet will:
- Install csi-driver-nfs Helm chart in `kube-system` namespace
- Create `nfs-rwx` StorageClass configured for Synology NAS

Configuration is in:
- `values/csi-driver-nfs/common/values.yaml` - common settings
- `values/csi-driver-nfs/local/homelab/values.yaml` - StorageClass config (NAS IP, share path)

**Option B: Manual Helm install**

```bash
# Add repo
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update

# Install
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  -n kube-system \
  --set externalSnapshotter.enabled=false

# Apply StorageClass manually
kubectl apply -f extras/nfs/storageclass-nfs.yaml
```

### 7. NFS StorageClass

StorageClass is configured in `values/csi-driver-nfs/local/homelab/values.yaml`:

```yaml
storageClasses:
  - name: nfs-rwx
    parameters:
      server: 192.168.55.115      # Your NAS IP
      share: /volume1/k8s-volumes  # NFS share path
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    mountOptions:
      - nfsvers=4.1
```

Edit the file to match your NAS configuration.

### 8. GitOps Bootstrap

**Option A: GitOps with ArgoCD ApplicationSets (recommended)**

After ArgoCD is installed, deploy the secrets management stack via ApplicationSets:

```bash
# Apply ArgoCD projects
kubectl apply -f bootstrap/argocd-projects/platform-core.yaml
kubectl apply -f bootstrap/argocd-projects/platform-storage.yaml

# Apply ApplicationSets
kubectl apply -f applicationsets/sealed-secrets.yaml
kubectl apply -f applicationsets/external-secrets.yaml
kubectl apply -f applicationsets/csi-driver-nfs.yaml
```

Configuration is managed in values files:
- `values/sealed-secrets/common/values.yaml` - common settings
- `values/sealed-secrets/local/homelab/values.yaml` - environment-specific
- `values/external-secrets/common/values.yaml` - common settings
- `values/external-secrets/local/homelab/values.yaml` - environment-specific

**Option B: Manual Helm install**

Install the complete GitOps stack with one command:

```bash
make bootstrap-all
```

Or install components individually:

```bash
# ArgoCD
make argocd-install
make argocd-password         # Get initial admin password
make argocd-change-password  # Set password from .env (ARGOCD_ADMIN_PASSWORD)
make argocd-port-forward     # UI at http://localhost:8080

# Sealed Secrets
make sealed-secrets-install

# External Secrets Operator
make external-secrets-install

# Azure Key Vault integration
make azure-credentials-create  # Creates sealed secret
make azure-credentials-apply   # Applies to cluster
make azure-store-apply         # Creates ClusterSecretStore
make azure-test                # Verify connection
```

### 9. ArgoCD Repository (SSH via Azure Key Vault)

Setup Git repository access for ArgoCD using SSH key stored in Azure Key Vault:

```bash
# 1. Generate SSH key
ssh-keygen -t ed25519 -C "argocd@cd-homelab" -f /tmp/argocd-cd-homelab -N ""

# 2. Add private key to Azure Key Vault
az keyvault secret set \
  --vault-name "kv-dt-dev-pc-001" \
  --name "argocd-cd-homelab-ssh-key" \
  --file /tmp/argocd-cd-homelab

# 3. Add public key as GitHub deploy key
gh repo deploy-key add /tmp/argocd-cd-homelab.pub \
  --repo tomasz-wostal-eu/cd-homelab \
  --title "ArgoCD cd-homelab"

# 4. Apply ExternalSecret (syncs key from Azure KV to ArgoCD)
kubectl apply -f extras/local/argocd/repo-cd-homelab.yaml

# 5. Clean up local keys
rm -f /tmp/argocd-cd-homelab /tmp/argocd-cd-homelab.pub

# 6. Verify
kubectl get externalsecret -n argocd
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository
```

## Usage

### Storage Classes

| Name | Access Mode | Use Case |
|------|-------------|----------|
| `local-path` (default) | RWO | Databases, single-pod apps |
| `nfs-rwx` | RWX | Shared storage, multi-pod apps |

Example PVC with RWX:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-rwx
  resources:
    requests:
      storage: 10Gi
```

### Cluster Access

**Local (macOS):**
```bash
export KUBECONFIG=~/.config/k3d/kubeconfig-homelab.yaml
kubectl get pods -A
```

**Remote (via Tailscale):**
```bash
# On another machine in the Tailscale network
export KUBECONFIG=/path/to/kubeconfig-homelab.yaml
kubectl get nodes
```

## Cluster Management

### After macOS Restart

The container runtime and k3d don't auto-start after reboot. Run:

```bash
make start   # Auto-detects Docker or Podman, starts cluster
```

Or manually:

```bash
# Docker Desktop
open -a Docker   # or start from Applications
k3d cluster start homelab

# Podman
podman machine start
k3d cluster start homelab
```

### Start/Stop

```bash
# Using Makefile (recommended - auto-detects runtime)
make start   # Start runtime + cluster
make stop    # Stop cluster + runtime
make status  # Show status

# Manual commands
k3d cluster stop homelab   # Stop cluster (preserves data)
k3d cluster start homelab  # Start cluster
```

### Runtime Selection

The Makefile auto-detects which runtime is available. To force a specific runtime:

```bash
RUNTIME=docker make start   # Force Docker Desktop
RUNTIME=podman make start   # Force Podman
```

### Delete

```bash
# Delete cluster
k3d cluster delete homelab

# Delete Podman machine (optional)
podman machine rm
```

## Troubleshooting

### k3d doesn't see Podman

```bash
docker context use default
docker ps  # should work
```

### Ports 80/443 - permission denied

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

### NFS mount not working

Check if NAS is reachable:
```bash
showmount -e 192.168.55.115
```

Check CSI driver logs:
```bash
kubectl -n kube-system logs -l app.kubernetes.io/instance=csi-driver-nfs
```

## Project Structure

```
.
├── applicationsets/
│   ├── csi-driver-nfs.yaml            # ApplicationSet for NFS CSI driver
│   ├── sealed-secrets.yaml            # ApplicationSet for Sealed Secrets
│   └── external-secrets.yaml          # ApplicationSet for External Secrets
├── bootstrap/
│   └── argocd-projects/
│       ├── platform-core.yaml         # ArgoCD AppProject for core (secrets)
│       └── platform-storage.yaml      # ArgoCD AppProject for storage
├── k3d/
│   └── config.yaml                    # k3d cluster configuration
├── values/
│   ├── csi-driver-nfs/
│   │   ├── common/values.yaml         # Common Helm values
│   │   └── local/homelab/values.yaml  # Environment-specific (StorageClass)
│   ├── sealed-secrets/
│   │   ├── common/values.yaml         # Common Helm values
│   │   └── local/homelab/values.yaml  # Environment-specific (resources)
│   └── external-secrets/
│       ├── common/values.yaml         # Common Helm values
│       └── local/homelab/values.yaml  # Environment-specific (resources)
├── extras/
│   ├── nfs/
│   │   └── storageclass-nfs.yaml      # StorageClass for Synology NAS (manual install)
│   └── local/
│       ├── external-secrets/
│       │   ├── azure-keyvault-store.yaml        # ClusterSecretStore
│       │   ├── azure-keyvault-credentials.yaml  # SealedSecret (generated)
│       │   └── example-external-secret.yaml     # Example ExternalSecret
│       └── argocd/
│           └── repo-cd-homelab.yaml   # ExternalSecret for Git repo SSH key
├── docs/
│   ├── 01-homelab.md              # Blog post: Kubernetes setup
│   ├── 02-gitops-secrets.md       # Blog post: GitOps & Secrets
│   └── 03-runtime-choice.md       # Blog post: Podman vs Docker Desktop
├── .env                           # Environment variables (not committed)
├── .gitignore                     # Git ignore rules
├── CLAUDE.md                      # Instructions for Claude Code
├── Makefile                       # Automation targets
└── README.md                      # This file
```

## License

MIT
