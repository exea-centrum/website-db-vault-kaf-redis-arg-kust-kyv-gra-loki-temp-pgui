# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat - Unified GitOps Stack (Finalna Wersja)

🚀 **Kompleksowa aplikacja z pełnym stack'iem DevOps**

## 📋 KOMPONENTY (WSZYSTKIE)
- **FastAPI** (App)
- **PostgreSQL** (DB)
- **pgAdmin** (DB UI)
- **Adminer** (DB UI Alternatywa)
- **Vault** (Secrets, z POPRAWIONYM initContainerem dla read-only fix)
- **Kafka KRaft** (Messaging, bez Zookeepera)
- **Redis** (Cache)
- **Prometheus/Grafana/Loki/Tempo/Promtail** (Observability)
- **ArgoCD/Kyverno** (GitOps/Security)

## 🚀 FINALNE KROKI WDROŻENIA (KRYTYCZNE)

### 1. Generowanie i push do Git

Musisz wygenerować manifesty z **poprawną długą nazwą** i wypchnąć je do repozytorium.

```bash
# 1. Usuń stary folder, aby zresetować pliki
rm -rf manifests/ argocd-application.yaml

# 2. Uruchom skrypt
./unified-deployment.sh generate

# 3. Dodaj, commituj i push do repo (użyj nazwy website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat!)
git add .
git commit -m "Final Fix: Corrected long project name for ArgoCD, Vault initContainer applied, added Adminer component."
git push -u origin main
```

### 2. Konfiguracja ArgoCD i Czyszczenie Zasobów Kubernetes

Musisz usunąć starą, błędną aplikację ArgoCD i zaaplikować nową (a następnie wymusić reset zasobów).

```bash
# 1. USUŃ starą aplikację ArgoCD (z błędną lub starą nazwą)
kubectl delete application webstack-gitops -n argocd || true

# 2. ZASTOSUJ nową aplikację ArgoCD (z poprawną, długą nazwą)
kubectl apply -f argocd-application.yaml

# 3. KRYTYCZNE: USUŃ STARE ZASOBY (aby nowy Ingress i Vault mogły wystartować)
kubectl delete deployment -l app -n davtrowebdbvault || true
kubectl delete statefulset -l app -n davtrowebdbvault || true
kubectl delete ingress website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat -n davtrowebdbvault || true # Używa poprawnej nazwy Ingress

# USUŃ PVC (Ważne dla resetu Vault/Postgres/Kafka/Redis)
kubectl delete pvc -l app=vault -n davtrowebdbvault || true
kubectl delete pvc -l app=postgres -n davtrowebdbvault || true
kubectl delete pvc -l app=kafka -n davtrowebdbvault || true
kubectl delete pvc -l app=redis -n davtrowebdbvault || true

# 4. Wymuś pełną synchronizację w ArgoCD
argocd app sync website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat --refresh --prune
```

### 3. Weryfikacja Podów i DNS

Po synchronizacji upewnij się, że wszystkie Pody są w stanie **Running**.

```bash
kubectl get pods -n davtrowebdbvault
```

**Upewnij się, że plik /etc/hosts zawiera nowe wpisy:**

```
# Zastąp XXX.XXX.XXX.XXX adresem IP Twojego Ingress Controller'a
XXX.XXX.XXX.XXX app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
XXX.XXX.XXX.XXX pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
XXX.XXX.XXX.XXX grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
XXX.XXX.XXX.XXX adminer.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local 
```

## 🌐 Dostęp
- **Aplikacja**: http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local
- **pgAdmin**: http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin@admin.com / admin)
- **Adminer**: http://adminer.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (Server: `postgres`, User: `appuser`, Pass: `apppass`, DB: `appdb`)
- **Grafana**: http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.local (admin / admin)
