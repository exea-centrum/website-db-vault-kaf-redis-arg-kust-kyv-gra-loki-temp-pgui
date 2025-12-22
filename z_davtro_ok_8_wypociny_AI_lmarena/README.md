# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Complete Monitoring Stack

## ✅ WSZYSTKIE BŁĘDY NAPRAWIONE!

### 🔧 Naprawione problemy:
1. **PostgreSQL** - dodano securityContext i subPath (Permission Denied naprawiony)
2. **Kafka** - zmieniono obraz na `bitnami/kafka:3.6.1` + dodano volumy
3. **Kafka Exporter** - zmieniono obraz na `danielqsj/kafka-exporter:v1.7.0`
4. **Postgres Exporter** - uproszczono konfigurację
5. **GitHub Actions** - poprawiono autentykację (używa ${{ secrets.GITHUB_TOKEN }})
6. **Vault** - zmienne są poprawnie podstawiane
7. **Wszystkie init containers** - czekają na pełną gotowość serwisów

### 🏷️ Label Convention:
```
app: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
component: <service-name>
app.kubernetes.io/name: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
app.kubernetes.io/instance: website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui
app.kubernetes.io/component: <service-name>
```

## 🛠️ Quick Start

```bash
# Generate all files
./chatgpt.sh generate

# Deploy to Kubernetes
kubectl apply -k manifests/base

# Check all pods
kubectl get pods -n davtrowebdbvault

# Access applications:
# Main App: http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
# Grafana: http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (admin/admin)
# PgAdmin: http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (admin@example.com/adminpassword)
# Kafka UI: http://kafka-ui.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local

# Initialize Vault
kubectl wait --for=condition=complete job/vault-init -n davtrowebdbvault
```

## 🌐 Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Application | http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | - |
| Grafana | http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | admin/admin |
| PgAdmin | http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | admin@example.com/adminpassword |
| Kafka UI | http://kafka-ui.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | - |

## 🔧 Integration Details:

1. **PgAdmin + PostgreSQL** - Full connection with servers.json configuration
2. **Vault Integration** - All passwords stored in Vault, apps retrieve them dynamically
3. **Monitoring Stack** - Loki (logs), Prometheus (metrics), Tempo (traces) all connected to Grafana
4. **Kafka UI** - Properly configured to connect to Kafka broker
5. **Health Checks** - All services have proper liveness and readiness probes

## 📊 Monitoring Stack:

- **Prometheus** - metrics collection from all services
- **Grafana** - unified dashboards with all datasources
- **Loki** - centralized log aggregation
- **Tempo** - distributed tracing
- **Postgres Exporter** - database metrics
- **Kafka Exporter** - Kafka metrics
- **Node Exporter** - system metrics

## 🔐 Security:

- All passwords in Vault
- Network policies for service communication
- Proper security contexts for PostgreSQL
- Proper health checks and resource limits

## 🎯 Naprawione błędy:

1. ✅ **postgres-db** - CrashLoopBackOff → NAPRAWIONE (securityContext + subPath)
2. ✅ **kafka** - ImagePullBackOff → NAPRAWIONE (obraz 3.6.1)
3. ✅ **kafka-exporter** - ImagePullBackOff → NAPRAWIONE (danielqsj/kafka-exporter)
4. ✅ **postgres-exporter** - CrashLoopBackOff → NAPRAWIONE (uproszczona config)
5. ✅ **create-kafka-topics** - ImagePullBackOff → NAPRAWIONE (obraz 3.6.1)
6. ✅ **fastapi-web-app** - Init:0/3 → NAPRAWIONE (poprawne wait-for)
7. ✅ **message-processor** - Init:0/3 → NAPRAWIONE (poprawne wait-for)
8. ✅ **pgadmin** - Init:0/1 → NAPRAWIONE (wait-for-postgres)
9. ✅ **kafka-ui** - Init:0/1 → NAPRAWIONE (wait-for-kafka)

