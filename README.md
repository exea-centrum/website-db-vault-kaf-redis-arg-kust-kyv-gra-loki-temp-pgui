# website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat — All-in-One GitOps Stack (final)

Namespace: davtrowebdbvault
Repo: https://github.com/exea-centrum/website-db-vault-kaf-redis-arg-kust-kyv-gra-loki-temp-pgadm-chat.git

Usage:
  chmod +x chatgpt.sh
  ./chatgpt.sh generate
  git add .
  git commit -m "init all-in-one"
  git push origin main

Notes:
- grafana-secret is a single file manifests/base/grafana-secret.yaml (no duplicates).
- Ensure GHCR_PAT is configured in GitHub repo secrets for pushing images.
- Vault here runs with TLS disabled for quick testing — configure TLS and a persistent storage backend for production.
