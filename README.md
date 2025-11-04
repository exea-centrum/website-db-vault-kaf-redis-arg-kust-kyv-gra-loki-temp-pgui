# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat - Unified GitOps Stack

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 Komponenty

### Aplikacja
- **FastAPI** - Strona osobista z ankietą
- **PostgreSQL** - Baza danych
- **pgAdmin** - Zarządzanie bazą danych

### GitOps & Orchestracja
- **ArgoCD** - Continuous Deployment
- **Kustomize** - Zarządzanie konfiguracją
- **Kyverno** - Policy enforcement

### Bezpieczeństwo
- **Vault** - Zarządzanie sekretami

### Messaging & Cache
- **Kafka (KRaft)** - Kolejka wiadomości (tryb bez Zookeepera)
- **Redis** - Cache i kolejki

### Monitoring & Observability
- **Prometheus** - Metryki
- **Grafana** - Wizualizacja
- **Loki** - Logi
- **Tempo** - Distributed tracing
- **Promtail** - Agregacja logów

## 🚀 Użycie

### 1. Generowanie manifestów
```bash
chmod +x unified-deployment.sh
./unified-deployment.sh generate
```

### 2. Inicjalizacja i push do GitHub
```bash
git init
git add .
git commit -m "Initial commit - unified stack with Kafka KRaft"
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
```

## ⚠️ Typowe problemy

**Problem: Kyverno odrzuca Deployment/StatefulSet**
**Rozwiązanie**: Upewnij się, że wszystkie zasoby mają etykiety:
```yaml
metadata:
  labels:
    app: nazwa-aplikacji
    environment: development
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

## 🏗️ Architektura

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
│         │                                           │
│         ├────────────┬─────────────┬───────────────┤
│         ▼            ▼             ▼               ▼
│  ┌──────────┐  ┌─────────┐  ┌─────────┐    ┌──────────┐
│  │  Redis   │  │  Kafka  │  │  Vault  │    │ pgAdmin  │
│  └──────────┘  │ (KRaft) │  └─────────┘    └──────────┘
│                └─────────┘                     │
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
│  │         (Policy Enforcement)                │  │
│  └─────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## 🛠️ Rozwój

### Struktura projektu:
```
.
├── app/
│   ├── main.py              # FastAPI aplikacja
│   ├── requirements.txt     # Zależności Python
│   └── templates/
│       └── index.html       # Frontend
├── manifests/
│   └── base/               # Manifesty Kubernetes
│       ├── *.yaml
│       └── kustomization.yaml
├── .github/
│   └── workflows/
│       └── ci.yml          # GitHub Actions
├── Dockerfile
└── unified-deployment.sh   # Ten skrypt
```

## 📝 Licencja

MIT License - Dawid Trojanowski © 2025
