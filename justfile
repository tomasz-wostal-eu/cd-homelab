# cd-homelab Justfile
# Kubernetes homelab on macOS/Linux with Docker/Podman + k3d + NFS + GitOps
#
# Runtime defaults:
#   - macOS: Docker Desktop (Podman available via VM)
#   - Linux: Podman rootful (Docker available if installed)
# Override with: RUNTIME=docker just <recipe>

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# =============================================================================
# Configuration
# =============================================================================

# OS detection (must be first for conditional config)
os := os()

# k3d config selection based on OS (can be overridden with K3D_CONFIG env var)
# macOS: k3d/config.yaml (cluster: homelab)
# Linux: k3d/config-linux.yaml (cluster: homelab-nix)
k3d_config := env_var_or_default("K3D_CONFIG", if os == "macos" { "k3d/config.yaml" } else { "k3d/config-linux.yaml" })

# Cluster configuration (derived from k3d_config)
cluster_name := if os == "macos" { `yq -r '.metadata.name' k3d/config.yaml` } else { `yq -r '.metadata.name' k3d/config-linux.yaml` }
kubeconfig_path := env_var_or_default("KUBECONFIG_PATH", "~/.config/k3d/kubeconfig-" + cluster_name + ".yaml")
nfs_storageclass := env_var_or_default("NFS_STORAGECLASS", "extras/nfs/storageclass-nfs.yaml")
nfs_volume := env_var_or_default("NFS_VOLUME", if os == "macos" { "/private/nfs/k8s-volumes" } else { "/mnt/k8s-volumes" })

# Podman VM configuration (macOS only)
podman_cpus := env_var_or_default("PODMAN_CPUS", "6")
podman_memory := env_var_or_default("PODMAN_MEMORY", "12288")
podman_disk := env_var_or_default("PODMAN_DISK", "50")

# GitOps namespaces
argocd_namespace := env_var_or_default("ARGOCD_NAMESPACE", "argocd")
argocd_port := env_var_or_default("ARGOCD_PORT", "8080")
sealed_secrets_namespace := env_var_or_default("SEALED_SECRETS_NAMESPACE", "sealed-secrets")
external_secrets_namespace := env_var_or_default("EXTERNAL_SECRETS_NAMESPACE", "external-secrets")

# Runtime detection script (use in bash recipes for dynamic detection)
# Can be overridden with RUNTIME env var
_detect_runtime_macos := 'if [[ -n "${RUNTIME:-}" ]]; then echo "$RUNTIME"; elif docker info 2>/dev/null | grep -q "Operating System: Docker Desktop"; then echo "docker"; elif podman machine list 2>/dev/null | grep -q "Currently running"; then echo "podman"; else echo "none"; fi'
_detect_runtime_linux := 'if [[ -n "${RUNTIME:-}" ]]; then echo "$RUNTIME"; elif podman info >/dev/null 2>&1; then echo "podman"; elif docker info >/dev/null 2>&1; then echo "docker"; else echo "none"; fi'
_detect_runtime := if os == "macos" { _detect_runtime_macos } else { _detect_runtime_linux }

# Static runtime hint for DOCKER_HOST/DOCKER_SOCK exports (default based on OS)
# macOS defaults to docker, Linux defaults to podman
runtime := env_var_or_default("RUNTIME", if os == "macos" { "docker" } else { "podman" })

# Podman socket detection (for k3d compatibility)
# On Linux: prefer rootful (/run/podman) over rootless (user socket)
podman_socket := if os == "macos" {
    `podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo ""`
} else {
    `if [ -S "/run/podman/podman.sock" ]; then echo "/run/podman/podman.sock"; elif [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" ]; then echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"; fi`
}

# Export DOCKER_HOST and DOCKER_SOCK for podman (k3d compatibility)
export DOCKER_HOST := if runtime == "podman" {
    if podman_socket != "" { "unix://" + podman_socket } else { "" }
} else { "" }

export DOCKER_SOCK := if runtime == "podman" { podman_socket } else { "" }

# Colors
green := '\033[0;32m'
yellow := '\033[0;33m'
red := '\033[0;31m'
nc := '\033[0m'

# =============================================================================
# Default & Help
# =============================================================================

# Show available recipes
@default:
    just --list --unsorted

# Show grouped help
[group('general')]
help:
    #!/usr/bin/env bash
    echo -e "{{green}}cd-homelab - Kubernetes Homelab Management{{nc}}"
    echo ""
    echo "Usage: just <recipe> [args]"
    echo ""
    echo -e "{{yellow}}Quick Start:{{nc}}"
    echo "  just setup              Full setup: start runtime, create cluster"
    echo "  just start              Start everything (runtime + cluster)"
    echo "  just stop               Stop everything (cluster + runtime)"
    echo "  just status             Show full status"
    echo ""
    echo -e "{{yellow}}Common Workflows:{{nc}}"
    echo "  just bootstrap-all      Install ArgoCD + Sealed Secrets + External Secrets"
    echo "  just argocd-ui          Port-forward ArgoCD UI + show password"
    echo ""
    echo "Run 'just --list' for all available recipes"

# =============================================================================
# Quick Start
# =============================================================================

# Full setup: start runtime, create cluster, configure kubeconfig
[group('quick-start')]
setup: runtime-start cluster-create kubeconfig
    @echo -e "{{green}}Setup complete! Run 'just status' to verify.{{nc}}"

# Delete cluster (keeps runtime)
[group('quick-start')]
clean: cluster-delete
    @echo -e "{{yellow}}Cluster deleted. Runtime preserved.{{nc}}"

# Delete everything (cluster + Podman machine on macOS)
[group('quick-start')]
clean-all: cluster-delete
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        just podman-rm
    fi
    echo -e "{{red}}All resources deleted.{{nc}}"

# Initialize Podman (macOS: VM setup, Linux: verify native install)
[group('quick-start')]
init-podman: podman-init
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        just docker-context
    fi
    echo -e "{{green}}Podman initialized. Run 'just setup' to create the cluster.{{nc}}"

# Initialize Docker (verify it's running)
[group('quick-start')]
init-docker:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{green}}Checking Docker Desktop (macOS)...{{nc}}"
        if docker info 2>/dev/null | grep -q "Docker Desktop"; then
            echo -e "{{green}}Docker Desktop is running.{{nc}}"
        else
            echo -e "{{red}}Docker Desktop not running. Please start it from Applications.{{nc}}"
            exit 1
        fi
    else
        echo -e "{{green}}Checking Docker daemon (Linux)...{{nc}}"
        if docker info >/dev/null 2>&1; then
            echo -e "{{green}}Docker daemon is running.{{nc}}"
        else
            echo -e "{{red}}Docker not running. Start with: sudo systemctl start docker{{nc}}"
            exit 1
        fi
    fi

# =============================================================================
# Lifecycle
# =============================================================================

# Start everything (runtime + cluster)
[group('lifecycle')]
start: runtime-start cluster-start
    #!/usr/bin/env bash
    echo -e "{{green}}Homelab started. Runtime: $({{_detect_runtime}}){{nc}}"

# Stop everything (cluster + runtime)
[group('lifecycle')]
stop: cluster-stop runtime-stop
    @echo -e "{{yellow}}Homelab stopped.{{nc}}"

# Restart everything
[group('lifecycle')]
restart: stop start
    @echo -e "{{green}}Homelab restarted.{{nc}}"

# Show full status (runtime, cluster, nodes)
[group('lifecycle')]
status: runtime-status cluster-status nodes
    @echo ""
    @echo -e "{{green}}Kubeconfig: {{kubeconfig_path}}{{nc}}"

# =============================================================================
# Runtime Management
# =============================================================================

# Start detected runtime (Docker or Podman)
[group('runtime')]
runtime-start:
    #!/usr/bin/env bash
    DETECTED=$({{_detect_runtime}})
    echo -e "{{green}}OS: {{os}} | Runtime: $DETECTED{{nc}}"
    if [[ "$DETECTED" == "docker" ]]; then
        just docker-start
    elif [[ "$DETECTED" == "podman" ]]; then
        just podman-start
    else
        if [[ "{{os}}" == "macos" ]]; then
            echo -e "{{red}}No runtime detected. Install Docker Desktop (recommended) or Podman.{{nc}}"
        else
            echo -e "{{red}}No runtime detected. Install Podman (recommended) or Docker.{{nc}}"
            echo -e "{{yellow}}For Podman: sudo dnf install podman && sudo systemctl enable --now podman.socket{{nc}}"
        fi
        exit 1
    fi

# Stop detected runtime
[group('runtime')]
runtime-stop:
    #!/usr/bin/env bash
    DETECTED=$({{_detect_runtime}})
    if [[ "$DETECTED" == "docker" ]]; then
        just docker-stop
    elif [[ "$DETECTED" == "podman" ]]; then
        just podman-stop
    fi

# Show runtime status
[group('runtime')]
runtime-status:
    #!/usr/bin/env bash
    DETECTED=$({{_detect_runtime}})
    echo -e "{{green}}OS: {{os}} | Runtime: $DETECTED{{nc}}"
    if [[ "$DETECTED" == "docker" ]]; then
        just docker-status
    elif [[ "$DETECTED" == "podman" ]]; then
        just podman-status
    else
        echo -e "{{red}}No runtime detected.{{nc}}"
    fi

# =============================================================================
# Podman (macOS: VM, Linux: native)
# =============================================================================

# Initialize Podman machine (macOS only - Linux runs native)
[group('podman')]
podman-init:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{green}}Initializing Podman machine (macOS)...{{nc}}"
        podman machine init \
            --cpus {{podman_cpus}} \
            --memory {{podman_memory}} \
            --disk-size {{podman_disk}} \
            --volume {{nfs_volume}}:{{nfs_volume}} \
            --rootful
        echo -e "{{green}}Starting Podman machine...{{nc}}"
        podman machine start
        echo -e "{{green}}Podman machine initialized and running in rootful mode.{{nc}}"
    else
        echo -e "{{green}}Linux detected - Podman runs natively (rootful mode), no machine needed.{{nc}}"
        if systemctl is-active --quiet podman.socket 2>/dev/null; then
            echo -e "{{green}}Podman socket is active.{{nc}}"
        else
            echo -e "{{yellow}}Enabling podman.socket...{{nc}}"
            sudo systemctl enable --now podman.socket || echo -e "{{red}}Failed to enable podman.socket. Run: sudo systemctl enable --now podman.socket{{nc}}"
        fi
    fi

# Start Podman (macOS: start machine, Linux: ensure socket is running)
[group('podman')]
podman-start:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{green}}Starting Podman machine...{{nc}}"
        podman machine start || true
    else
        echo -e "{{green}}Linux: Ensuring Podman socket is running (rootful mode)...{{nc}}"
        if ! systemctl is-active --quiet podman.socket 2>/dev/null; then
            sudo systemctl start podman.socket || echo -e "{{red}}Failed to start podman.socket{{nc}}"
        fi
        echo -e "{{green}}Podman socket: $(systemctl is-active podman.socket 2>/dev/null || echo 'unknown'){{nc}}"
    fi

# Stop Podman (macOS: stop machine, Linux: stop socket)
[group('podman')]
podman-stop:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{yellow}}Stopping Podman machine...{{nc}}"
        podman machine stop || true
    else
        echo -e "{{yellow}}Linux: Stopping Podman socket...{{nc}}"
        sudo systemctl stop podman.socket || true
    fi

# Show Podman status
[group('podman')]
podman-status:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        podman machine list
    else
        echo "Socket status: $(systemctl is-active podman.socket 2>/dev/null || echo 'inactive')"
        echo "Socket path:   /run/podman/podman.sock"
        echo ""
        podman info 2>/dev/null | grep -E "^  (version|rootless|cgroupVersion)" || echo "Podman not running or not installed"
    fi

# Remove Podman machine (macOS only)
[group('podman')]
podman-rm: podman-stop
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{red}}Removing Podman machine...{{nc}}"
        podman machine rm -f || true
    else
        echo -e "{{yellow}}Linux: Podman runs natively - nothing to remove.{{nc}}"
    fi

# =============================================================================
# Docker (macOS: Desktop, Linux: daemon)
# =============================================================================

# Ensure Docker is running
[group('docker')]
docker-start:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{green}}Checking Docker Desktop (macOS)...{{nc}}"
        if docker info >/dev/null 2>&1; then
            echo -e "{{green}}Docker Desktop is running.{{nc}}"
        else
            echo -e "{{yellow}}Starting Docker Desktop...{{nc}}"
            open -a Docker
            echo -e "{{yellow}}Waiting for Docker to start (up to 60s)...{{nc}}"
            for i in $(seq 1 60); do
                if docker info >/dev/null 2>&1; then
                    echo -e "{{green}}Docker Desktop started.{{nc}}"
                    break
                fi
                sleep 1
            done
        fi
    else
        echo -e "{{green}}Checking Docker daemon (Linux)...{{nc}}"
        if docker info >/dev/null 2>&1; then
            echo -e "{{green}}Docker daemon is running.{{nc}}"
        else
            echo -e "{{yellow}}Starting Docker daemon...{{nc}}"
            sudo systemctl start docker || echo -e "{{red}}Failed to start Docker. Try: sudo systemctl start docker{{nc}}"
        fi
    fi

# Stop Docker (macOS: manual, Linux: systemctl)
[group('docker')]
docker-stop:
    #!/usr/bin/env bash
    if [[ "{{os}}" == "macos" ]]; then
        echo -e "{{yellow}}Note: Docker Desktop runs as a background app. Quit from menu bar if needed.{{nc}}"
    else
        echo -e "{{yellow}}Stopping Docker daemon...{{nc}}"
        sudo systemctl stop docker || true
    fi

# Show Docker status
[group('docker')]
docker-status:
    @docker info 2>/dev/null | grep -E "Operating System|Server Version|CPUs|Total Memory" || echo "Docker not running"

# Switch Docker context to default
[group('docker')]
docker-context:
    @echo -e "{{green}}Switching Docker context to default...{{nc}}"
    docker context use default
    @echo ""
    docker context list

# =============================================================================
# k3d Cluster
# =============================================================================

# Create k3d cluster
[group('cluster')]
cluster-create:
    @echo -e "{{green}}Creating k3d cluster '{{cluster_name}}'...{{nc}}"
    k3d cluster create --config {{k3d_config}}

# Delete k3d cluster
[group('cluster')]
cluster-delete:
    @echo -e "{{red}}Deleting k3d cluster '{{cluster_name}}'...{{nc}}"
    k3d cluster delete {{cluster_name}} || true

# Start k3d cluster
[group('cluster')]
cluster-start:
    #!/usr/bin/env bash
    DETECTED=$({{_detect_runtime}})
    echo -e "{{green}}Starting k3d cluster '{{cluster_name}}'...{{nc}}"
    k3d cluster start {{cluster_name}} || true
    if [[ "$DETECTED" == "podman" ]]; then
        echo -e "{{green}}Ensuring serverlb is running (Podman workaround)...{{nc}}"
        podman start k3d-{{cluster_name}}-serverlb 2>/dev/null || true
        sleep 5
    fi
    echo -e "{{green}}Waiting for nodes to be ready...{{nc}}"
    kubectl wait --for=condition=Ready nodes --all --timeout=60s 2>/dev/null || \
        (echo -e "{{yellow}}Some nodes not ready. Run 'just cluster-restart' if using Podman.{{nc}}" && exit 1)

# Stop k3d cluster
[group('cluster')]
cluster-stop:
    @echo -e "{{yellow}}Stopping k3d cluster '{{cluster_name}}'...{{nc}}"
    k3d cluster stop {{cluster_name}}

# Show k3d cluster status
[group('cluster')]
cluster-status:
    k3d cluster list

# Full cluster recreate (preserves Sealed Secrets keys)
[group('cluster')]
cluster-restart:
    #!/usr/bin/env bash
    echo -e "{{yellow}}Recreating cluster (preserves GitOps state via ArgoCD)...{{nc}}"
    if kubectl get secret -n {{sealed_secrets_namespace}} -l sealedsecrets.bitnami.com/sealed-secrets-key -o name 2>/dev/null | grep -q secret; then
        echo -e "{{green}}Backing up Sealed Secrets keys...{{nc}}"
        mkdir -p .secrets
        kubectl get secret -n {{sealed_secrets_namespace}} -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > .secrets/sealed-secrets-keys.yaml
    fi
    k3d cluster delete {{cluster_name}} || true
    k3d cluster create --config {{k3d_config}}
    if [[ -f ".secrets/sealed-secrets-keys.yaml" ]]; then
        echo -e "{{green}}Restoring Sealed Secrets keys...{{nc}}"
        kubectl create namespace {{sealed_secrets_namespace}} --dry-run=client -o yaml | kubectl apply -f -
        kubectl apply -f .secrets/sealed-secrets-keys.yaml
    fi
    echo -e "{{green}}Cluster recreated. ArgoCD will resync automatically.{{nc}}"

# =============================================================================
# Kubernetes Configuration
# =============================================================================

# Merge kubeconfig to ~/.kube/config
[group('kubeconfig')]
kubeconfig:
    @echo -e "{{green}}Merging kubeconfig to ~/.kube/config...{{nc}}"
    k3d kubeconfig merge {{cluster_name}} --kubeconfig-merge-default --kubeconfig-switch-context
    @echo -e "{{green}}Context switched to k3d-{{cluster_name}}{{nc}}"

# Show kubeconfig path
[group('kubeconfig')]
kubeconfig-show:
    @echo "{{kubeconfig_path}}"

# =============================================================================
# NFS Storage
# =============================================================================

# Install NFS CSI driver via Helm
[group('storage')]
nfs-install:
    @echo -e "{{green}}Installing NFS CSI driver...{{nc}}"
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts || true
    helm repo update
    helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
        -n kube-system \
        --set externalSnapshotter.enabled=false
    @echo -e "{{green}}NFS CSI driver installed.{{nc}}"

# Apply NFS StorageClass
[group('storage')]
nfs-storageclass:
    @echo -e "{{green}}Applying NFS StorageClass...{{nc}}"
    kubectl apply -f {{nfs_storageclass}}

# Show NFS CSI driver status
[group('storage')]
nfs-status:
    kubectl -n kube-system get pods -l app.kubernetes.io/instance=csi-driver-nfs

# Show NFS CSI driver logs
[group('storage')]
nfs-logs:
    kubectl -n kube-system logs -l app.kubernetes.io/instance=csi-driver-nfs --tail=50

# =============================================================================
# Kubernetes Resources
# =============================================================================

# List cluster nodes
[group('k8s-resources')]
nodes:
    kubectl get nodes -o wide

# List all pods
[group('k8s-resources')]
pods:
    kubectl get pods -A

# List all services
[group('k8s-resources')]
services:
    kubectl get svc -A

# List all PersistentVolumeClaims
[group('k8s-resources')]
pvc:
    kubectl get pvc -A

# List StorageClasses
[group('k8s-resources')]
sc:
    kubectl get storageclass

# List all Ingresses
[group('k8s-resources')]
ingress:
    kubectl get ingress -A

# Show recent cluster events
[group('k8s-resources')]
events:
    kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# =============================================================================
# Debugging
# =============================================================================

# Show logs for a pod
[group('debug')]
logs pod ns="default":
    kubectl logs -n {{ns}} {{pod}} --tail=100

# Open shell in a pod
[group('debug')]
shell pod ns="default":
    kubectl exec -it -n {{ns}} {{pod}} -- /bin/sh

# Run a debug pod with common tools
[group('debug')]
debug-pod:
    kubectl run debug --rm -it --image=nicolaka/netshoot -- /bin/bash

# Show node resource usage
[group('debug')]
top-nodes:
    kubectl top nodes

# Show pod resource usage
[group('debug')]
top-pods:
    kubectl top pods -A

# Describe a resource
[group('debug')]
describe resource ns="default":
    kubectl describe -n {{ns}} {{resource}}

# Get events for a namespace
[group('debug')]
ns-events ns="default":
    kubectl get events -n {{ns}} --sort-by='.lastTimestamp'

# =============================================================================
# ArgoCD
# =============================================================================

# Install ArgoCD via Helm
[group('argocd')]
argocd-install:
    @echo -e "{{green}}Installing ArgoCD...{{nc}}"
    helm repo add argo https://argoproj.github.io/argo-helm || true
    helm repo update
    kubectl create namespace {{argocd_namespace}} --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install argocd argo/argo-cd \
        --namespace {{argocd_namespace}} \
        --set "server.service.type=ClusterIP" \
        --set "server.insecure=true" \
        --set "applicationSet.enabled=true" \
        --timeout 10m \
        --wait
    @echo -e "{{green}}ArgoCD installed. Run 'just argocd-password' to get admin password.{{nc}}"

# Uninstall ArgoCD
[group('argocd')]
argocd-uninstall:
    @echo -e "{{red}}Uninstalling ArgoCD...{{nc}}"
    helm uninstall argocd --namespace {{argocd_namespace}} || true
    kubectl delete namespace {{argocd_namespace}} || true

# Get ArgoCD admin password
[group('argocd')]
argocd-password:
    @echo -e "{{green}}ArgoCD admin password:{{nc}}"
    @kubectl get secret argocd-initial-admin-secret \
        --namespace {{argocd_namespace}} \
        -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward ArgoCD UI to localhost
[group('argocd')]
argocd-port-forward:
    @echo -e "{{green}}ArgoCD UI: http://localhost:{{argocd_port}}{{nc}}"
    @echo -e "{{yellow}}Username: admin{{nc}}"
    @echo -e "{{yellow}}Run 'just argocd-password' for password{{nc}}"
    kubectl port-forward svc/argocd-server -n {{argocd_namespace}} {{argocd_port}}:443

# Convenience: show password and start port-forward
[group('argocd')]
argocd-ui: argocd-password argocd-port-forward

# Show ArgoCD status
[group('argocd')]
argocd-status:
    @echo -e "{{green}}ArgoCD Pods:{{nc}}"
    @kubectl get pods -n {{argocd_namespace}}
    @echo ""
    @echo -e "{{green}}ArgoCD Services:{{nc}}"
    @kubectl get svc -n {{argocd_namespace}}

# Apply ArgoCD repository configuration
[group('argocd')]
argocd-repo-apply:
    #!/usr/bin/env bash
    echo -e "{{green}}Applying ArgoCD repository configuration...{{nc}}"
    if kubectl get clustersecretstore azure-keyvault-store >/dev/null 2>&1; then
        kubectl apply -f extras/local/argocd/repo-cd-homelab.yaml
        echo -e "{{green}}Repository ExternalSecret applied. Waiting for sync...{{nc}}"
        sleep 5
        kubectl get externalsecret -n {{argocd_namespace}}
    else
        echo -e "{{red}}ERROR: ClusterSecretStore 'azure-keyvault-store' not found.{{nc}}"
        echo -e "{{yellow}}Run 'just azure-store-apply' first.{{nc}}"
        exit 1
    fi

# Show ArgoCD repository status
[group('argocd')]
argocd-repo-status:
    @echo -e "{{green}}ArgoCD Repositories:{{nc}}"
    @kubectl get secret -n {{argocd_namespace}} -l argocd.argoproj.io/secret-type=repository
    @echo ""
    @echo -e "{{green}}ExternalSecrets:{{nc}}"
    @kubectl get externalsecret -n {{argocd_namespace}} 2>/dev/null || echo "No ExternalSecrets"

# Change ArgoCD admin password (uses ARGOCD_ADMIN_PASSWORD from .env)
[group('argocd')]
argocd-change-password:
    #!/usr/bin/env bash
    echo -e "{{green}}Changing ArgoCD admin password...{{nc}}"
    if [[ -z "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
        echo -e "{{red}}ERROR: ARGOCD_ADMIN_PASSWORD not set in .env{{nc}}"
        exit 1
    fi
    if ! command -v argocd &> /dev/null; then
        echo -e "{{red}}ERROR: argocd CLI not installed. Install with: brew install argocd{{nc}}"
        exit 1
    fi
    echo -e "{{yellow}}Starting port-forward in background...{{nc}}"
    kubectl port-forward svc/argocd-server -n {{argocd_namespace}} {{argocd_port}}:443 &>/dev/null &
    PF_PID=$!
    sleep 2
    CURRENT_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n {{argocd_namespace}} -o jsonpath="{.data.password}" | base64 -d)
    echo -e "{{yellow}}Logging in with current password...{{nc}}"
    argocd login localhost:{{argocd_port}} --username admin --password "$CURRENT_PASSWORD" --insecure
    echo -e "{{yellow}}Setting new password from .env...{{nc}}"
    argocd account update-password --current-password "$CURRENT_PASSWORD" --new-password "$ARGOCD_ADMIN_PASSWORD"
    kill $PF_PID 2>/dev/null || true
    echo -e "{{green}}Password changed successfully!{{nc}}"

# =============================================================================
# Sealed Secrets
# =============================================================================

# Install Sealed Secrets via Helm
[group('sealed-secrets')]
sealed-secrets-install:
    @echo -e "{{green}}Installing Sealed Secrets...{{nc}}"
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets || true
    helm repo update
    kubectl create namespace {{sealed_secrets_namespace}} --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
        --namespace {{sealed_secrets_namespace}} \
        --set fullnameOverride=sealed-secrets
    @echo -e "{{green}}Sealed Secrets installed.{{nc}}"

# Uninstall Sealed Secrets
[group('sealed-secrets')]
sealed-secrets-uninstall:
    @echo -e "{{red}}Uninstalling Sealed Secrets...{{nc}}"
    helm uninstall sealed-secrets --namespace {{sealed_secrets_namespace}} || true
    kubectl delete namespace {{sealed_secrets_namespace}} || true

# Show Sealed Secrets status
[group('sealed-secrets')]
sealed-secrets-status:
    @kubectl get pods -n {{sealed_secrets_namespace}}

# Get Sealed Secrets public certificate
[group('sealed-secrets')]
sealed-secrets-cert:
    @echo -e "{{green}}Fetching Sealed Secrets certificate...{{nc}}"
    @kubeseal --fetch-cert \
        --controller-name=sealed-secrets \
        --controller-namespace={{sealed_secrets_namespace}}

# Backup Sealed Secrets keys
[group('sealed-secrets')]
sealed-secrets-backup:
    @echo -e "{{green}}Backing up Sealed Secrets keys...{{nc}}"
    @mkdir -p .secrets
    @kubectl get secret -n {{sealed_secrets_namespace}} -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > .secrets/sealed-secrets-keys.yaml
    @echo -e "{{green}}Keys backed up to .secrets/sealed-secrets-keys.yaml{{nc}}"
    @echo -e "{{red}}WARNING: This file contains private keys! Already in .gitignore.{{nc}}"

# Restore Sealed Secrets keys
[group('sealed-secrets')]
sealed-secrets-restore:
    #!/usr/bin/env bash
    if [[ -f ".secrets/sealed-secrets-keys.yaml" ]]; then
        echo -e "{{green}}Restoring Sealed Secrets keys...{{nc}}"
        kubectl create namespace {{sealed_secrets_namespace}} --dry-run=client -o yaml | kubectl apply -f -
        kubectl apply -f .secrets/sealed-secrets-keys.yaml
        echo -e "{{green}}Keys restored. Now run 'just sealed-secrets-install'{{nc}}"
    else
        echo -e "{{yellow}}No backup found at .secrets/sealed-secrets-keys.yaml{{nc}}"
    fi

# =============================================================================
# External Secrets
# =============================================================================

# Install External Secrets Operator via Helm
[group('external-secrets')]
external-secrets-install:
    @echo -e "{{green}}Installing External Secrets Operator...{{nc}}"
    helm repo add external-secrets https://charts.external-secrets.io || true
    helm repo update
    kubectl create namespace {{external_secrets_namespace}} --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace {{external_secrets_namespace}} \
        --set installCRDs=true \
        --set fullnameOverride=external-secrets
    @echo -e "{{green}}External Secrets Operator installed.{{nc}}"

# Uninstall External Secrets Operator
[group('external-secrets')]
external-secrets-uninstall:
    @echo -e "{{red}}Uninstalling External Secrets Operator...{{nc}}"
    helm uninstall external-secrets --namespace {{external_secrets_namespace}} || true
    kubectl delete namespace {{external_secrets_namespace}} || true

# Show External Secrets Operator status
[group('external-secrets')]
external-secrets-status:
    @kubectl get pods -n {{external_secrets_namespace}}

# =============================================================================
# Azure Key Vault
# =============================================================================

# Create sealed secret for Azure Key Vault credentials
[group('azure')]
azure-credentials-create:
    #!/usr/bin/env bash
    echo -e "{{green}}Creating Azure Key Vault credentials secret...{{nc}}"
    if [[ -z "${AZURE_CLIENT_ID:-}" ]] || [[ -z "${AZURE_CLIENT_SECRET:-}" ]]; then
        echo -e "{{red}}ERROR: AZURE_CLIENT_ID and AZURE_CLIENT_SECRET required in .env{{nc}}"
        exit 1
    fi
    echo "Creating temporary secret..."
    kubectl create secret generic azure-keyvault-credentials \
        --from-literal=client-id="$AZURE_CLIENT_ID" \
        --from-literal=client-secret="$AZURE_CLIENT_SECRET" \
        --namespace="{{external_secrets_namespace}}" \
        --dry-run=client -o yaml > /tmp/azure-credentials.yaml
    echo "Sealing secret..."
    mkdir -p extras/local/external-secrets
    kubeseal \
        --controller-name=sealed-secrets \
        --controller-namespace={{sealed_secrets_namespace}} \
        --format=yaml \
        --namespace={{external_secrets_namespace}} \
        < /tmp/azure-credentials.yaml \
        > extras/local/external-secrets/azure-keyvault-credentials.yaml
    rm -f /tmp/azure-credentials.yaml
    echo -e "{{green}}Sealed secret created: extras/local/external-secrets/azure-keyvault-credentials.yaml{{nc}}"

# Apply Azure Key Vault credentials sealed secret
[group('azure')]
azure-credentials-apply:
    #!/usr/bin/env bash
    if [[ ! -f "extras/local/external-secrets/azure-keyvault-credentials.yaml" ]]; then
        echo -e "{{red}}ERROR: Run 'just azure-credentials-create' first{{nc}}"
        exit 1
    fi
    echo -e "{{green}}Applying Azure credentials sealed secret...{{nc}}"
    kubectl apply -f extras/local/external-secrets/azure-keyvault-credentials.yaml
    sleep 3
    echo -e "{{green}}Verifying secret was created:{{nc}}"
    kubectl get secret azure-keyvault-credentials -n {{external_secrets_namespace}}

# Apply Azure Key Vault ClusterSecretStore
[group('azure')]
azure-store-apply:
    #!/usr/bin/env bash
    if [[ ! -f "extras/local/external-secrets/azure-keyvault-store.yaml" ]]; then
        echo -e "{{red}}ERROR: extras/local/external-secrets/azure-keyvault-store.yaml not found{{nc}}"
        exit 1
    fi
    echo -e "{{green}}Applying Azure Key Vault ClusterSecretStore...{{nc}}"
    kubectl apply -f extras/local/external-secrets/azure-keyvault-store.yaml
    echo -e "{{green}}Verifying ClusterSecretStore:{{nc}}"
    kubectl get clustersecretstore azure-keyvault-store

# Test Azure Key Vault connection
[group('azure')]
azure-test:
    @echo -e "{{green}}Testing Azure Key Vault connection...{{nc}}"
    @echo ""
    @echo "ClusterSecretStore status:"
    @kubectl get clustersecretstore azure-keyvault-store -o jsonpath='{.status.conditions[*].message}' 2>/dev/null && echo "" || echo "Not found"
    @echo ""
    @echo "External Secrets Operator logs (last 10 lines):"
    @kubectl logs -n {{external_secrets_namespace}} -l app.kubernetes.io/name=external-secrets --tail=10 2>/dev/null || echo "No logs"

# =============================================================================
# GitOps Bootstrap
# =============================================================================

# Install both Sealed Secrets and External Secrets
[group('bootstrap')]
bootstrap-secrets: sealed-secrets-install external-secrets-install
    @echo -e "{{green}}Secrets management stack installed.{{nc}}"
    @echo -e "{{yellow}}Next: Create Azure credentials with 'just azure-credentials-create'{{nc}}"

# Apply App of Apps (root application that manages all ApplicationSets)
[group('bootstrap')]
bootstrap-apps:
    #!/usr/bin/env bash
    echo -e "{{green}}Applying App of Apps...{{nc}}"
    kubectl apply -f bootstrap/argocd-projects.yaml
    kubectl apply -f bootstrap/root-app.yaml
    echo -e "{{green}}Root application applied. ArgoCD will now manage all ApplicationSets.{{nc}}"
    echo -e "{{yellow}}Note: ArgoCD ApplicationSet will take over managing ArgoCD itself.{{nc}}"

# Full bootstrap: ArgoCD + Secrets management + App of Apps
[group('bootstrap')]
bootstrap-all: argocd-install bootstrap-secrets bootstrap-apps
    #!/usr/bin/env bash
    echo -e "{{green}}Bootstrap complete!{{nc}}"
    echo ""
    echo "Next steps:"
    echo "  1. just argocd-password           # Get admin password"
    echo "  2. just azure-credentials-create  # Create Azure KV credentials"
    echo "  3. just azure-credentials-apply   # Apply credentials"
    echo "  4. just azure-store-apply         # Apply ClusterSecretStore"
    echo "  5. just argocd-repo-apply         # Configure Git repository"
    echo ""
    echo "ArgoCD will be available at: https://argocd-homelab.tailc90e09.ts.net"

# Show status of all bootstrap components
[group('bootstrap')]
bootstrap-status: argocd-status sealed-secrets-status external-secrets-status argocd-repo-status

# =============================================================================
# Info & Utilities
# =============================================================================

# Show environment info
[group('info')]
info:
    #!/usr/bin/env bash
    echo "OS:               {{os}}"
    echo "Runtime:          $({{_detect_runtime}})"
    echo "Cluster Name:     {{cluster_name}}"
    echo "K3D Config:       {{k3d_config}}"
    echo "Kubeconfig:       {{kubeconfig_path}}"
    echo "NFS StorageClass: {{nfs_storageclass}}"
    echo ""
    echo "Podman:"
    podman --version 2>/dev/null || echo "  Not installed"
    echo ""
    echo "Docker:"
    docker --version 2>/dev/null || echo "  Not installed"
    echo ""
    echo "k3d:"
    k3d --version 2>/dev/null || echo "  Not installed"
    echo ""
    echo "kubectl:"
    kubectl version --client 2>/dev/null || echo "  Not installed"
    echo ""
    echo "helm:"
    helm version --short 2>/dev/null || echo "  Not installed"

# Show Tailscale IP
[group('info')]
tailscale-ip:
    @tailscale ip -4 2>/dev/null || echo "Tailscale not running"

# Initialize git repository
[group('info')]
git-init:
    @echo -e "{{green}}Initializing git repository...{{nc}}"
    git init
    git add .
    git commit -m "Initial commit: homelab k3d setup"
    @echo -e "{{green}}Git repository initialized.{{nc}}"
