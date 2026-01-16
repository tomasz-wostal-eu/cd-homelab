# cd-homelab Makefile
# Kubernetes homelab on macOS with Podman + k3d + NFS

.PHONY: help init setup clean start stop restart status \
        podman-init podman-start podman-stop podman-status podman-rm \
        cluster-create cluster-delete cluster-start cluster-stop cluster-status \
        kubeconfig nfs-install nfs-storageclass \
        nodes pods services pvc logs shell \
        docker-context git-init

# Variables
CLUSTER_NAME ?= homelab
K3D_CONFIG ?= k3d/config.yaml
NFS_STORAGECLASS ?= extras/nfs/storageclass-nfs.yaml
KUBECONFIG_PATH ?= ~/.config/k3d/kubeconfig-$(CLUSTER_NAME).yaml
PODMAN_CPUS ?= 6
PODMAN_MEMORY ?= 12288
PODMAN_DISK ?= 50
NFS_VOLUME ?= /private/nfs/k8s-volumes

# Colors
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

# Default target
.DEFAULT_GOAL := help

##@ General

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Quick Start

init: podman-init docker-context ## Initialize Podman machine (first time setup)
	@echo "$(GREEN)Podman initialized. Run 'make setup' to create the cluster.$(NC)"

setup: podman-start cluster-create kubeconfig nfs-install nfs-storageclass ## Full setup: start Podman, create cluster, install NFS
	@echo "$(GREEN)Setup complete! Run 'make status' to verify.$(NC)"

clean: cluster-delete ## Delete cluster (keeps Podman machine)
	@echo "$(YELLOW)Cluster deleted. Podman machine preserved.$(NC)"

clean-all: cluster-delete podman-rm ## Delete everything (cluster + Podman machine)
	@echo "$(RED)All resources deleted.$(NC)"

##@ Podman Machine

podman-init: ## Initialize Podman machine (rootful + restart)
	@echo "$(GREEN)Initializing Podman machine...$(NC)"
	podman machine init \
		--cpus $(PODMAN_CPUS) \
		--memory $(PODMAN_MEMORY) \
		--disk-size $(PODMAN_DISK) \
		--volume $(NFS_VOLUME):$(NFS_VOLUME) \
		--rootful
	@echo "$(GREEN)Starting Podman machine...$(NC)"
	podman machine start
	@echo "$(GREEN)Podman machine initialized and running in rootful mode.$(NC)"

podman-start: ## Start Podman machine
	@echo "$(GREEN)Starting Podman machine...$(NC)"
	podman machine start || true

podman-stop: ## Stop Podman machine
	@echo "$(YELLOW)Stopping Podman machine...$(NC)"
	podman machine stop || true

podman-status: ## Show Podman machine status
	podman machine list

podman-rm: podman-stop ## Remove Podman machine
	@echo "$(RED)Removing Podman machine...$(NC)"
	podman machine rm -f || true

##@ k3d Cluster

cluster-create: ## Create k3d cluster
	@echo "$(GREEN)Creating k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster create --config $(K3D_CONFIG)

cluster-delete: ## Delete k3d cluster
	@echo "$(RED)Deleting k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster delete $(CLUSTER_NAME) || true

cluster-start: ## Start k3d cluster
	@echo "$(GREEN)Starting k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster start $(CLUSTER_NAME)

cluster-stop: ## Stop k3d cluster
	@echo "$(YELLOW)Stopping k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster stop $(CLUSTER_NAME)

cluster-status: ## Show k3d cluster status
	k3d cluster list

##@ Lifecycle

start: podman-start cluster-start ## Start everything (Podman + cluster)
	@echo "$(GREEN)Homelab started.$(NC)"

stop: cluster-stop podman-stop ## Stop everything (cluster + Podman)
	@echo "$(YELLOW)Homelab stopped.$(NC)"

restart: stop start ## Restart everything
	@echo "$(GREEN)Homelab restarted.$(NC)"

status: podman-status cluster-status nodes ## Show full status
	@echo ""
	@echo "$(GREEN)Kubeconfig: $(KUBECONFIG_PATH)$(NC)"

##@ Kubernetes Config

kubeconfig: ## Merge kubeconfig to ~/.kube/config
	@echo "$(GREEN)Merging kubeconfig to ~/.kube/config...$(NC)"
	k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-merge-default --kubeconfig-switch-context
	@echo "$(GREEN)Context switched to k3d-$(CLUSTER_NAME)$(NC)"

kubeconfig-show: ## Show kubeconfig path
	@echo "$(KUBECONFIG_PATH)"

##@ NFS Storage

nfs-install: ## Install NFS CSI driver via Helm
	@echo "$(GREEN)Installing NFS CSI driver...$(NC)"
	helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts || true
	helm repo update
	helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
		-n kube-system \
		--set externalSnapshotter.enabled=false
	@echo "$(GREEN)NFS CSI driver installed.$(NC)"

nfs-storageclass: ## Apply NFS StorageClass
	@echo "$(GREEN)Applying NFS StorageClass...$(NC)"
	kubectl apply -f $(NFS_STORAGECLASS)

nfs-status: ## Show NFS CSI driver status
	kubectl -n kube-system get pods -l app.kubernetes.io/instance=csi-driver-nfs

nfs-logs: ## Show NFS CSI driver logs
	kubectl -n kube-system logs -l app.kubernetes.io/instance=csi-driver-nfs --tail=50

##@ Kubernetes Resources

nodes: ## List cluster nodes
	kubectl get nodes -o wide

pods: ## List all pods
	kubectl get pods -A

services: ## List all services
	kubectl get svc -A

pvc: ## List all PersistentVolumeClaims
	kubectl get pvc -A

sc: ## List StorageClasses
	kubectl get storageclass

ingress: ## List all Ingresses
	kubectl get ingress -A

events: ## Show recent cluster events
	kubectl get events -A --sort-by='.lastTimestamp' | tail -20

##@ Debugging

logs: ## Show logs for a pod (usage: make logs POD=<pod-name> NS=<namespace>)
ifndef POD
	@echo "$(RED)Error: POD is required. Usage: make logs POD=<pod-name> NS=<namespace>$(NC)"
else
	kubectl logs -n $(or $(NS),default) $(POD) --tail=100
endif

shell: ## Open shell in a pod (usage: make shell POD=<pod-name> NS=<namespace>)
ifndef POD
	@echo "$(RED)Error: POD is required. Usage: make shell POD=<pod-name> NS=<namespace>$(NC)"
else
	kubectl exec -it -n $(or $(NS),default) $(POD) -- /bin/sh
endif

debug-pod: ## Run a debug pod with common tools
	kubectl run debug --rm -it --image=nicolaka/netshoot -- /bin/bash

top-nodes: ## Show node resource usage
	kubectl top nodes

top-pods: ## Show pod resource usage
	kubectl top pods -A

##@ Docker/Podman Context

docker-context: ## Switch Docker context to default (Podman)
	@echo "$(GREEN)Switching Docker context to default...$(NC)"
	docker context use default
	@echo ""
	docker context list

##@ Git

git-init: ## Initialize git repository
	@echo "$(GREEN)Initializing git repository...$(NC)"
	git init
	git add .
	git commit -m "Initial commit: homelab k3d setup"
	@echo "$(GREEN)Git repository initialized.$(NC)"

##@ Info

info: ## Show environment info
	@echo "Cluster Name:    $(CLUSTER_NAME)"
	@echo "K3D Config:      $(K3D_CONFIG)"
	@echo "Kubeconfig:      $(KUBECONFIG_PATH)"
	@echo "NFS StorageClass: $(NFS_STORAGECLASS)"
	@echo ""
	@echo "Podman:"
	@podman --version 2>/dev/null || echo "  Not installed"
	@echo ""
	@echo "k3d:"
	@k3d --version 2>/dev/null || echo "  Not installed"
	@echo ""
	@echo "kubectl:"
	@kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || echo "  Not installed"
	@echo ""
	@echo "helm:"
	@helm version --short 2>/dev/null || echo "  Not installed"

tailscale-ip: ## Show Tailscale IP
	@tailscale ip -4 2>/dev/null || echo "Tailscale not running"
