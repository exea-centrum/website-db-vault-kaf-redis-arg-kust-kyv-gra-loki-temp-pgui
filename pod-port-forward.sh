#!/bin/bash
echo "Uruchamianie port-forward do podów..."

# Zatrzymaj istniejące port-forward
pkill -f 'kubectl port-forward'

# Pobierz nazwy podów
APP_POD=$(kubectl get pods -n davtrowebdb -l app=website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -o jsonpath='{.items[0].metadata.name}')
ADMINER_POD=$(kubectl get pods -n davtrowebdb -l app=adminer -o jsonpath='{.items[0].metadata.name}')
GRAFANA_POD=$(kubectl get pods -n davtrowebdb -l app=grafana -o jsonpath='{.items[0].metadata.name}')
PROMETHEUS_POD=$(kubectl get pods -n davtrowebdb -l app=prometheus -o jsonpath='{.items[0].metadata.name}')
LOKI_POD=$(kubectl get pods -n davtrowebdb -l app=loki -o jsonpath='{.items[0].metadata.name}')
TEMPO_POD=$(kubectl get pods -n davtrowebdb -l app=tempo -o jsonpath='{.items[0].metadata.name}')

# Uruchom port-forward do podów
kubectl port-forward -n davtrowebdb pod/$APP_POD 8089:8000 &
kubectl port-forward -n davtrowebdb pod/$ADMINER_POD 8081:8080 &
kubectl port-forward -n davtrowebdb pod/$GRAFANA_POD 3001:3000 &
kubectl port-forward -n davtrowebdb pod/$PROMETHEUS_POD 9091:9090 &
kubectl port-forward -n davtrowebdb pod/$LOKI_POD 3101:3100 &
kubectl port-forward -n davtrowebdb pod/$TEMPO_POD 3201:3200 &

echo "Port-forward uruchomione. Aby zatrzymać: pkill -f 'kubectl port-forward'"
echo ""
echo "Dostępne aplikacje:"
echo "📊 FastAPI App: http://localhost:8088"
echo "🗄️  Adminer: http://localhost:8081"
echo "📈 Grafana: http://localhost:3001 (admin/admin)"
echo "⚡ Prometheus: http://localhost:9091"
echo "📝 Loki: http://localhost:3101"
echo "⏱️  Tempo: http://localhost:3201"