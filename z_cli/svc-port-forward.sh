#!/bin/bash
echo "Uruchamianie wszystkich port-forward..."

# Uruchom każde polecenie w tle
kubectl port-forward -n davtrowebdb service/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin 8080:80 &
kubectl port-forward -n davtrowebdb service/adminer 8081:8080 &
kubectl port-forward -n davtrowebdb service/grafana 3000:3000 &
kubectl port-forward -n davtrowebdb service/prometheus 9090:9090 &
kubectl port-forward -n davtrowebdb service/loki 3100:3100 &
kubectl port-forward -n davtrowebdb service/tempo 3200:3200 &

echo "Port-forward uruchomione. Aby zatrzymać: pkill -f 'kubectl port-forward'"
echo ""
echo "Dostępne aplikacje:"
echo "📊 FastAPI App: http://localhost:8080"
echo "🗄️  Adminer: http://localhost:8081"
echo "📈 Grafana: http://localhost:3000 (admin/admin)"
echo "⚡ Prometheus: http://localhost:9090"
echo "📝 Loki: http://localhost:3100"
echo "⏱️  Tempo: http://localhost:3200"