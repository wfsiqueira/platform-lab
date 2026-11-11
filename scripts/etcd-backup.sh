#!/usr/bin/env bash
# etcd-backup.sh — snapshot do etcd. Rode NO control-plane, como root:
#   sudo ./etcd-backup.sh [/var/backups/etcd]
# Usa os certificados padrão do kubeadm. Também é o exercício nº 1 da CKA.
set -eu

DEST="${1:-/var/backups/etcd}"
TS=$(date +%Y%m%d-%H%M%S)
FILE="$DEST/etcd-snapshot-$TS.db"
PKI=/etc/kubernetes/pki/etcd

mkdir -p "$DEST"

if ! command -v etcdctl >/dev/null 2>&1; then
  echo "etcdctl não encontrado. Instale (apt install etcd-client) ou use o binário do pod:"
  echo "  kubectl -n kube-system exec etcd-\$(hostname) -- etcdctl ..."
  exit 1
fi

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$PKI/ca.crt" \
  --cert="$PKI/server.crt" \
  --key="$PKI/server.key" \
  snapshot save "$FILE"

# Conferência do snapshot (etcdutl é o comando atual; etcdctl status ficou deprecado)
if command -v etcdutl >/dev/null 2>&1; then
  etcdutl snapshot status "$FILE" -w table
else
  ETCDCTL_API=3 etcdctl snapshot status "$FILE" -w table
fi

# Guarda também os manifestos e o PKI, necessários para um restore completo
tar czf "$DEST/k8s-config-$TS.tgz" /etc/kubernetes/manifests /etc/kubernetes/pki 2>/dev/null

# Retenção: mantém os 7 snapshots mais recentes
ls -1t "$DEST"/etcd-snapshot-*.db 2>/dev/null | tail -n +8 | while read -r old; do rm -f "$old"; done

echo "OK: $FILE"
echo "Copie para FORA do nó (ex.: scp para o Mac ou NAS). Snapshot no mesmo disco não é backup."
