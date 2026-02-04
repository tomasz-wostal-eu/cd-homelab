# cd-homelab

Local Kubernetes cluster on macOS/Linux with full GitOps stack:
- **Service Mesh**: Istio Ambient (no sidecars, L4 mTLS via ztunnel)
- **Gateway API**: Envoy Gateway for ingress
- **Secrets**: Sealed Secrets + External Secrets → Azure Key Vault
- **TLS**: cert-manager with self-signed Homelab CA
- **Applications**: EMQX MQTT broker with TLS

## Architecture

```
macOS/Linux
└── Podman (rootful) or Docker Desktop
    └── k3d cluster "homelab"
        ├── 1 server + 3 agents
        ├── kubeAPI on Tailscale IP (remote access)
        │
        ├── Platform Core
        │   ├── ArgoCD (GitOps engine)
        │   ├── cert-manager + Homelab CA
        │   ├── Sealed Secrets
        │   └── External Secrets → Azure Key Vault
        │
        ├── Platform Networking
        │   ├── Istio Ambient (base, cni, istiod, ztunnel)
        │   └── Envoy Gateway (Gateway API)
        │
        ├── Platform Storage
        │   ├── local-path (RWO) - default
        │   └── NFS CSI → Synology NAS (RWX)
        │
        └── Applications
            └── EMQX (MQTT broker)
                └── Exposed via Gateway API (TCP/TLS/HTTP)
```

## Prerequisites

- macOS (Apple Silicon / Intel) or Linux
- **Container runtime** (choose one):
  - Docker Desktop (`brew install --cask docker`) - recommended for macOS
  - Podman (`brew install podman`) - recommended for Linux
- [just](https://github.com/casey/just) (`brew install just`) - command runner
- k3d (`brew install k3d`)
- helm (`brew install helm`)
- kubectl (`brew install kubectl`)
- kubeseal (`brew install kubeseal`) - for Sealed Secrets
- yq (`brew install yq`) - YAML processor
- Tailscale (optional, for remote access)
- Azure Key Vault with Service Principal (for External Secrets)

## Quick Start

```bash
# 1. Clone repository
git clone git@github.com:tomasz-wostal-eu/cd-homelab.git
cd cd-homelab

# 2. Configure Tailscale IP (optional)
# Edit k3d/config.yaml (macOS) or k3d/config-linux.yaml (Linux)
# Set kubeAPI.host to your Tailscale IP

# 3. Full setup (auto-detects runtime)
just setup

# 4. Bootstrap GitOps stack
just bootstrap-all

# 5. Deploy platform components
kubectl apply -f bootstrap/argocd-projects/
kubectl apply -f applicationsets/
```

## Common Commands

```bash
# Lifecycle
just setup              # Full setup: runtime + cluster + kubeconfig
just start              # Start runtime + cluster
just stop               # Stop everything
just status             # Show status
just info               # Show environment info

# Cluster management
just cluster-restart    # Recreate cluster (preserves Sealed Secrets keys)
just cluster-delete     # Delete cluster

# GitOps
just argocd-ui          # Port-forward + show password
just argocd-password    # Get admin password

# Force specific runtime
RUNTIME=docker just start
RUNTIME=podman just start
```

## Deployment Order

ApplicationSets use `sync-wave` annotations:

| Wave | Component | Namespace |
|------|-----------|-----------|
| -2 | cert-manager | cert-manager |
| -2 | sealed-secrets | sealed-secrets |
| -1 | external-secrets | external-secrets |
| -1 | istio-base | istio-system |
| 0 | istio-cni | istio-system |
| 1 | istiod | istio-system |
| 2 | ztunnel | istio-system |
| 3 | envoy-gateway | envoy-gateway-system |
| 1 | emqx | emqx |

## EMQX MQTT Broker

EMQX is exposed via Envoy Gateway with multiple protocols:

| Port | Protocol | Description |
|------|----------|-------------|
| 1883 | TCP | Plain MQTT |
| 8883 | TLS | MQTT over TLS |
| 8083 | TCP | MQTT over WebSocket |
| 8084 | TLS | WebSocket Secure |
| 18083 | HTTPS | Dashboard |

### Connecting to MQTT

```bash
# Get Gateway external IP
GATEWAY_IP=$(kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

# Export Homelab CA certificate
kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt

# Test plain MQTT
mosquitto_pub -h $GATEWAY_IP -p 1883 -t test -m "hello"

# Test MQTTS (TLS)
mosquitto_pub -h $GATEWAY_IP -p 8883 --cafile homelab-ca.crt -t test -m "hello TLS"

# Dashboard
open https://$GATEWAY_IP:18083
# Default: admin / changeme123
```

### TLS Certificate Configuration

Edit `extras/local/emqx/certificate.yaml` to add your IPs:

```yaml
ipAddresses:
  - 127.0.0.1
  - 100.x.x.x    # Your Tailscale IP
  - 192.168.x.x  # Your local network IP
```

## Project Structure

```
applicationsets/               # ArgoCD ApplicationSets
  ├── cert-manager.yaml
  ├── sealed-secrets.yaml
  ├── external-secrets.yaml
  ├── istio-base.yaml
  ├── istio-cni.yaml
  ├── istiod.yaml
  ├── ztunnel.yaml
  ├── envoy-gateway.yaml
  └── emqx.yaml

bootstrap/argocd-projects/     # ArgoCD AppProjects
  ├── platform-core.yaml
  ├── platform-networking.yaml
  ├── platform-storage.yaml
  └── apps.yaml

values/{component}/            # Helm values
  ├── common/values.yaml
  └── local/homelab/values.yaml

extras/local/                  # Additional K8s resources
  ├── cert-manager/
  │   └── homelab-ca.yaml      # Self-signed CA
  ├── emqx/
  │   ├── gateway.yaml         # Gateway API resources
  │   ├── routes.yaml          # TCP/TLS/HTTP routes
  │   └── certificate.yaml     # TLS certificate
  └── external-secrets/
      └── azure-keyvault-*.yaml

k3d/
  ├── config.yaml              # macOS (cluster: homelab)
  └── config-linux.yaml        # Linux (cluster: homelab-nix)

justfile                       # All automation recipes
```

## Storage Classes

| Name | Access Mode | Backend |
|------|-------------|---------|
| `local-path` (default) | RWO | Local storage |
| `nfs-rwx` | RWX | Synology NAS via NFS CSI |

## Cluster Management

### After Reboot

```bash
just start   # Auto-detects runtime, starts cluster
```

### Remote Access (via Tailscale)

```bash
# On another machine in the Tailscale network
export KUBECONFIG=/path/to/kubeconfig-homelab.yaml
kubectl get nodes
```

## Troubleshooting

### k3d doesn't see runtime

```bash
# Docker Desktop
docker context use default
docker ps

# Podman (macOS)
podman machine start
```

### Ports 80/443 - permission denied

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

### Certificate issues

```bash
# Check cert-manager
kubectl get certificates -A
kubectl describe certificate emqx-tls -n emqx

# Check ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer homelab-ca-issuer
```

### Istio not working

```bash
# Check Istio components
kubectl get pods -n istio-system

# Check if namespace is labeled for ambient
kubectl label namespace emqx istio.io/dataplane-mode=ambient
```

## License

MIT
