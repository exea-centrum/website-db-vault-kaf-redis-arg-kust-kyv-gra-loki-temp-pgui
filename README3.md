# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat - Unified GitOps Stack (Zintegrowane Kafka i Tracing)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 Komponenty

### Aplikacja
- **FastAPI** - Strona osobista z ankietą. **Wysyła wiadomości do Kafka i Tracing do Tempo.**
- **PostgreSQL** - Baza danych
- **pgAdmin** - Zarządzanie bazą danych

### GitOps & Orchestracja
- **ArgoCD** - Continuous Deployment
- **Kustomize** - Zarządzanie konfiguracją
- **Kyverno** - Policy enforcement

### Bezpieczeństwo
- **Vault** - Zarządzanie sekretami

### Messaging & Cache
- **Kafka + Zookeeper** - Kolejka wiadomości. **Aplikacja FastAPI jest Producentem.**
- **Redis** - Cache i kolejki

### Monitoring & Observability (Pełny Trójkąt)
- **Prometheus** - Metryki
- **Grafana** - Wizualizacja (Metryki, Logi, Ślady)
- **Loki** - Logi (Współpracuje z Promtail)
- **Tempo** - Distributed tracing. **Zbiera ślady OpenTelemetry z FastAPI.**
- **Promtail** - Agregacja logów

## 🚀 Użycie

### 1. Generowanie manifestów
```bash
chmod +x unified-deployment.sh
./unified-deployment.sh generate
```

### 2. Inicjalizacja i push do GitHub (KRYTYCZNE dla ArgoCD)
```bash
# Upewnij się, że wszystkie pliki, w tym kafka.yaml, są dodane.
git init
git add .
git commit -m "Initial commit - unified stack with Kafka and Tempo tracing (Fixed Kustomization labels)"
git branch -M main
git remote add origin https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git
git push -u origin main
```

### 3. Weryfikacja lokalnie (opcjonalnie)
```bash
# Sprawdź czy Kustomize działa
kubectl kustomize manifests/base

# Sprawdź strukturę
tree manifests/
```

### 4. Deploy z ArgoCD
```bash
# Upewnij się że ArgoCD jest zainstalowany
kubectl get namespace argocd

# Zastosuj Application manifest
kubectl apply -f argocd-application.yaml

# Sprawdź status
kubectl get applications -n argocd
kubectl describe application website-db-stack -n argocd

# Zobacz logi sync
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### 5. Debug jeśli są problemy
```bash
# Sprawdź czy repo jest dostępne dla ArgoCD
argocd repo list

# Dodaj repo jeśli nie ma
argocd repo add https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git

# Sprawdź czy manifesty są poprawne
kubectl kustomize manifests/base | kubectl apply --dry-run=client -f -
```

## ⚠️ Typowe problemy

### "app path does not exist" lub "no such file or directory"
**Przyczyna**: Manifesty nie zostały jeszcze wypushowane do repo lub ścieżka jest błędna. **Upewnij się, że wykonałeś KROK 2.**

**Rozwiązanie**:
1. Upewnij się że zrobiłeś `git push` po generowaniu
2. Sprawdź czy folder `manifests/base/` istnieje w repo na GitHub
3. Sprawdź czy plik `manifests/base/kustomization.yaml` jest dostępny

### "Unable to generate manifests"
**Przyczyna**: Błąd w kustomization.yaml lub brakujący plik.

**Rozwiązanie**:
```bash
# Test lokalny
kubectl kustomize manifests/base

# Sprawdź czy wszystkie pliki istnieją
ls -la manifests/base/
```

### ArgoCD nie widzi repo
**Rozwiązanie**:
```bash
# Dodaj credentials dla prywatnego repo
kubectl create secret generic repo-creds \
  --from-literal=url=https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git \
  --from-literal=password=YOUR_GITHUB_TOKEN \
  --from-literal=username=YOUR_GITHUB_USERNAME \
  -n argocd
```

## 🌐 Dostęp

- **Aplikacja**: http://website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
- **pgAdmin**: http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin@admin.com / admin)
- **Grafana**: http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin / admin)
- **Vault**: http://vault.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local:8200

## 📊 Baza danych

### Tabele:
- `survey_responses` - Odpowiedzi z ankiety
- `page_visits` - Statystyki odwiedzin
- `contact_messages` - Wiadomości kontaktowe

## 🔐 Sekretna konfiguracja

### GitHub Secrets wymagane:
- `GHCR_PAT` - Personal Access Token dla GitHub Container Registry

## 📦 Namespace
`davtrowebdbvault`

## 🏗️ Architektura (Zintegrowana)

```
┌─────────────────────────────────────────────────────┐
│                    ArgoCD                           │
│              (Continuous Deployment)                │
└──────────────────┬──────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────┐
│              Kubernetes Cluster                     │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐               │
│  │   FastAPI    │  │  PostgreSQL  │               │
│  │   Website    │──│   Database   │               │
│  └──────────────┘  └──────────────┘               │
│         │ Tracing (Tempo)                           │
│         ├────────────┬─────────────┬───────────────┤
│         ▼            ▼             ▼               ▼
│  ┌──────────┐  ┌─────────┐  ┌─────────┐    ┌──────────┐
│  │  Redis   │  │  Kafka  │  │  Vault  │    │ pgAdmin  │
│  └──────────┘  └─────────┘  └─────────┘    └──────────┘
│                  ^                                  │
│                  │ Wiadomości (Survey Topic)          │
│                  │                                  │
│  ┌─────────────────────────────────────────────┐  │
│  │         Observability Stack                 │  │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────┐    │  │
│  │  │Prometheus│ │ Grafana │ │   Loki   │    │  │
│  │  └──────────┘ └─────────┘ └──────────┘    │  │
│  │  ┌──────────┐ ┌─────────┐                 │  │
│  │  │  Tempo   │ │Promtail │                 │  │
│  │  └──────────┘ └─────────┘                 │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  ┌─────────────────────────────────────────────┐  │
│  │              Kyverno Policies               │  │
│  │         (Policy Enforcement)                │  |
│  └─────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## 🛠️ Rozwój

### Struktura projektu:
```
.
├── app/
│   ├── main.py              # FastAPI (Producent Kafka, OpenTelemetry Tracing)
│   ├── requirements.txt     # Zależności Python (+kafka-python, +opentelemetry)
│   └── templates/
│       └── index.html       # Frontend
├── manifests/
│   └── base/               # Manifesty Kubernetes (Deployment ma Env Vars dla Kafka/Tempo)
│       ├── *.yaml
│       └── kustomization.yaml # POPRAWIONY: Używa 'labels' zamiast 'commonLabels'
├── .github/
│   └── workflows/
│       └── ci.yml          # GitHub Actions
├── Dockerfile
└── unified-deployment.sh   # Ten skrypt
```

## 📝 Licencja

MIT License - Dawid Trojanowski © 2025
