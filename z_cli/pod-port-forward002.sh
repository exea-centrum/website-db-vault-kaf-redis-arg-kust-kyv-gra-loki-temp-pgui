#!/bin/bash
echo "Uruchamianie port-forward do podów..."

# Zatrzymaj istniejące port-forward
pkill -f 'kubectl get pods -n davtrowebdb' 2>/dev/null
sleep 2

# Wspólna etykieta dla wszystkich podów
LABEL="app=website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin"

# Pobierz listę wszystkich podów
ALL_PODS=$(kubectl get pods -n davtrowebdb -l $LABEL -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Znajdź konkretne pody używając grep
FASTAPI_POD=$(echo "$ALL_PODS" | grep "website-db-" | head -1)
ADMINER_POD=$(echo "$ALL_PODS" | grep "adminer-" | head -1)
GRAFANA_POD=$(echo "$ALL_PODS" | grep "grafana-" | head -1)
PROMETHEUS_POD=$(echo "$ALL_PODS" | grep "prometheus-" | head -1)
LOKI_POD=$(echo "$ALL_PODS" | grep "loki-" | head -1)
TEMPO_POD=$(echo "$ALL_PODS" | grep "tempo-" | head -1)

echo "Znalezione pody:"
echo "FastAPI: $FASTAPI_POD"
echo "Adminer: $ADMINER_POD"
echo "Grafana: $GRAFANA_POD"
echo "Prometheus: $PROMETHEUS_POD"
echo "Loki: $LOKI_POD"
echo "Tempo: $TEMPO_POD"

# Uruchom port-forward tylko dla znalezionych podów
if [ -n "$FASTAPI_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla FastAPI: $FASTAPI_POD (8088:8000)"
  kubectl port-forward -n davtrowebdb pod/$FASTAPI_POD 8088:8000 &
  sleep 2
fi

if [ -n "$ADMINER_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla Adminer: $ADMINER_POD (8081:8080)"
  kubectl port-forward -n davtrowebdb pod/$ADMINER_POD 8081:8080 &
  sleep 2
fi

if [ -n "$GRAFANA_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla Grafana: $GRAFANA_POD (3001:3000)"
  kubectl port-forward -n davtrowebdb pod/$GRAFANA_POD 3001:3000 &
  sleep 2
fi

if [ -n "$PROMETHEUS_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla Prometheus: $PROMETHEUS_POD (9091:9090)"
  kubectl port-forward -n davtrowebdb pod/$PROMETHEUS_POD 9091:9090 &
  sleep 2
fi

if [ -n "$LOKI_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla Loki: $LOKI_POD (3101:3100)"
  kubectl port-forward -n davtrowebdb pod/$LOKI_POD 3101:3100 &
  sleep 2
fi

if [ -n "$TEMPO_POD" ]; then
  echo "🔹 Uruchamiam port-forward dla Tempo: $TEMPO_POD (3201:3200)"
  kubectl port-forward -n davtrowebdb pod/$TEMPO_POD 3201:3200 &
  sleep 2
fi

echo ""
echo "✅ Port-forward uruchomione. Aby zatrzymać: pkill -f 'kubectl port-forward'"
echo ""
echo "🌐 Dostępne aplikacje:"
[ -n "$FASTAPI_POD" ] && echo "📊 FastAPI App: http://localhost:8088"
[ -n "$ADMINER_POD" ] && echo "🗄️  Adminer: http://localhost:8081"
[ -n "$GRAFANA_POD" ] && echo "📈 Grafana: http://localhost:3001 (admin/admin)"
[ -n "$PROMETHEUS_POD" ] && echo "⚡ Prometheus: http://localhost:9091"
[ -n "$LOKI_POD" ] && echo "📝 Loki: http://localhost:3101"
[ -n "$TEMPO_POD" ] && echo "⏱️  Tempo: http://localhost:3201"
echo ""
echo "Aby przetestować:"
echo "curl http://localhost:8088/health"