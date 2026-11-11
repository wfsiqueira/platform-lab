#!/usr/bin/env bash
# reset-identidade.sh — gera machine-id e chaves SSH novas em UM nó, com drain e uncordon.
# Rode NO MASTER (precisa de kubectl funcionando e ssh para o nó):
#   ./scripts/reset-identidade.sh vmkubernetesworkernode01 192.168.3.8
# Um nó por vez. Não rode no master: ele mantém a identidade atual.
#
# PDB: pods com PodDisruptionBudget que não pode ser cumprido (1 réplica, ou volume local preso
# ao nó) travam o drain. Por padrão o script desiste em 120 s, faz uncordon e lista o que travou.
# Com DISABLE_EVICTION=1 o drain APAGA esses pods ignorando o PDB (downtime curto e consciente):
#   DISABLE_EVICTION=1 ./scripts/reset-identidade.sh <nó> <ip>
# Pods que demoram a encerrar (ex.: Postgres do CloudNativePG, shutdown "smart"): DRAIN_TIMEOUT=600s
set -eu

NODE="${1:?uso: $0 <nome-do-nó> <ip>}"
IP="${2:?uso: $0 <nome-do-nó> <ip>}"

if [ "$NODE" = "vmkubernetesmasternode" ]; then
  echo "O master mantém a identidade atual. Nada a fazer."; exit 1
fi

OLD_ID=$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.machineID}')
echo "== $NODE ($IP)  machineID atual: $OLD_ID"

EXTRA=""
if [ "${DISABLE_EVICTION:-0}" = "1" ]; then EXTRA="--disable-eviction"; echo "ATENÇÃO: ignorando PDBs (--disable-eviction)"; fi
# shellcheck disable=SC2086
if ! kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT:-120s}" $EXTRA; then
  echo
  echo "Drain não terminou. Pods que ficaram no nó:"
  kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide | grep -vE 'calico|csi-node|kube-proxy|speaker'
  echo; echo "PDBs sem margem (ALLOWED DISRUPTIONS = 0):"
  kubectl get pdb -A | awk 'NR==1 || $(NF-1)==0'
  kubectl uncordon "$NODE"
  echo; echo "Nó devolvido (uncordon). Resolva os PDBs ou rode de novo com DISABLE_EVICTION=1."
  exit 1
fi

# -t para o sudo pedir senha; o reboot derruba a conexão (por isso o '|| true')
ssh -t "$IP" 'sudo bash -c "
  rm -f /etc/machine-id /var/lib/dbus/machine-id
  systemd-machine-id-setup
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  echo novo machine-id: \$(cat /etc/machine-id)
  systemctl reboot
"' || true

# a chave de host mudou: remove a antiga do known_hosts deste usuário
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
ssh-keygen -R "$NODE" >/dev/null 2>&1 || true

# Não basta esperar "Ready": logo após o reboot o nó ainda aparece Ready por ~40 s
# (o controller só marca NotReady depois do grace period). Esperamos o kubelet subir de novo
# e reportar o NOVO machine-id; só então Ready e uncordon.
echo "Aguardando o nó reiniciar e reportar o novo machine-id (até 10 min)..."
i=0
while :; do
  CUR=$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.machineID}' 2>/dev/null || true)
  if [ -n "$CUR" ] && [ "$CUR" != "$OLD_ID" ]; then break; fi
  i=$((i+1)); [ "$i" -ge 60 ] && { echo "Tempo esgotado: o nó não reportou novo machine-id. Ele continua cordoned; investigue."; exit 1; }
  sleep 10
done
kubectl wait --for=condition=Ready "node/$NODE" --timeout=600s
kubectl uncordon "$NODE"

NEW_ID=$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.machineID}')
echo "machineID: $OLD_ID -> $NEW_ID"
echo "OK"
echo "Lembrete: no Mac, rode também  ssh-keygen -R $IP"
