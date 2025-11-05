# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Unified GitOps Stack (Zintegrowane Kafka i Tracing)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 Komponenty

### Aplikacja
- **FastAPI** - Strona osobista z ankietą. **Wysyła wiadomości do Kafka i Tracing do Tempo.**
- **PostgreSQL** - Baza danych
- **pgAdmin** - Zarządzanie bazą danych PostgreSQL
- **Adminer** - Uniwersalny panel do baz danych (PostgreSQL, MySQL, itp.)

### GitOps & Orchestracja
- **ArgoCD** - Continuous Deployment
- **Kustomize** - Zarządzanie konfiguracją
- **Kyverno** - Policy enforcement

### Bezpieczeństwo
- **Vault** - Zarządzanie sekretami

### Messaging & Cache
- **Kafka + KRaft** - Kolejka wiadomości. **Aplikacja FastAPI jest Producentem.**
- **Kafka UI** - Interfejs graficzny do zarządzania Kafką.
- **Redis** - Cache i kolejki
- **Redis Commander** - Interfejs graficzny do zarządzania Redisem.

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

### 2. Inicjalizacja i push do GitHub
```bash
git init
git add .
git commit -m "Initial commit - unified stack with Kafka and Tempo tracing"
git branch -M main
git remote add origin https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.git
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
argocd repo add https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.git

# Sprawdź czy manifesty są poprawne
kubectl kustomize manifests/base | kubectl apply --dry-run=client -f -
```

## ⚠️ Typowe problemy

### "app path does not exist"
**Przyczyna**: Manifesty nie zostały jeszcze wypushowane do repo lub ścieżka jest błędna.

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
  --from-literal=url=https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.git \
  --from-literal=password=YOUR_GITHUB_TOKEN \
  --from-literal=username=YOUR_GITHUB_USERNAME \
  -n argocd
```

## 🌐 Dostęp (Host-Based Routing)

**Wszystkie adresy wymagają ustawienia lokalnego rekordu DNS lub wpisu w /etc/hosts, kierującego na IP kontrolera Ingress.**

- **Aplikacja**: http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
- **pgAdmin**: http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (Email: admin@admin.com / Hasło: admin)
- **Adminer**: http://adminer.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (Port: 8080)
- **Kafka UI**: http://kafka-ui.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (Port: 8080)
- **Redis Commander (UI)**: http://redis-ui.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (Port: 8081, Użytkownik: admin / Hasło: admin)
- **Grafana**: http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (Użytkownik: admin / Hasło: admin)
- **Prometheus**: http://prometheus.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
- **Vault**: http://vault.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
- **Tempo**: http://tempo.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local

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
│  ┌──────────┐  ┌─────────┐    ┌──────────┐    │
│  │ Redis UI │  │Kafka UI │    │ Adminer  │    │
│  └──────────┘  └─────────┘    └──────────┘    │
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
│   ├── main.py              # FastAPI (Producent Kafka, OpenTelemetry Tracing)
│   ├── requirements.txt     # Zależności Python (+kafka-python, +opentelemetry)
│   └── templates/
│       └── index.html       # Frontend
├── manifests/
│   └── base/               # Manifesty Kubernetes (Deployment ma Env Vars dla Kafka/Tempo)
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
