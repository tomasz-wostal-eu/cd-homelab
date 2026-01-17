# cd-homelab Makefile
# Kubernetes homelab on macOS with Podman/Docker + k3d + NFS + GitOps

# Load environment variables from .env file
-include .env
export

.PHONY: help init setup clean start stop restart status \
        podman-init podman-start podman-stop podman-status podman-rm \
        docker-start docker-stop docker-status \
        cluster-create cluster-delete cluster-start cluster-stop cluster-status cluster-restart \
        kubeconfig nfs-install nfs-storageclass \
        nodes pods services pvc logs shell \
        docker-context git-init \
        argocd-install argocd-uninstall argocd-password argocd-port-forward argocd-status argocd-change-password \
        sealed-secrets-install sealed-secrets-uninstall sealed-secrets-status sealed-secrets-cert \
        sealed-secrets-backup sealed-secrets-restore \
        external-secrets-install external-secrets-uninstall external-secrets-status \
        azure-credentials-create azure-credentials-apply azure-store-apply azure-test \
        bootstrap-secrets bootstrap-all bootstrap-status

# Variables - Cluster
CLUSTER_NAME ?= homelab
K3D_CONFIG ?= k3d/config.yaml
NFS_STORAGECLASS ?= extras/nfs/storageclass-nfs.yaml
KUBECONFIG_PATH ?= ~/.config/k3d/kubeconfig-$(CLUSTER_NAME).yaml
NFS_VOLUME ?= /private/nfs/k8s-volumes

# Variables - Podman
PODMAN_CPUS ?= 6
PODMAN_MEMORY ?= 12288
PODMAN_DISK ?= 50

# Runtime detection: docker or podman (can override with RUNTIME=podman or RUNTIME=docker)
RUNTIME ?= $(shell if docker info 2>/dev/null | grep -q "Operating System: Docker Desktop"; then echo "docker"; elif podman machine list 2>/dev/null | grep -q "Currently running"; then echo "podman"; else echo "none"; fi)

# Variables - GitOps (can be overridden in .env)
ARGOCD_NAMESPACE ?= argocd
ARGOCD_PORT ?= 8080
SEALED_SECRETS_NAMESPACE ?= sealed-secrets
EXTERNAL_SECRETS_NAMESPACE ?= external-secrets

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

init-podman: podman-init docker-context ## Initialize Podman machine (first time setup)
	@echo "$(GREEN)Podman initialized. Run 'make setup' to create the cluster.$(NC)"

init-docker: ## Initialize Docker Desktop (just verify it's running)
	@echo "$(GREEN)Checking Docker Desktop...$(NC)"
	@if docker info 2>/dev/null | grep -q "Docker Desktop"; then \
		echo "$(GREEN)Docker Desktop is running.$(NC)"; \
	else \
		echo "$(RED)Docker Desktop not running. Please start it from Applications.$(NC)"; \
		exit 1; \
	fi

setup: runtime-start cluster-create kubeconfig ## Full setup: start runtime, create cluster
	@echo "$(GREEN)Setup complete! Run 'make status' to verify.$(NC)"

clean: cluster-delete ## Delete cluster (keeps runtime)
	@echo "$(YELLOW)Cluster deleted. Runtime preserved.$(NC)"

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

##@ Docker Desktop

docker-start: ## Ensure Docker Desktop is running
	@echo "$(GREEN)Checking Docker Desktop...$(NC)"
	@if docker info >/dev/null 2>&1; then \
		echo "$(GREEN)Docker Desktop is running.$(NC)"; \
	else \
		echo "$(YELLOW)Starting Docker Desktop...$(NC)"; \
		open -a Docker; \
		echo "$(YELLOW)Waiting for Docker to start (up to 60s)...$(NC)"; \
		for i in $$(seq 1 60); do \
			if docker info >/dev/null 2>&1; then \
				echo "$(GREEN)Docker Desktop started.$(NC)"; \
				break; \
			fi; \
			sleep 1; \
		done; \
	fi

docker-stop: ## Stop Docker Desktop (optional - runs in background)
	@echo "$(YELLOW)Note: Docker Desktop runs as a background app. Quit from menu bar if needed.$(NC)"

docker-status: ## Show Docker Desktop status
	@docker info 2>/dev/null | grep -E "Operating System|Server Version|CPUs|Total Memory" || echo "Docker not running"

##@ Runtime (auto-detect Docker or Podman)

runtime-start: ## Start detected runtime (Docker or Podman)
	@echo "$(GREEN)Detected runtime: $(RUNTIME)$(NC)"
	@if [ "$(RUNTIME)" = "docker" ]; then \
		$(MAKE) docker-start; \
	elif [ "$(RUNTIME)" = "podman" ]; then \
		$(MAKE) podman-start; \
	else \
		echo "$(RED)No runtime detected. Install Docker Desktop or Podman.$(NC)"; \
		exit 1; \
	fi

runtime-stop: ## Stop detected runtime
	@if [ "$(RUNTIME)" = "docker" ]; then \
		$(MAKE) docker-stop; \
	elif [ "$(RUNTIME)" = "podman" ]; then \
		$(MAKE) podman-stop; \
	fi

runtime-status: ## Show runtime status
	@echo "$(GREEN)Runtime: $(RUNTIME)$(NC)"
	@if [ "$(RUNTIME)" = "docker" ]; then \
		$(MAKE) docker-status; \
	elif [ "$(RUNTIME)" = "podman" ]; then \
		$(MAKE) podman-status; \
	else \
		echo "$(RED)No runtime detected.$(NC)"; \
	fi

##@ k3d Cluster

cluster-create: ## Create k3d cluster
	@echo "$(GREEN)Creating k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster create --config $(K3D_CONFIG)

cluster-delete: ## Delete k3d cluster
	@echo "$(RED)Deleting k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster delete $(CLUSTER_NAME) || true

cluster-start: ## Start k3d cluster
	@echo "$(GREEN)Starting k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	@k3d cluster start $(CLUSTER_NAME) || true
	@if [ "$(RUNTIME)" = "podman" ]; then \
		echo "$(GREEN)Ensuring serverlb is running (Podman workaround)...$(NC)"; \
		podman start k3d-$(CLUSTER_NAME)-serverlb 2>/dev/null || true; \
		sleep 5; \
	fi
	@echo "$(GREEN)Waiting for nodes to be ready...$(NC)"
	@kubectl wait --for=condition=Ready nodes --all --timeout=60s 2>/dev/null || \
		(echo "$(YELLOW)Some nodes not ready. Run 'make cluster-restart' if using Podman.$(NC)" && exit 1)

cluster-stop: ## Stop k3d cluster
	@echo "$(YELLOW)Stopping k3d cluster '$(CLUSTER_NAME)'...$(NC)"
	k3d cluster stop $(CLUSTER_NAME)

cluster-status: ## Show k3d cluster status
	k3d cluster list

cluster-restart: ## Full cluster recreate (Podman workaround for restart issues)
	@echo "$(YELLOW)Recreating cluster (preserves GitOps state via ArgoCD)...$(NC)"
	@if kubectl get secret -n $(SEALED_SECRETS_NAMESPACE) -l sealedsecrets.bitnami.com/sealed-secrets-key -o name 2>/dev/null | grep -q secret; then \
		echo "$(GREEN)Backing up Sealed Secrets keys...$(NC)"; \
		mkdir -p .secrets; \
		kubectl get secret -n $(SEALED_SECRETS_NAMESPACE) -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > .secrets/sealed-secrets-keys.yaml; \
	fi
	k3d cluster delete $(CLUSTER_NAME) || true
	k3d cluster create --config $(K3D_CONFIG)
	@if [ -f ".secrets/sealed-secrets-keys.yaml" ]; then \
		echo "$(GREEN)Restoring Sealed Secrets keys...$(NC)"; \
		kubectl create namespace $(SEALED_SECRETS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
		kubectl apply -f .secrets/sealed-secrets-keys.yaml; \
	fi
	@echo "$(GREEN)Cluster recreated. ArgoCD will resync automatically.$(NC)"

##@ Lifecycle

start: runtime-start cluster-start ## Start everything (runtime + cluster)
	@echo "$(GREEN)Homelab started. Runtime: $(RUNTIME)$(NC)"

stop: cluster-stop runtime-stop ## Stop everything (cluster + runtime)
	@echo "$(YELLOW)Homelab stopped.$(NC)"

restart: stop start ## Restart everything
	@echo "$(GREEN)Homelab restarted.$(NC)"

status: runtime-status cluster-status nodes ## Show full status
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

##@ ArgoCD

argocd-install: ## Install ArgoCD via Helm
	@echo "$(GREEN)Installing ArgoCD...$(NC)"
	helm repo add argo https://argoproj.github.io/argo-helm || true
	helm repo update
	kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install argocd argo/argo-cd \
		--namespace $(ARGOCD_NAMESPACE) \
		--set "server.service.type=ClusterIP" \
		--set "server.insecure=true" \
		--set "applicationSet.enabled=true" \
		--timeout 10m \
		--wait
	@echo "$(GREEN)ArgoCD installed. Run 'make argocd-password' to get admin password.$(NC)"

argocd-uninstall: ## Uninstall ArgoCD
	@echo "$(RED)Uninstalling ArgoCD...$(NC)"
	helm uninstall argocd --namespace $(ARGOCD_NAMESPACE) || true
	kubectl delete namespace $(ARGOCD_NAMESPACE) || true

argocd-password: ## Get ArgoCD admin password
	@echo "$(GREEN)ArgoCD admin password:$(NC)"
	@kubectl get secret argocd-initial-admin-secret \
		--namespace $(ARGOCD_NAMESPACE) \
		-o jsonpath="{.data.password}" | base64 -d && echo

argocd-port-forward: ## Port-forward ArgoCD UI to localhost:8080
	@echo "$(GREEN)ArgoCD UI: http://localhost:$(ARGOCD_PORT)$(NC)"
	@echo "$(YELLOW)Username: admin$(NC)"
	@echo "$(YELLOW)Run 'make argocd-password' for password$(NC)"
	kubectl port-forward svc/argocd-server -n $(ARGOCD_NAMESPACE) $(ARGOCD_PORT):443

argocd-status: ## Show ArgoCD status
	@echo "$(GREEN)ArgoCD Pods:$(NC)"
	@kubectl get pods -n $(ARGOCD_NAMESPACE)
	@echo ""
	@echo "$(GREEN)ArgoCD Services:$(NC)"
	@kubectl get svc -n $(ARGOCD_NAMESPACE)

argocd-change-password: ## Change ArgoCD admin password (from ARGOCD_ADMIN_PASSWORD in .env)
	@echo "$(GREEN)Changing ArgoCD admin password...$(NC)"
	@if [ -z "$(ARGOCD_ADMIN_PASSWORD)" ]; then \
		echo "$(RED)ERROR: ARGOCD_ADMIN_PASSWORD not set in .env$(NC)"; \
		exit 1; \
	fi
	@if ! command -v argocd &> /dev/null; then \
		echo "$(RED)ERROR: argocd CLI not installed. Install with: brew install argocd$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Starting port-forward in background...$(NC)"
	@kubectl port-forward svc/argocd-server -n $(ARGOCD_NAMESPACE) $(ARGOCD_PORT):443 &>/dev/null & \
		PF_PID=$$!; \
		sleep 2; \
		CURRENT_PASSWORD=$$(kubectl get secret argocd-initial-admin-secret -n $(ARGOCD_NAMESPACE) -o jsonpath="{.data.password}" | base64 -d); \
		echo "$(YELLOW)Logging in with current password...$(NC)"; \
		argocd login localhost:$(ARGOCD_PORT) --username admin --password "$$CURRENT_PASSWORD" --insecure; \
		echo "$(YELLOW)Setting new password from .env...$(NC)"; \
		argocd account update-password --current-password "$$CURRENT_PASSWORD" --new-password "$(ARGOCD_ADMIN_PASSWORD)"; \
		kill $$PF_PID 2>/dev/null || true; \
		echo "$(GREEN)Password changed successfully!$(NC)"

##@ Sealed Secrets

sealed-secrets-install: ## Install Sealed Secrets via Helm
	@echo "$(GREEN)Installing Sealed Secrets...$(NC)"
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets || true
	helm repo update
	kubectl create namespace $(SEALED_SECRETS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
		--namespace $(SEALED_SECRETS_NAMESPACE) \
		--set fullnameOverride=sealed-secrets
	@echo "$(GREEN)Sealed Secrets installed.$(NC)"

sealed-secrets-uninstall: ## Uninstall Sealed Secrets
	@echo "$(RED)Uninstalling Sealed Secrets...$(NC)"
	helm uninstall sealed-secrets --namespace $(SEALED_SECRETS_NAMESPACE) || true
	kubectl delete namespace $(SEALED_SECRETS_NAMESPACE) || true

sealed-secrets-status: ## Show Sealed Secrets status
	@kubectl get pods -n $(SEALED_SECRETS_NAMESPACE)

sealed-secrets-cert: ## Get Sealed Secrets public certificate
	@echo "$(GREEN)Fetching Sealed Secrets certificate...$(NC)"
	@kubeseal --fetch-cert \
		--controller-name=sealed-secrets \
		--controller-namespace=$(SEALED_SECRETS_NAMESPACE)

sealed-secrets-backup: ## Backup Sealed Secrets keys (run before cluster delete!)
	@echo "$(GREEN)Backing up Sealed Secrets keys...$(NC)"
	@mkdir -p .secrets
	@kubectl get secret -n $(SEALED_SECRETS_NAMESPACE) -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > .secrets/sealed-secrets-keys.yaml
	@echo "$(GREEN)Keys backed up to .secrets/sealed-secrets-keys.yaml$(NC)"
	@echo "$(RED)WARNING: This file contains private keys! Already in .gitignore.$(NC)"

sealed-secrets-restore: ## Restore Sealed Secrets keys (run before sealed-secrets-install)
	@if [ -f ".secrets/sealed-secrets-keys.yaml" ]; then \
		echo "$(GREEN)Restoring Sealed Secrets keys...$(NC)"; \
		kubectl create namespace $(SEALED_SECRETS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
		kubectl apply -f .secrets/sealed-secrets-keys.yaml; \
		echo "$(GREEN)Keys restored. Now run 'make sealed-secrets-install'$(NC)"; \
	else \
		echo "$(YELLOW)No backup found at .secrets/sealed-secrets-keys.yaml$(NC)"; \
	fi

##@ External Secrets

external-secrets-install: ## Install External Secrets Operator via Helm
	@echo "$(GREEN)Installing External Secrets Operator...$(NC)"
	helm repo add external-secrets https://charts.external-secrets.io || true
	helm repo update
	kubectl create namespace $(EXTERNAL_SECRETS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace $(EXTERNAL_SECRETS_NAMESPACE) \
		--set installCRDs=true \
		--set fullnameOverride=external-secrets
	@echo "$(GREEN)External Secrets Operator installed.$(NC)"

external-secrets-uninstall: ## Uninstall External Secrets Operator
	@echo "$(RED)Uninstalling External Secrets Operator...$(NC)"
	helm uninstall external-secrets --namespace $(EXTERNAL_SECRETS_NAMESPACE) || true
	kubectl delete namespace $(EXTERNAL_SECRETS_NAMESPACE) || true

external-secrets-status: ## Show External Secrets Operator status
	@kubectl get pods -n $(EXTERNAL_SECRETS_NAMESPACE)

##@ Azure Key Vault

azure-credentials-create: ## Create sealed secret for Azure Key Vault credentials
	@echo "$(GREEN)Creating Azure Key Vault credentials secret...$(NC)"
	@if [ -z "$(AZURE_CLIENT_ID)" ] || [ -z "$(AZURE_CLIENT_SECRET)" ]; then \
		echo "$(RED)ERROR: AZURE_CLIENT_ID and AZURE_CLIENT_SECRET required in .env$(NC)"; \
		exit 1; \
	fi
	@echo "Creating temporary secret..."
	@kubectl create secret generic azure-keyvault-credentials \
		--from-literal=client-id="$(AZURE_CLIENT_ID)" \
		--from-literal=client-secret="$(AZURE_CLIENT_SECRET)" \
		--namespace="$(EXTERNAL_SECRETS_NAMESPACE)" \
		--dry-run=client -o yaml > /tmp/azure-credentials.yaml
	@echo "Sealing secret..."
	@mkdir -p extras/local/external-secrets
	@kubeseal \
		--controller-name=sealed-secrets \
		--controller-namespace=$(SEALED_SECRETS_NAMESPACE) \
		--format=yaml \
		--namespace=$(EXTERNAL_SECRETS_NAMESPACE) \
		< /tmp/azure-credentials.yaml \
		> extras/local/external-secrets/azure-keyvault-credentials.yaml
	@rm -f /tmp/azure-credentials.yaml
	@echo "$(GREEN)Sealed secret created: extras/local/external-secrets/azure-keyvault-credentials.yaml$(NC)"

azure-credentials-apply: ## Apply Azure Key Vault credentials sealed secret
	@if [ ! -f "extras/local/external-secrets/azure-keyvault-credentials.yaml" ]; then \
		echo "$(RED)ERROR: Run 'make azure-credentials-create' first$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Applying Azure credentials sealed secret...$(NC)"
	kubectl apply -f extras/local/external-secrets/azure-keyvault-credentials.yaml
	@sleep 3
	@echo "$(GREEN)Verifying secret was created:$(NC)"
	@kubectl get secret azure-keyvault-credentials -n $(EXTERNAL_SECRETS_NAMESPACE)

azure-store-apply: ## Apply Azure Key Vault ClusterSecretStore
	@if [ ! -f "extras/local/external-secrets/azure-keyvault-store.yaml" ]; then \
		echo "$(RED)ERROR: extras/local/external-secrets/azure-keyvault-store.yaml not found$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Applying Azure Key Vault ClusterSecretStore...$(NC)"
	kubectl apply -f extras/local/external-secrets/azure-keyvault-store.yaml
	@echo "$(GREEN)Verifying ClusterSecretStore:$(NC)"
	@kubectl get clustersecretstore azure-keyvault-store

azure-test: ## Test Azure Key Vault connection
	@echo "$(GREEN)Testing Azure Key Vault connection...$(NC)"
	@echo ""
	@echo "ClusterSecretStore status:"
	@kubectl get clustersecretstore azure-keyvault-store -o jsonpath='{.status.conditions[*].message}' 2>/dev/null && echo "" || echo "Not found"
	@echo ""
	@echo "External Secrets Operator logs (last 10 lines):"
	@kubectl logs -n $(EXTERNAL_SECRETS_NAMESPACE) -l app.kubernetes.io/name=external-secrets --tail=10 2>/dev/null || echo "No logs"

##@ GitOps Bootstrap

bootstrap-secrets: sealed-secrets-install external-secrets-install ## Install both Sealed Secrets and External Secrets
	@echo "$(GREEN)Secrets management stack installed.$(NC)"
	@echo "$(YELLOW)Next: Create Azure credentials with 'make azure-credentials-create'$(NC)"

bootstrap-all: argocd-install bootstrap-secrets ## Full bootstrap: ArgoCD + Secrets management
	@echo "$(GREEN)Bootstrap complete!$(NC)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. make argocd-port-forward  # Access ArgoCD UI"
	@echo "  2. make argocd-password      # Get admin password"
	@echo "  3. make azure-credentials-create  # Create Azure KV credentials"
	@echo "  4. make azure-credentials-apply   # Apply credentials"
	@echo "  5. make azure-store-apply         # Apply ClusterSecretStore"

bootstrap-status: argocd-status sealed-secrets-status external-secrets-status ## Show status of all bootstrap components
