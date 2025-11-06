# 🚀 website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Unified GitOps Stack

Complete modern microservices architecture deployed using **GitOps (ArgoCD + Kustomize)**.

## 🛠️ Technology Stack

- **Application:** FastAPI (Python) with Kafka and OpenTelemetry Tracing
- **Registry:** GitHub Container Registry (ghcr.io)
- **CI/CD:** GitHub Actions (Build & Push Docker Image)
- **GitOps:** ArgoCD & Kustomize
- **Database:** PostgreSQL (StatefulSet)
- **DB Management:** pgAdmin
- **Cache/Broker:** Redis
- **Message Broker:** Apache Kafka (KRaft, Single-Node)
- **Secrets Management:** HashiCorp Vault
- **Monitoring & Observability:**
    - **Metrics:** Prometheus
    - **Logs:** Loki + Promtail
    - **Tracing:** Tempo (OpenTelemetry/OTLP)
    - **Visualization:** Grafana
- **Policy Management:** Kyverno

## 🚀 Quick Start

1. **Generate the project:**
   ```bash
   chmod +x unified-stack.sh
   ./unified-stack.sh generate
   ```

2. **Initialize Git and push:**
   ```bash
   git init
   git add .
   git commit -m 'Initial commit - unified stack with Kafka and Tempo tracing'
   git branch -M main
   git remote add origin https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.git
   git push -u origin main
   ```

3. **Deploy with ArgoCD:**
   ```bash
   kubectl apply -f argocd-application.yaml
   ```

## 🌐 Access URLs

Add to your `/etc/hosts`:
```
127.0.0.1 app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
127.0.0.1 pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
127.0.0.1 grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
127.0.0.1 prometheus.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
```

- **App:** http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
- **pgAdmin:** http://pgadmin.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (admin@webstack.local / adminpassword)
- **Grafana:** http://grafana.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local (admin / admin)
- **Prometheus:** http://prometheus.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local

## 📊 Features

- FastAPI application with Kafka integration
- Distributed tracing with Tempo
- Comprehensive monitoring with Prometheus/Grafana
- Centralized logging with Loki
- GitOps deployment with ArgoCD
- Security policies with Kyverno

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   FastAPI App   │───▶│     Kafka       │───▶│   PostgreSQL    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Tempo         │    │   Redis         │    │   pgAdmin       │
│   (Tracing)     │    │   (Cache)       │    │   (DB UI)       │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Loki          │    │   Prometheus    │    │   Grafana       │
│   (Logs)        │    │   (Metrics)     │    │   (Dashboard)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   ArgoCD (GitOps)                           │
└─────────────────────────────────────────────────────────────┘
```
