# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui - Complete Monitoring Stack

## All Resources Generated:

- ✅ app-deployment
- ✅ postgres-db
- ✅ pgadmin
- ✅ vault
- ✅ redis
- ✅ kafka-kraft
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
- ✅ kyverno-policy

## Architecture

1. **Frontend**: FastAPI with survey system
2. **Queue**: Redis for message brokering
3. **Stream Processing**: Kafka for event streaming
4. **Database**: PostgreSQL for persistence
5. **Secrets**: Vault for secure configuration
6. **Monitoring**: Prometheus + Grafana + Loki + Tempo
7. **Policy**: Kyverno for security policies

## Quick Start

```bash
./unified-stack.sh generate
docker build -t ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest .
docker push ghcr.io/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui:latest
kubectl apply -k manifests/base
```

## Access Points

- App: http://app.website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgui.local
- Grafana: http://grafana-service.davtrowebdbvault.svc.cluster.local
- Prometheus: http://prometheus-service.davtrowebdbvault.svc.cluster.local
- Kafka UI: http://kafka-ui.davtrowebdbvault.svc.cluster.local:8080
- pgAdmin: http://pgadmin-service.davtrowebdbvault.svc.cluster.local

## 📊 Architecture Diagram

\`\`\`
┌─────────────────────────────────────────────────────────────────┐
│ KUBERNETES CLUSTER │
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │
│ │ INGRESS │ │ ARGOCD │ │ KYVERNO POLICY │ │
│ │ (nginx) │◄───┤ (GitOps) │────│ (Security) │ │
│ └─────────────┘ └─────────────┘ └─────────────────────┘ │
│ │ │
│ ▼ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │
│ │ FASTAPI │────│ REDIS │────│ KAFKA │ │
│ │ (App) │ │ (Queue) │ │ (Streaming) │ │
│ └─────────────┘ └─────────────┘ └─────────────────────┘ │
│ │ │ │ │
│ │ │ ▼ │
│ ▼ │ ┌─────────────┐ │
│ ┌─────────────┐ │ │ KAFKA UI │ │
│ │ POSTGRESQL │◄─────────────────────┘ │ (Monitoring)│ │
│ │ (Database) │ └─────────────┘ │
│ └─────────────┘ │
│ │ │
│ ▼ │
│ ┌─────────────┐ │
│ │ PGADMIN │ │
│ │ (Admin) │ │
│ └─────────────┘ │
│ │
├─────────────────────────────────────────────────────────────────┤
│ MONITORING STACK │
│ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │
│ │ PROMETHEUS │◄───│ GRAFANA │ │ LOKI │ │
│ │ (Metrics) │ │ (Dashboards)│ │ (Logging) │ │
│ └─────────────┘ └─────────────┘ └─────────────────────┘ │
│ ▲ │ ▲ │
│ │ │ │ │
│ ┌───────┴────────┐ │ ┌───────┴────────┐ │
│ │ Service │ │ │ PROMTAIL │ │
│ │ Discovery │ │ │ (Log Agent) │ │
│ └────────────────┘ │ └────────────────┘ │
│ │ │
│ ┌─────────────┐ │ ┌─────────────────────┐│
│ │ TEMPO │ │ │ APPLICATIONS ││
│ │ (Tracing) │ │ │ (FastAPI, Worker) ││
│ └─────────────┘ │ └─────────────────────┘│
│ ▲ │ │
│ │ │ │
│ ┌───────┴────────┐ │ │
│ │ Distributed │ │ │
│ │ Tracing │ │ │
│ └────────────────┘ │ │
│ │
├─────────────────────────────────────────────────────────────────┤
│ SECURITY │
│ │
│ ┌─────────────┐ │
│ │ VAULT │ │
│ │ (Secrets) │──────────────────────────────────────┐ │
│ └─────────────┘ │ │
│ │ │ │
│ ▼ ▼ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐ │
│ │ Database │ │ Redis │ │ Kafka │ │
│ │ Credentials │ │ Password │ │ Credentials │ │
│ └─────────────┘ └─────────────┘ └─────────────────────┘ │
│ │
└─────────────────────────────────────────────────────────────────┘

## 🔄 Data Flow

1. **User Request**:
   User → Ingress → FastAPI → Redis → Worker → Kafka → PostgreSQL

2. **Survey Processing**:
   Browser → FastAPI (/api/survey/submit) → Redis (queue) → Worker →
   Kafka (survey-topic) + PostgreSQL (survey_responses table)

3. **Contact Form**:
   Browser → FastAPI (/api/contact) → Redis (queue) → Worker →
   Kafka (survey-topic) + PostgreSQL (contact_messages table)

4. **Monitoring Flow**:
   Apps → Prometheus (metrics) → Grafana (visualization)
   Apps → Promtail (logs) → Loki (storage) → Grafana (logs UI)
   Apps → Tempo (traces) → Grafana (tracing UI)

5. **Secrets Management**:
   Apps → Vault (secrets) → Database/Redis/Kafka credentials

## 🎯 **Kluczowe powiązania**:

1. **Przepływ danych**: User → Ingress → FastAPI → Redis → Worker → Kafka → PostgreSQL
2. **Monitoring**: Wszystkie usługi → Prometheus/Loki/Tempo → Grafana
3. **Bezpieczeństwo**: Vault dostarcza sekrety do wszystkich komponentów
4. **Polityki**: Kyverno egzekwuje standardy na wszystkich Podach
5. **GitOps**: ArgoCD synchronizuje manifesty z repozytorium

## 🔄 **Relacje między komponentami**:

- **Redis** jako centralna kolejka między FastAPI a Workerem
- **Kafka** jako system przetwarzania strumieniowego
- **PostgreSQL** jako główne miejsce przechowywania danych
- **Vault** jako źródło prawdy dla sekretów
- **Prometheus** jako agregator metryk
- **Grafana** jako unified dashboard

Schemat pokazuje zarówno przepływy danych jak i zależności infrastrukturalne w czytelnej formie wizualnej!
