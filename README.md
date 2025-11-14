# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Complete Monitoring Stack

## 🚀 Now with Full Grafana Integration!

### 📊 Complete Monitoring Architecture

Grafana is now fully integrated with ALL components in the cluster:

#### 🔍 Data Sources Configuration:
- **Prometheus** - Metrics collection from all services
- **Loki** - Log aggregation from all pods
- **Tempo** - Distributed tracing
- **PostgreSQL** - Direct database connection

#### 📈 Metrics Collection:
- **FastAPI Application** - HTTP metrics, response times, error rates
- **PostgreSQL** - Database connections, query performance, locks
- **Redis** - Memory usage, connections, operations
- **Kafka** - Message rates, consumer lag, topic metrics
- **Vault** - Seal status, token usage, secret operations
- **System** - CPU, memory, disk, network (via Node Exporter)

#### 📋 Dashboards Included:
1. **FastAPI Application Metrics** - HTTP requests, response times, errors
2. **Kafka Metrics** - Message throughput, consumer lag, broker stats
3. **PostgreSQL Metrics** - Connections, queries, performance
4. **Redis Metrics** - Memory, connections, operations
5. **System Metrics** - CPU, memory, disk, network
6. **Vault Metrics** - Health, token usage, secret operations
7. **Comprehensive Monitoring** - All services in one view

#### 🔧 New Exporters Added:
- **postgres-exporter** - PostgreSQL metrics
- **kafka-exporter** - Kafka metrics
- **node-exporter** - System metrics

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

# Initialize Vault
kubectl wait --for=condition=complete job/vault-init -n davtrowebdbvault
```

## 🌐 Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Application | http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | - |
| Grafana | http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | admin/admin |
| Kafka UI | http://kafka-ui.davtrowebdbvault.svc.cluster.local:8080 | - |
| Vault UI | http://vault.davtrowebdbvault.svc.cluster.local:8200 | root token |

## 📊 Monitoring Flow

```
Application Logs → Promtail → Loki → Grafana
Application Metrics → Prometheus → Grafana
Database Metrics → Postgres Exporter → Prometheus → Grafana
Kafka Metrics → Kafka Exporter → Prometheus → Grafana
System Metrics → Node Exporter → Prometheus → Grafana
Tracing Data → Tempo → Grafana
```

## 🔍 What You Can Monitor:

### Application Level:
- HTTP request rates and latency
- Database query performance
- Redis cache hit rates
- Kafka message throughput
- Error rates and exceptions

### Infrastructure Level:
- CPU and memory usage
- Disk I/O and space
- Network traffic
- Pod resource consumption
- Cluster health

### Business Level:
- Survey response rates
- User engagement metrics
- System usage patterns
- Performance trends

## 🚀 Features

- **Real-time metrics** from all services
- **Centralized logging** with Loki
- **Distributed tracing** with Tempo
- **Custom dashboards** for each service
- **Alerting ready** configuration
- **Persistent storage** for metrics and logs
- **Auto-discovery** of new services
- **Multi-level monitoring** (app/infra/business)

## 📝 Notes

- All dashboards are pre-configured and ready to use
- Metrics are collected every 15 seconds
- Logs are collected in real-time
- All data is persisted across pod restarts
- Grafana is configured with provisioning for easy setup
