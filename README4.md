# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat - Unified GitOps Stack (Zintegrowane Kafka KRaft i Tracing)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 Komponenty

### Aplikacja
- **FastAPI** - Strona osobista z ankietą. **Wysyła wiadomości do Kafka i Tracing do Tempo.**
- **PostgreSQL** - Baza danych
- **pgAdmin** - Zarządzanie bazą danych

### GitOps & Orchestracja
- **ArgoCD** - Continuous Deployment
- **Kustomize** - Zarządzanie konfiguracją
- **Kyverno** - Policy enforcement (Wymaga etykiety `environment: development` w każdym Podzie!)

### Bezpieczeństwo
- **Vault** - Zarządzanie sekretami (Konfiguracja naprawiona, aby działać bez `mlock`).

### Messaging & Cache
- **Kafka (KRaft)** - Kolejka wiadomości. **Usunięto Zookeepera.**
- **Redis** - Cache i kolejki

### Monitoring & Observability
- **Prometheus** - Metryki
- **Grafana** - Wizualizacja (Metryki, Logi, Ślady)
- **Loki** - Logi (Współpracuje z Promtail)
- **Tempo** - Distributed tracing. **Zbiera ślady OpenTelemetry z FastAPI.**
- **Promtail** - Agregacja logów

## ⚠️ WAŻNA INFORMACJA O NOWEJ NAZWIE

**Stara nazwa projektu była za długa, co powodowało błędy Ingress.**
Nowa, bezpieczna nazwa projektu to: `website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat`.

Oznacza to, że musisz **utworzyć nowe repozytorium** na GitHub o nazwie `website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat`.

## 🚀 Finalne Kroki Wdrożenia (KRYTYCZNE)

Musisz usunąć stare zasoby w klastrze i zsynchronizować Git z nową konfiguracją.

### 1. Generowanie i push do nowego repozytorium

```bash
# 1. Usuń stary folder, aby zresetować pliki
rm -rf manifests/ argocd-application.yaml

# 2. Uruchom skrypt (teraz z nową nazwą PROJECT)
./unified-deployment.sh generate

# 3. UTWÓRZ NOWE REPOZYTORIUM na GitHub o nazwie website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat

# 4. Inicjalizacja Git i push do nowego repo:
git init
git add .
git commit -m "Final fix: Shortened PROJECT name, implemented Kafka KRaft, and fixed all Kyverno/Vault labels."
git branch -M main
git remote add origin https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git
git push -u origin main
```

### 2. Czyszczenie starych zasobów w Kubernetes

**To jest niezbędne, aby usunąć pętle restartów (Vault) i stare definicje (Kafka/Zookeeper):**

```bash
# Usuń StatefulSety i Service, aby zresetować ich stan
kubectl delete statefulset vault postgres redis kafka -n davtrowebdbvault
kubectl delete service vault postgres redis kafka -n davtrowebdbvault
# Usuń wszelkie zasoby PVC, które mogły zostać utworzone przez stare StatefuSet'y
kubectl delete pvc -l app=vault -n davtrowebdbvault
kubectl delete pvc -l app=kafka -n davtrowebdbvault
kubectl delete pvc -l app=postgres -n davtrowebdbvault
kubectl delete pvc -l app=redis -n davtrowebdbvault

# Usuń stare zasoby ArgoCD
kubectl delete application website-db-stack -n argocd
```

### 3. Deploy i synchronizacja

```bash
# 1. Zastosuj nową Application Defintion
kubectl apply -f argocd-application.yaml

# 2. Wymuś odświeżenie i synchronizację w ArgoCD
argocd app sync website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat --refresh --prune

# 3. Zaktualizuj plik /etc/hosts na Twoim komputerze:
# (Zastąp XXX.XXX.XXX.XXX adresem IP Twojego Ingress Controller'a)
XXX.XXX.XXX.XXX app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
XXX.XXX.XXX.XXX pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
XXX.XXX.XXX.XXX grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
```

## 🌐 Dostęp

- **Aplikacja**: http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
- **pgAdmin**: http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin@admin.com / admin)
- **Grafana**: http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin / admin)
- **Vault**: Dostęp klastrowy (port 8200)

## 🏗️ Architektura
(Skrócona)
```
FastAPI ─┬─> PostgreSQL
         ├─> Kafka (KRaft)
         ├─> Tempo (Tracing)
         ├─> Prometheus (Metrics)
         └─> Grafana/Loki
```
