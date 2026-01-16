# cd-homelab

Local Kubernetes cluster on macOS with Podman + k3d + NFS storage from Synology NAS.

## Architecture

```
macOS
└── Podman (rootful mode)
    └── k3d cluster "homelab"
        ├── 1 server + 3 agents
        ├── kubeAPI on Tailscale IP (remote access)
        ├── Ingress: ports 80/443
        └── Storage:
            ├── local-path (RWO) - default
            └── nfs-rwx (RWX) → Synology NAS
```

## Prerequisites

- macOS (Apple Silicon / Intel)
- Homebrew
- Podman (`brew install podman`)
- k3d (`brew install k3d`)
- helm (`brew install helm`)
- kubectl (`brew install kubectl`)
- Tailscale (optional, for remote access)
- NFS share from NAS (for RWX storage)

## Setup

### 1. Podman Machine

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

```bash
# Add repo
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update

# Install
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  -n kube-system \
  --set externalSnapshotter.enabled=false
```

### 7. NFS StorageClass

Edit `extras/nfs/storageclass-nfs.yaml` - set your NAS IP:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-rwx
provisioner: nfs.csi.k8s.io
parameters:
  server: 192.168.55.115      # Your NAS IP
  share: /volume1/k8s-volumes  # NFS share path
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
```

Apply:
```bash
kubectl apply -f extras/nfs/storageclass-nfs.yaml
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

### Start/Stop

```bash
# Stop cluster (preserves data)
k3d cluster stop homelab

# Start cluster
k3d cluster start homelab

# Stop Podman machine
podman machine stop

# Start Podman machine
podman machine start
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
├── k3d/
│   └── config.yaml              # k3d cluster configuration
├── extras/
│   └── nfs/
│       └── storageclass-nfs.yaml  # StorageClass for Synology NAS
├── .env                         # Environment variables (not committed)
├── .gitignore                   # Git ignore rules
├── CLAUDE.md                    # Instructions for Claude Code
└── README.md                    # This file
```

## License

MIT
