#!/usr/bin/env bash
# Bootstrap do Garage (uma vez, depois do primeiro sync). Compatível com bash 3.2.
# Cria layout, buckets loki/tempo, uma chave por bucket e grava as chaves em Secrets
# (loki-s3, tempo-s3) sem imprimir os valores.
set -eu
NS=lab-observability
G() { kubectl -n "$NS" exec garage-0 -- /garage "$@"; }

if ! kubectl -n "$NS" get secret garage-secrets >/dev/null 2>&1; then
  umask 077
  kubectl -n "$NS" create secret generic garage-secrets \
    --from-literal=rpc-secret="$(openssl rand -hex 32)" \
    --from-literal=admin-token="$(openssl rand -base64 32)"
  kubectl -n "$NS" rollout restart statefulset/garage
  kubectl -n "$NS" rollout status statefulset/garage --timeout=120s
fi

NODE=$(G status | awk '/^[0-9a-f]{16}/ {print $1; exit}')
if G layout show 2>/dev/null | grep -q "No nodes"; then :; fi
G layout assign -z lab -c 10G "$NODE" || true
G layout apply --version 1 || true

for B in loki tempo; do
  G bucket create "$B" || true
  G key create "$B-key" >/dev/null || true
  G bucket allow --read --write --owner "$B" --key "$B-key"
  INFO=$(G key info "$B-key" --show-secret)
  AK=$(printf '%s\n' "$INFO" | awk -F': *' '/Key ID/ {print $2; exit}')
  SK=$(printf '%s\n' "$INFO" | awk -F': *' '/Secret key/ {print $2; exit}')
  kubectl -n "$NS" create secret generic "$B-s3" \
    --from-literal=AWS_ACCESS_KEY_ID="$AK" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$SK" \
    --dry-run=client -o yaml | kubectl apply -f -
done
echo "Garage pronto: buckets loki e tempo, Secrets loki-s3 e tempo-s3."
