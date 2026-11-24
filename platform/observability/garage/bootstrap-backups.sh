#!/usr/bin/env bash
# Etapa 4: bucket e chave do Garage para os backups do CloudNativePG (plugin Barman Cloud). Idempotente,
# compatível com bash 3.2. Grava a chave no Secret garage-cnpg-backups (namespace lab-crossplane), que o
# Crossplane copia para cada ambiente. Não imprime valores.
set -eu
NS=lab-observability
G() { kubectl -n "$NS" exec garage-0 -- /garage "$@"; }

G bucket create cnpg-backups || true
G key create cnpg-backups-key >/dev/null || true
G bucket allow --read --write --owner cnpg-backups --key cnpg-backups-key
INFO=$(G key info cnpg-backups-key --show-secret)
AK=$(printf '%s\n' "$INFO" | awk -F': *' '/Key ID/ {print $2; exit}')
SK=$(printf '%s\n' "$INFO" | awk -F': *' '/Secret key/ {print $2; exit}')
kubectl -n lab-crossplane create secret generic garage-cnpg-backups \
  --from-literal=ACCESS_KEY_ID="$AK" \
  --from-literal=ACCESS_SECRET_KEY="$SK" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Garage pronto: bucket cnpg-backups e Secret garage-cnpg-backups (lab-crossplane)."
