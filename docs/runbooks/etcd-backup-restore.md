# Runbook — Backup e restore do etcd (cluster kubeadm, etcd empilhado)

Este é um dos exercícios mais frequentes da CKA. Treine no seu cluster **só o backup**; o restore, treine primeiro no killer.sh ou num cluster descartável.

## Backup

```bash
# no master
sudo ./scripts/etcd-backup.sh /var/backups/etcd
scp master:/var/backups/etcd/etcd-snapshot-*.db ~/Backups/homelab/   # tire do nó
```

O que o script faz por baixo (decore para a prova):

```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd/snap.db
```

Onde achar os caminhos se esquecer: `cat /etc/kubernetes/manifests/etcd.yaml | grep -E 'cert|key|data-dir|listen-client'`.

## Restore (num único control plane)

```bash
# 1. Pare os componentes estáticos tirando os manifestos do lugar
sudo mkdir -p /root/manifests-bkp && sudo mv /etc/kubernetes/manifests/*.yaml /root/manifests-bkp/

# 2. Restaure para um diretório NOVO (nunca por cima do atual)
sudo etcdutl snapshot restore /var/backups/etcd/snap.db --data-dir /var/lib/etcd-restore
#   (versões antigas: ETCDCTL_API=3 etcdctl snapshot restore ... --data-dir ...)

# 3. Aponte o etcd para o novo diretório
sudo sed -i 's#/var/lib/etcd#/var/lib/etcd-restore#g' /root/manifests-bkp/etcd.yaml

# 4. Devolva os manifestos e espere o kubelet recriar os pods
sudo mv /root/manifests-bkp/*.yaml /etc/kubernetes/manifests/
watch crictl ps
kubectl get pods -A
```

Pegadinhas comuns na prova: usar a porta errada (2379 é a de cliente), esquecer os três certificados, restaurar por cima do `data-dir` em uso e editar só o `--data-dir` sem mudar o `hostPath` do volume no manifesto (o `sed` acima troca os dois).

## Referências

- [Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [etcd disaster recovery](https://etcd.io/docs/latest/op-guide/recovery/)
