#!/usr/bin/env bash
# preflight.sh — diagnóstico SOMENTE LEITURA do cluster antes da Fase 0.
# Compatível com bash 3.2 (macOS). Requer: kubectl com contexto do homelab.
# Uso: ./scripts/preflight.sh [contexto]
set -u

CTX="${1:-}"
K="kubectl"
if [ -n "$CTX" ]; then K="kubectl --context $CTX"; fi

hr() { printf '\n==== %s ====\n' "$1"; }

hr "Contexto atual"
$K config current-context 2>/dev/null || { echo "ERRO: kubectl sem contexto"; exit 1; }

hr "Versões (cliente, servidor e nós)"
$K version 2>/dev/null | sed 's/^/  /'
$K get nodes -o custom-columns='NO:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion'

VERS=$($K get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')
if [ "$VERS" -gt 1 ]; then
  echo "  ATENÇÃO: $VERS versões diferentes de kubelet no cluster. Alinhe antes do upgrade."
fi

hr "Recursos ALOCADOS (requests/limits) por nó"
for n in $($K get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "-- $n"
  $K describe node "$n" | sed -n '/Allocated resources:/,/Events:/p' | grep -E 'cpu|memory' | sed 's/^/   /'
done

hr "Uso real (metrics-server)"
$K top nodes 2>/dev/null || echo "  metrics-server ausente (ok por enquanto; entra na Fase 1)"

hr "Componentes do control plane (static pods)"
$K -n kube-system get pods -l tier=control-plane -o wide 2>/dev/null

hr "CNI detectado (todos os namespaces)"
$K get ds -A -o custom-columns='NS:.metadata.namespace,DAEMONSET:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' \
  | grep -iE 'calico|cilium|flannel|weave|antrea|canal|kube-router|tigera' \
  || echo "  Não identificado. Confira no nó: ls /etc/cni/net.d && cat /etc/cni/net.d/*"

hr "Instalações via Helm (o que já existe e como foi instalado)"
helm list -A 2>/dev/null || echo "  helm não instalado no Mac"

hr "Argo CD, cert-manager, MetalLB e kcert em execução"
$K get pods -A --no-headers 2>/dev/null | awk '{print $1}' | sort | uniq -c \
  | grep -iE 'argocd|argo-rollouts|cert-manager|metallb|kcert' || echo "  Nenhum."
$K get ipaddresspools.metallb.io -A 2>/dev/null

hr "StorageClasses"
$K get storageclass

hr "Entrada de tráfego: ingress-nginx da comunidade?"
NGX=$($K get pods -A -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$NGX" -gt 0 ]; then
  echo "  SIM: $NGX pod(s) do ingress-nginx da comunidade (aposentado em mar/2026)."
  $K get pods -A -l app.kubernetes.io/name=ingress-nginx -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[0].image'
else
  echo "  Nenhum pod com o label da comunidade. Pode ser o NGINX Ingress da F5 — confira a imagem:"
  $K get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[0].image' | grep -i nginx
fi

hr "Service e portas do ingress-nginx (como ele recebe tráfego)"
$K get svc -A -l app.kubernetes.io/name=ingress-nginx -o wide 2>/dev/null
$K get deploy,ds -A -l app.kubernetes.io/name=ingress-nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  hostNetwork="}{.spec.template.spec.hostNetwork}{"  hostPorts="}{.spec.template.spec.containers[0].ports[*].hostPort}{"\n"}{end}' 2>/dev/null

hr "Como o tráfego chega (Services LoadBalancer/NodePort)"
$K get svc -A | awk 'NR==1 || /LoadBalancer|NodePort/'
$K get pods -A -o wide 2>/dev/null | grep -iE 'metallb|kube-vip|cilium-l2' >/dev/null \
  && echo "  Provedor de LoadBalancer encontrado (MetalLB/kube-vip/Cilium)." \
  || echo "  Nenhum provedor de LoadBalancer óbvio. Envoy Gateway vai precisar de NodePort ou MetalLB."

hr "Ingress existentes (o que será migrado)"
$K get ingress -A

hr "CRDs já instalados de Gateway API / cert-manager / Argo CD"
$K get crd 2>/dev/null | grep -E 'gateway.networking.k8s.io|cert-manager.io|argoproj.io' || echo "  Nenhum."

hr "Fim. Nada foi alterado no cluster."
