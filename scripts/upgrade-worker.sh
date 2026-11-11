#!/usr/bin/env bash
# upgrade-worker.sh — sobe UM worker kubeadm para a versão de destino (CentOS, pacotes pkgs.k8s.io).
# Rode NO MASTER, depois que o control plane já estiver na versão de destino:
#   ./upgrade-worker.sh <nó> <ip> <patch>        ex.: ./upgrade-worker.sh vmkubernetesworkernode02 192.168.3.9 1.34.13
# Opções (variáveis de ambiente):
#   DISABLE_EVICTION=1   apaga pods ignorando PDB (volumes locais que não podem sair do nó)
#   DRAIN_TIMEOUT=600s   pods que demoram a encerrar (Postgres do CloudNativePG)
set -eu

if [ "$(id -u)" = "0" ]; then
  echo "Não rode com sudo: o script usa as chaves SSH do seu usuário. O sudo é pedido dentro de cada nó."; exit 1
fi

NODE="${1:?uso: $0 <nó> <ip> <patch>}"
IP="${2:?uso: $0 <nó> <ip> <patch>}"
PATCH="${3:?uso: $0 <nó> <ip> <patch>  (ex.: 1.34.13)}"
MINOR=$(echo "$PATCH" | cut -d. -f1,2)

CUR=$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
echo "== $NODE ($IP): kubelet $CUR -> v$PATCH (repo v$MINOR)"
if [ "$CUR" = "v$PATCH" ]; then echo "Já está na versão de destino."; exit 0; fi

EXTRA=""
[ "${DISABLE_EVICTION:-0}" = "1" ] && EXTRA="--disable-eviction"
# shellcheck disable=SC2086
if ! kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT:-120s}" $EXTRA; then
  echo "Drain não terminou; devolvendo o nó."
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide | grep -vE 'calico|csi-node|kube-proxy|speaker'
  kubectl uncordon "$NODE"; exit 1
fi

LOCAL_SCRIPT=$(mktemp /tmp/upgrade-node.XXXXXX)
REMOTE_SCRIPT="/tmp/upgrade-node-$USER-$$.sh"
cat > "$LOCAL_SCRIPT" <<EOF
set -e
sed -i "s#/v1\.[0-9]*/#/v${MINOR}/#g" /etc/yum.repos.d/kubernetes.repo
dnf makecache -q
dnf install -y "kubeadm-${PATCH}" --disableexcludes=kubernetes
kubeadm upgrade node
dnf install -y "kubelet-${PATCH}" "kubectl-${PATCH}" --disableexcludes=kubernetes
systemctl daemon-reload
systemctl restart kubelet
echo "nó atualizado: \$(kubelet --version)"
EOF
scp -q "$LOCAL_SCRIPT" "$IP:$REMOTE_SCRIPT"; rm -f "$LOCAL_SCRIPT"
if ! ssh -t "$IP" "sudo bash $REMOTE_SCRIPT; rc=\$?; rm -f $REMOTE_SCRIPT; exit \$rc"; then
  echo "ERRO no nó. Ele continua cordoned. Não faça uncordon antes de investigar."; exit 1
fi

echo "Aguardando o kubelet reportar v$PATCH..."
i=0
until [ "$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')" = "v$PATCH" ]; do
  i=$((i+1)); [ "$i" -ge 60 ] && { echo "Tempo esgotado; o nó continua cordoned."; exit 1; }
  sleep 10
done
kubectl wait --for=condition=Ready "node/$NODE" --timeout=300s
kubectl uncordon "$NODE"
kubectl get node "$NODE"
