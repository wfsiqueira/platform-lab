# Runbook — Upgrade do cluster kubeadm (v1.33 → v1.36) em CentOS

**Alvo:** v1.36, a versão usada hoje na prova da CKA. O kubeadm só sobe **uma versão minor por vez**: 1.33 → 1.34 → 1.35 → 1.36. Cada salto segue o mesmo roteiro abaixo.

**Premissa:** nós CentOS Stream 9 (ou 10) com pacotes RPM de `pkgs.k8s.io`, repositório com `exclude=` (padrão da doc oficial).

> **Se `cat /etc/os-release` mostrar CentOS 7 ou Stream 8, pare aqui.** Os dois estão fora de suporte, com kernel antigo e cgroup v1 por padrão. Nesse caso o primeiro projeto é trocar o SO dos nós (Rocky/Alma 9 ou Stream 9), um nó por vez, antes de qualquer upgrade do Kubernetes.

---

## 0. Antes do primeiro salto (uma vez só)

- [ ] `./scripts/preflight.sh` sem erros e anotado no `docs/`.
- [ ] **Snapshot das 7 VMs no vCenter** (com memória desligada). É o seu rollback real: o kubeadm não faz downgrade.
- [ ] **Backup do etcd** com `scripts/etcd-backup.sh` e cópia para fora do nó.
- [ ] SO e kernel: `cat /etc/os-release && uname -r` em todos os nós. (Confirmado: CentOS Stream 9, kernel 5.14, cgroup v2.)
- [ ] Identidade dos clones: `machine-id` e chave SSH repetidos em master, worker01 e worker02. Corrigir com `docs/runbooks/reset-identidade-clones.md`.
- [ ] cgroup: `stat -fc %T /sys/fs/cgroup` deve responder `cgroup2fs`. [Provável] O kubelet recente recusa cgroup v1 por padrão.
- [ ] Runtime: [Provável] a partir da 1.36 o kubelet exige containerd 2.x; confira as *urgent upgrade notes* de cada versão. **No preflight, o worker03 está em containerd 1.7.27 e kubelet 1.33.3; os outros 6 nós estão em containerd 2.4.2.** Antes do primeiro salto, alinhe o worker03:

```bash
# Do Mac
kubectl drain vmkubernetesworkernode03 --ignore-daemonsets --delete-emptydir-data
```

```bash
# No worker03, como root
cp /etc/containerd/config.toml /root/config.toml.1.7.bkp
dnf list --showduplicates containerd.io | tail -5        # repositório docker-ce; use a mesma 2.4.x dos outros nós
dnf install -y containerd.io-2.4.2                        # ajuste para o pacote exato que os outros nós usam (rpm -q containerd.io)
containerd config default > /etc/containerd/config.toml   # config v3 do containerd 2.x
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
diff <(ssh vmkubernetesworkernode01 cat /etc/containerd/config.toml) /etc/containerd/config.toml   # compare com um nó bom
systemctl restart containerd && systemctl restart kubelet
crictl info | grep -i -m1 systemdcgroup
```

```bash
# Do Mac
kubectl uncordon vmkubernetesworkernode03
kubectl get node vmkubernetesworkernode03 -o wide   # containerd://2.4.x
```

    O kubelet 1.33.3 do worker03 pode ficar; ele será alinhado no primeiro salto para 1.34.
- [ ] Repositório: `cat /etc/yum.repos.d/kubernetes.repo`. Se apontar para `packages.cloud.google.com` ou `yum.kubernetes.io`, esse repositório foi desligado; o passo 1.1 já migra para `pkgs.k8s.io`.
- [ ] Patch: worker03 está em 1.33.3 e os demais em 1.33.1. Diferença de patch na mesma minor é aceita; o primeiro salto (1.34) alinha todos.
- [ ] kubectl do Mac: está em 1.36.1, três minors acima do servidor 1.33 (a política aceita só uma). Durante os saltos, prefira o `kubectl` do master ou instale um 1.34 no Mac.
- [ ] **Bloqueios confirmados no preflight:** Calico v3.28.1 (testado até 1.30) e Istio 1.21.2 (suporta até 1.29, sem suporte desde set/2024). Resolva os dois com `docs/runbooks/upgrade-calico-istio.md` antes do primeiro salto.
- [ ] Backup de aplicação com o Velero já instalado: `velero backup create pre-upgrade-<data> --wait`.
- [ ] APIs removidas: `kubent` ou `pluto detect-all-in-cluster`.
- [ ] Pods com volume local (`openebs-hostpath`) **não migram** de nó no drain. Deixe esses nós por último e trabalhe rápido neles:

```bash
kubectl get pods -A -o wide --field-selector=status.phase=Running \
  | grep -E "$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.name}{"|"}{end}' | sed 's/|$//')"
```

---

## 1. Control plane (`vmkubernetesmasternode`)

No master, como root. Troque `1.34` e `1.34.11` pela minor e pelo patch de destino deste salto.

```bash
TARGET_MINOR=1.34
TARGET_PATCH=1.34.11

# 1.1 Repositório da nova minor
cat > /etc/yum.repos.d/kubernetes.repo <<REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${TARGET_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${TARGET_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REPO
dnf makecache
dnf list --showduplicates kubeadm --disableexcludes=kubernetes | tail -3   # confirme o patch mais recente

# 1.2 kubeadm primeiro
dnf install -y "kubeadm-${TARGET_PATCH}" --disableexcludes=kubernetes
kubeadm version

# 1.3 Plano e aplicação
kubeadm upgrade plan
kubeadm upgrade apply "v${TARGET_PATCH}"
```

Do Mac:

```bash
kubectl drain vmkubernetesmasternode --ignore-daemonsets
```

De volta ao master:

```bash
dnf install -y "kubelet-${TARGET_PATCH}" "kubectl-${TARGET_PATCH}" --disableexcludes=kubernetes
systemctl daemon-reload && systemctl restart kubelet
```

Do Mac:

```bash
kubectl uncordon vmkubernetesmasternode
kubectl get nodes                       # master na nova versão, Ready
kubectl -n kube-system get pods         # control plane Running
```

---

## 2. Workers — **um por vez** (01 → 06)

Do Mac:

```bash
NODE=vmkubernetesworkernode01
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

No worker, como root (crie o `kubernetes.repo` igual ao do passo 1.1):

```bash
TARGET_PATCH=1.34.11
dnf makecache
dnf install -y "kubeadm-${TARGET_PATCH}" --disableexcludes=kubernetes
kubeadm upgrade node

dnf install -y "kubelet-${TARGET_PATCH}" "kubectl-${TARGET_PATCH}" --disableexcludes=kubernetes
systemctl daemon-reload && systemctl restart kubelet
```

Do Mac:

```bash
kubectl uncordon "$NODE"
kubectl get node "$NODE"
```

Espere todos os pods do nó ficarem `Running` antes de ir para o próximo.

---

## 3. Validação depois de cada salto

```bash
kubectl get nodes                                    # todos na mesma versão
kubectl get pods -A | grep -vE 'Running|Completed'   # deve vir só o cabeçalho
curl -sI https://passbolt.wsiqueira.cloud | head -1  # serviço pessoal no ar
```

Faça um novo backup do etcd e só então comece o próximo salto.

## 4. Rollback

1. Problema só num worker: `kubectl drain`, reverter o snapshot da VM, `uncordon`.
2. Problema no control plane: reverter o snapshot do master. Se o etcd ficar inconsistente, restaurar com `docs/runbooks/etcd-backup-restore.md`.

## Referências

- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Upgrading Linux nodes](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/)
- [Installing kubeadm (pacotes RPM)](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Changing the package repository](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/)
- [Version skew policy](https://kubernetes.io/releases/version-skew-policy/)
