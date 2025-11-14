# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Complete Monitoring Stack

## 🚨 Fixed Issues

### 1. Vault CrashLoopBackOff
**Problem**: Vault container was crashing repeatedly
**Solution**: 
- Added development mode with proper startup command
- Added health checks (readiness and liveness probes)
- Set proper resource requests/limits

### 2. Kafka Configuration
**Problem**: Kafka wasn't starting properly
**Solution**:
- Fixed listener configuration with proper environment variables
- Added proper resource allocation
- Added health checks

### 3. pgAdmin Email Validation
**Problem**:  is not a valid email
**Solution**: Changed to 

### 4. Missing Resources
**Problem**: Kyverno policy was too restrictive
**Solution**: Changed to  mode and made policy less restrictive for development

## 📊 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    KUBERNETES CLUSTER                           │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │   INGRESS   │    │  ARGOCD     │    │   KYVERNO POLICY    │  │
│  │ (nginx)     │◄───┤ (GitOps)    │────│ (Security - Audit)  │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│          │                                                      │
│          ▼                                                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │   FASTAPI   │────│    REDIS    │────│      KAFKA          │  │
│  │   (App)     │    │  (Queue)    │    │   (Streaming)       │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│          │                            │          │              │
│          │                            │          ▼              │
│          ▼                            │  ┌─────────────┐        │
│  ┌─────────────┐                      │  │  KAFKA UI   │        │
│  │ POSTGRESQL  │◄─────────────────────┘  │ (Monitoring)│        │
│  │  (Database) │                         └─────────────┘        │
│  └─────────────┘                                                 │
│          │                                                      │
│          ▼                                                      │
│  ┌─────────────┐                                                │
│  │   PGADMIN   │                                                │
│  │   (Admin)   │                                                │
│  └─────────────┘                                                │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                      MONITORING STACK                           │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ PROMETHEUS  │◄───│   GRAFANA   │    │      LOKI           │  │
│  │ (Metrics)   │    │ (Dashboards)│    │    (Logging)        │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│          ▲                            │          ▲              │
│          │                            │          │              │
│  ┌───────┴────────┐                   │  ┌───────┴────────┐     │
│  │  Service       │                   │  │   PROMTAIL     │     │
│  │  Discovery     │                   │  │ (Log Agent)    │     │
│  └────────────────┘                   │  └────────────────┘     │
│                                       │                         │
│  ┌─────────────┐                      │  ┌─────────────────────┐│
│  │   TEMPO     │                      │  │   APPLICATIONS      ││
│  │ (Tracing)   │                      │  │ (FastAPI, Worker)   ││
│  └─────────────┘                      │  └─────────────────────┘│
│          ▲                            │                         │
│          │                            │                         │
│  ┌───────┴────────┐                   │                         │
│  │  Distributed   │                   │                         │
│  │   Tracing      │                   │                         │
│  └────────────────┘                   │                         │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                      SECURITY (DEV MODE)                        │
│                                                                 │
│  ┌─────────────┐                                                │
│  │    VAULT    │                                                │
│  │  (Secrets)  │──────────────────────────────────────┐         │
│  └─────────────┘                                      │         │
│    (Dev Mode)                                         ▼         │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ Database    │    │   Redis     │    │   Kafka             │  │
│  │ Credentials │    │  Password   │    │  Credentials        │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## All Resources Generated:
- ✅ app-deployment
- ✅ postgres-db  
- ✅ pgadmin (FIXED email)
- ✅ vault (FIXED CrashLoopBackOff)
- ✅ redis
- ✅ kafka-kraft (FIXED configuration)
- ✅ kafka-ui
- ✅ prometheus-config
- ✅ prometheus
- ✅ grafana-datasource
- ✅ grafana
- ✅ loki-config
- ✅ loki
- ✅ promtail-config
- ✅ promtail
- ✅ tempo-config
- ✅ tempo
- ✅ ingress
- ✅ kyverno-policy (FIXED to Audit mode)

## 🛠️ Quick Start

```bash
# Generate all files
./unified-stack.sh generate

# Build and push container
docker build -t ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest .
docker push ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest  

# Deploy to Kubernetes
kubectl apply -k manifests/base

# Check status - all pods should be running now
kubectl get pods -n davtrowebdbvault

# Check specific components
kubectl logs deployment/vault -n davtrowebdbvault
kubectl logs statefulset/kafka -n davtrowebdbvault
kubectl logs deployment/pgadmin -n davtrowebdbvault
```

## 🔧 Troubleshooting

If any pods are still failing:

1. **Vault**: Should now start in dev mode
2. **Kafka**: Check logs for configuration issues
3. **pgAdmin**: Email validation should pass with example.com
4. **Resources**: All components now have proper resource requests/limits

## 🌐 Access Points

| Service | URL | Purpose |
|---------|-----|---------|
| Application | http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local | Main website with survey |
| Grafana | http://grafana-service.davtrowebdbvault.svc.cluster.local | Metrics & logs dashboard |
| Prometheus | http://prometheus-service.davtrowebdbvault.svc.cluster.local | Metrics collection |
| Kafka UI | http://kafka-ui.davtrowebdbvault.svc.cluster.local:8080 | Kafka monitoring |
| pgAdmin | http://pgadmin-service.davtrowebdbvault.svc.cluster.local | Database administration |
| Vault UI | http://vault.davtrowebdbvault.svc.cluster.local:8200 | Secrets management |

## 📝 Notes

- **Vault** is running in development mode (not for production)
- **Kyverno** policy is in Audit mode for development
- All components have proper health checks and resource limits
- Survey system should work end-to-end: Web → Redis → Kafka → PostgreSQL
