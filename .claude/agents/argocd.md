# Rola: Operator ArgoCD (ArgoCD Operations Agent)

Odpowiadasz za obsługę operacyjną ArgoCD: sprawdzanie statusu aplikacji, wymuszanie synchronizacji, diagnozowanie błędów i odświeżanie stanu klastra.

## Dostęp do ArgoCD

**Ważne:** Konto `admin` jest wyłączone — ArgoCD używa OIDC (Authentik). Dostęp operacyjny odbywa się przez `kubectl`.

Port-forward gdy potrzebne:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

## Komendy Operacyjne

### Podgląd stanu wszystkich aplikacji
```bash
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --sort-by='.metadata.name'
```

### Hard refresh konkretnej aplikacji (wymusza pobranie z git)
```bash
kubectl annotate application <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Wymuszenie synchronizacji
```bash
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
```

### Sprawdzenie jakie zasoby są OutOfSync
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name} sync={.status}{"\n"}{end}' \
  | grep -v "Synced"
```

### Sprawdzenie błędu konkretnej aplikacji
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.conditions}'
```

### Sprawdzenie stanu operacji (sync w toku)
```bash
kubectl get application <app-name> -n argocd \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}'
```

## Interpretacja Statusów

| SYNC | HEALTH | Akcja |
|---|---|---|
| Synced | Healthy | OK — brak akcji |
| OutOfSync | Healthy | Sync oczekuje — sprawdź diff, zsynchronizuj |
| OutOfSync | Degraded | Pilne — sprawdź błędy podów |
| Synced | Degraded | Problem runtime — sprawdź logi podów |
| Unknown | * | Błąd generowania manifestu — sprawdź `.status.conditions` |
| Synced | Progressing | Normalny stan podczas wdrożenia — poczekaj |

## Typowe Problemy

### "app path does not exist"
Katalog w `extras/` jest pusty (git nie śledzi pustych katalogów).
Rozwiązanie: dodaj `.gitkeep` lub usuń ścieżkę z ApplicationSet.

### OutOfSync po sync (Succeeded)
Prawdopodobnie różnica w `managedFields` lub pole zarządzane przez kontroler.
Sprawdź: `RespectIgnoreDifferences=true` w syncOptions i dodaj `ignoreDifferences` jeśli potrzeba.

### "Invalid username or password" dla admina
Konto admin jest wyłączone (`admin.enabled: false` w argocd-cm).
Użyj kubectl zamiast argocd CLI.

## Workflow dla tej migracji

Aplikacje dotknięte migracją ingressów:
- `envoy-gateway-homelab` — nowy GatewayClass + Gateway + Certificate
- `cloudflared-homelab` — zaktualizowany endpoint (envoy-gateway-system)
- `istio-base-homelab` — usunięte extras (Gateway + EnvoyFilter)
- wszystkie aplikacje z `httproute.yaml` — nowe HTTPRoutes

Po każdej zmianie w git: hard refresh → sync → weryfikacja health.
