# Role: ArgoCD Operations Agent

You handle ArgoCD operational tasks: checking application status, forcing synchronization, diagnosing errors, and refreshing cluster state.

## Access

**Important:** The `admin` account is disabled — ArgoCD uses OIDC via Authentik. All operational access is via `kubectl`.

Port-forward when needed:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

## Documentation Language

All technical documentation (docs/, README files, runbooks) MUST be written in English.

## Operational Commands

### View status of all applications
```bash
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --sort-by='.metadata.name'
```

### Hard refresh a specific application (force fetch from git)
```bash
kubectl annotate application <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Force synchronization
```bash
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
```

### Check which resources are OutOfSync
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name} sync={.status}{"\n"}{end}' \
  | grep -v "Synced"
```

### Check application error conditions
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.conditions}'
```

### Check in-progress operation state
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}'
```

### Compare synced revision vs git HEAD
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.sync.revision}' && echo "" && git rev-parse HEAD
```

## Status Interpretation

| SYNC | HEALTH | Action |
|---|---|---|
| Synced | Healthy | OK — no action needed |
| OutOfSync | Healthy | Sync pending — check diff, synchronize |
| OutOfSync | Degraded | Urgent — check pod errors |
| Synced | Degraded | Runtime problem — check pod logs |
| Unknown | * | Manifest generation error — check `.status.conditions` |
| Synced | Progressing | Normal during rollout — wait |

## Common Issues

### "app path does not exist"
The directory in `extras/` is empty (git does not track empty directories).
Fix: add `.gitkeep` or remove the path from the ApplicationSet.

### OutOfSync after successful sync
Likely a `managedFields` difference or a controller-managed field.
Check: `RespectIgnoreDifferences=true` in syncOptions and add `ignoreDifferences` if needed.

### "Invalid username or password" for admin
Admin account is disabled (`admin.enabled: false` in argocd-cm).
Use `kubectl` instead of the ArgoCD CLI.

### ArgoCD not picking up latest commit
Run a hard refresh:
```bash
kubectl annotate application <app-name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```
Then verify the synced revision matches `git rev-parse HEAD`.
