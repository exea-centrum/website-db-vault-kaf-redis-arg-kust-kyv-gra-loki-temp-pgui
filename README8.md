# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Complete Monitoring Stack

## 🛠️ Quick Start

```bash
# Generate all files
./lmarena.sh generate

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

