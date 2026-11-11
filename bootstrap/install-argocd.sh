#!/usr/bin/env bash
# install-argocd.sh — o ÚNICO passo manual do laboratório.
# Instala o Argo CD via Helm e aplica a root app (app-of-apps).
# Compatível com bash 3.2 (macOS). Requer: kubectl e helm.
set -eu

ARGO_CHART_VERSION="${ARGO_CHART_VERSION:-}"   # vazio = última; fixe após o 1º teste (helm search repo argo/argo-cd)
NS=argocd
DIR="$(cd "$(dirname "$0")" && pwd)"

grep -q 'REPLACE_ME' "$DIR/root-app.yaml" && {
  echo "Edite bootstrap/root-app.yaml e troque REPLACE_ME pelo seu usuário do GitHub."; exit 1; }

# O homelab JÁ tem um Argo CD instalado via Helm (release "argocd", chart 10.11.6, out/2026).
# Padrão: ADOTAR o existente e só aplicar a root app. Reinstalar/atualizar só com UPGRADE_ARGOCD=1,
# porque os values deste repo sobrescreveriam a configuração atual (domínio, TLS, SSO).
if kubectl -n "$NS" get deploy argocd-server >/dev/null 2>&1 && [ "${UPGRADE_ARGOCD:-0}" != "1" ]; then
  echo "Argo CD existente detectado: mantendo como está e aplicando só a root app."
  kubectl apply -f "$DIR/repo-envoy-oci.yaml"
  kubectl apply -f "$DIR/root-app.yaml"
  exit 0
fi

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

VERSION_FLAG=""
if [ -n "$ARGO_CHART_VERSION" ]; then VERSION_FLAG="--version $ARGO_CHART_VERSION"; fi

# shellcheck disable=SC2086
helm upgrade --install argocd argo/argo-cd -n "$NS" --create-namespace \
  -f "$DIR/argocd/values.yaml" $VERSION_FLAG --wait

kubectl apply -f "$DIR/repo-envoy-oci.yaml"
kubectl apply -f "$DIR/root-app.yaml"

echo
echo "Senha inicial do admin (troque e depois apague o secret):"
kubectl -n "$NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "Acesso local: kubectl -n $NS port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"
