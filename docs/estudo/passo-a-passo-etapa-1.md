# Passo a passo — Etapa 1 (semanas 1 e 2): Fundação do platform-lab

**Objetivo da etapa:** sair de um cluster com 2 anos de mudanças manuais e componentes vencidos para um cluster v1.36 gerenciado por GitOps, com backups testados e a entrada de tráfego migrada do ingress-nginx (aposentado) para a Gateway API.

**Como usar:** siga os passos na ordem. Cada passo tem **objetivo**, **comandos**, **validação** e **rollback**. Não comece um passo sem a validação do anterior. Comandos marcados *(master)* rodam no `vmkubernetesmasternode`; *(nó)* rodam no worker indicado; o resto roda no Mac, na pasta do repositório.

Runbooks de referência em `docs/runbooks/`. Exercícios de CKA em `cka/semanas-01-02/`.

---

## Estado em 11/11/2026

| Item | Situação |
| --- | --- |
| Repositório `wfsiqueira/platform-lab` | Criado, pre-commit ativo, histórico limpo (coletas removidas) |
| Diagnóstico do cluster | Concluído (preflight + coleta) |
| kubeconfig do master | Corrigido (certificado de cliente antigo; copiado o `admin.conf`) |
| Identidade dos nós | Os **7 nós** têm o mesmo `machine-id` e a mesma chave SSH |
| Incidente | Drain do worker01 travado por PDB e interrompido; nó precisa de `uncordon` |

### Mapa do cluster

| Componente | Versão / estado | Ação na etapa |
| --- | --- | --- |
| Kubernetes (kubeadm, CentOS Stream 9) | v1.33 (worker03 em 1.33.3) | Subir para v1.36 |
| containerd | 2.4.2 (worker03 em 1.7.27) | Alinhar worker03 |
| Calico (operator) | v3.28.1, testado até K8s 1.30 | Atualizar antes do upgrade |
| Istio | 1.21.2, sem suporte e **sem uso** | Remover |
| ingress-nginx (comunidade) | v1.15.1, aposentado em mar/2026 | Substituir por Envoy Gateway |
| Cloudflare Tunnel | `616ad2e0…`, 2 réplicas, **rotas no painel** | Fixar 2 réplicas; cortar hosts pelo painel |
| external-dns | `policy: sync`, `sources: [ingress]` | `upsert-only` durante a migração |
| Argo CD / cert-manager | Helm (chart 10.11.6 / v1.18.0) | Adotar, não reinstalar |
| MetalLB, OpenEBS, Velero, CNPG, Kyverno | Instalados | Usar; checar Kyverno |

---

## Passo 0 — Pré-requisitos (uma vez)

**Comandos**

```bash
brew install helm jq kubent velero pre-commit gitleaks
```

*(master)* chave SSH para os workers, para não digitar senha nos próximos passos:

```bash
for ip in 192.168.3.8 192.168.3.9 192.168.3.10 192.168.3.12 192.168.3.17 192.168.3.18; do ssh-copy-id "$ip"; done
```

*(master)* certificados do cluster:

```bash
sudo kubeadm certs check-expiration
```

**Validação:** `kubectl get nodes` funciona no Mac e no master; nenhum certificado com menos de 30 dias.

---

## Passo 1 — Recuperar o worker01 (incidente do drain)

**Objetivo:** devolver o nó que ficou `cordoned` e garantir que os pods com volume local voltaram.

```bash
kubectl uncordon vmkubernetesworkernode01
kubectl get pods -A --field-selector=status.phase=Pending
kubectl -n application get pods -o wide
kubectl -n baseplus-hml get pods -o wide
```

**Validação:** nenhum pod `Pending`; Passbolt abre e faz login.

**O que aconteceu e por quê:** o drain travou em PDBs que nunca podem ser cumpridos (`istiod` com 1 réplica; `passbolt-mariadb-primary-0`, primário único com volume local) e no `coredns`. Os pods com volume `openebs-hostpath` despejados ficaram sem ter para onde ir, porque o volume está preso ao nó. Ver "Lições aprendidas".

---

## Passo 2 — Três camadas de backup

**Objetivo:** ter caminho de volta antes de qualquer mudança. Nada a partir do passo 3 começa sem isto.

1. **etcd** *(master)*:

   ```bash
   sudo ./scripts/etcd-backup.sh /var/backups/etcd
   ```

   No Mac, copie para fora do nó:

   ```bash
   mkdir -p ~/Backups/homelab && scp 192.168.3.7:/var/backups/etcd/etcd-snapshot-*.db ~/Backups/homelab/
   ```

2. **Velero** (aplicações e volumes):

   ```bash
   velero backup create pre-etapa1-$(date +%Y%m%d) --wait
   velero backup describe pre-etapa1-$(date +%Y%m%d) --details | grep -iE 'phase|errors|warnings|podvolume'
   ```

   Se o Velero não fizer backup dos volumes (`openebs-hostpath`), faça dump dos bancos:

   ```bash
   kubectl -n application exec passbolt-mariadb-primary-0 -- sh -c 'mysqldump -u root -p"$MARIADB_ROOT_PASSWORD" --all-databases' > ~/Backups/homelab/passbolt-$(date +%Y%m%d).sql
   ```

3. **Snapshots das 7 VMs** no vCenter (sem memória), com o nome `pre-etapa1`.

**Validação:** arquivo do etcd no Mac; backup do Velero `Completed`; 7 snapshots visíveis no vCenter.

**CKA:** exercício 1 (etcd) e leitura de `docs/runbooks/etcd-backup-restore.md`.

---

## Passo 3 — Túnel e DNS em modo seguro

**Objetivo:** impedir que um drain derrube todos os sites e que apagar um Ingress apague um DNS.

```bash
helm search repo cloudflare-tunnel   # descubra <repo>
helm upgrade cloudflare <repo>/cloudflare-tunnel --version 0.3.2 -n cloudflare \
  --reuse-values -f platform/cloudflare/tunnel-ingress.yaml

helm search repo external-dns        # descubra <repo>
helm upgrade external-dns <repo>/external-dns --version 1.17.0 -n cloudflare \
  --reuse-values --set policy=upsert-only
```

**Validação:**

```bash
helm get values cloudflare -n cloudflare | grep replicaCount       # 2
kubectl -n cloudflare get pods -o wide                             # 2 cloudflared em nós diferentes
kubectl -n cloudflare logs deploy/external-dns --tail=20 | grep -i policy
```

**Rollback:** `helm rollback cloudflare -n cloudflare` e `helm rollback external-dns -n cloudflare`.

---

## Passo 4 — Remover o Istio

**Objetivo:** tirar um componente sem suporte e sem uso, que trava drains e bloqueia o upgrade.

```bash
kubectl -n istio-ingress get all ; helm list -n istio-ingress   # confirme que está vazio ou sem uso
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl get crd -o name | grep 'istio.io' | xargs kubectl delete
kubectl delete ns istio-system istio-ingress
```

**Validação:** `kubectl get pods -A | grep -i istio` vazio; sites no ar.

**Rollback:** reinstalar os charts `base` e `istiod` 1.21.2 (só se algo depender, o que a coleta descartou).

---

## Passo 5 — Auditar PDBs antes dos drains

**Objetivo:** saber de antemão o que vai travar cada drain.

```bash
kubectl get pdb -A | awk 'NR==1 || $(NF-1)==0'                     # PDBs sem margem
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide         # onde estão as réplicas do coredns
kubectl get pods -A -o wide | grep -E 'mariadb|redis|-pg-'          # pods com volume local
```

**Decisão por tipo:**

| Caso | Tratamento |
| --- | --- |
| coredns com as 2 réplicas no mesmo nó ou uma não pronta | `kubectl -n kube-system rollout restart deploy coredns` e conferir que caíram em nós diferentes |
| Pod com volume local (MariaDB, Redis, Postgres do CNPG) | Não tem para onde ir: aceitar alguns minutos fora com `DISABLE_EVICTION=1` |
| PDB com 1 réplica de componente sem estado | Escalar para 2 antes do drain |

**CKA:** exercício 4 (drain com PDB).

---

## Passo 6 — Identidade única nos workers 01, 02, 04, 05 e 06

**Objetivo:** cada nó com `machine-id` e chaves SSH próprios (requisito para a telemetria por host na Fase 1). O master mantém a identidade atual.

```bash
DISABLE_EVICTION=1 ./scripts/reset-identidade.sh vmkubernetesworkernode01 192.168.3.8
DISABLE_EVICTION=1 ./scripts/reset-identidade.sh vmkubernetesworkernode02 192.168.3.9
DISABLE_EVICTION=1 ./scripts/reset-identidade.sh vmkubernetesworkernode05 192.168.3.17
DISABLE_EVICTION=1 ./scripts/reset-identidade.sh vmkubernetesworkernode04 192.168.3.12
kubectl -n cloudflare get pods -o wide        # 2 cloudflared Running antes do worker06
DISABLE_EVICTION=1 ./scripts/reset-identidade.sh vmkubernetesworkernode06 192.168.3.18
```

Depois de cada nó, remova a chave antiga no Mac: `ssh-keygen -R <ip>`.

**Validação:**

```bash
kubectl get nodes -o custom-columns='NO:.metadata.name,MACHINE-ID:.status.nodeInfo.machineID'   # 6 IDs diferentes do master
kubectl get pods -A --field-selector=status.phase=Pending                                         # vazio
```

**Rollback:** reverter o snapshot da VM do nó afetado.

---

## Passo 7 — worker03: identidade + containerd 2.x (um drain só)

**Objetivo:** alinhar o único nó em containerd 1.7.27 e trocar a identidade dele na mesma janela.

```bash
kubectl drain vmkubernetesworkernode03 --ignore-daemonsets --delete-emptydir-data --disable-eviction
```

*(nó, root)*:

```bash
cp /etc/containerd/config.toml /root/config.toml.1.7.bkp
dnf install -y containerd.io-<mesma versão dos outros nós>   # rpm -q containerd.io no worker01
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup && ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_* && ssh-keygen -A
systemctl reboot
```

```bash
kubectl wait --for=condition=Ready node/vmkubernetesworkernode03 --timeout=600s
kubectl uncordon vmkubernetesworkernode03
kubectl get node vmkubernetesworkernode03 -o wide     # containerd://2.4.x
```

**Rollback:** snapshot da VM, ou restaurar `/root/config.toml.1.7.bkp` e o pacote anterior.

---

## Passo 8 — Atualizar o Calico

**Objetivo:** colocar o CNI numa versão testada para K8s 1.33 a 1.36. Detalhes em `docs/runbooks/upgrade-calico-istio.md`.

```bash
kubectl get installation default -o jsonpath='{.spec.variant}{"\n"}'
kubectl -n tigera-operator get deploy tigera-operator -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# escolha a versão alvo na página de requisitos do Calico e leia o guia de upgrade dela
CALICO=v3.32.0
kubectl apply --server-side --force-conflicts -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO}/manifests/tigera-operator.yaml"
watch kubectl get tigerastatus
```

**Validação:** `tigerastatus` todo `AVAILABLE=True`; teste pod a pod entre nós e DNS (comandos no runbook); sites no ar.

**Rollback:** reaplicar o `tigera-operator.yaml` da v3.28.1; se a rede quebrar, snapshots.

**CKA:** troubleshooting de rede (CNI em `/etc/cni/net.d`, pod sem IP, DNS).

---

## Passos 9, 10 e 11 — Kubernetes 1.33 → 1.34 → 1.35 → 1.36

**Objetivo:** um salto de minor por passo, seguindo `docs/runbooks/upgrade-kubeadm.md` (seções 1 a 3).

Antes de cada salto:

```bash
sudo ./scripts/etcd-backup.sh            # (master)
velero backup create pre-k8s-<versão> --wait
kubent                                   # APIs removidas na versão de destino
```

Ordem dentro de cada salto: master (`kubeadm upgrade apply`) → workers um a um (`kubeadm upgrade node`), sempre com drain (`--disable-eviction` nos nós com volume local) e uncordon. Use o `kubectl` do master durante os saltos (o do Mac está em 1.36).

**Validação de cada salto:**

```bash
kubectl get nodes                                    # todos na mesma versão
kubectl get pods -A | grep -vE 'Running|Completed'   # só o cabeçalho
sudo kubeadm certs check-expiration                  # (master) renovados pelo upgrade
```

**Rollback:** snapshots das VMs (o kubeadm não faz downgrade).

**CKA:** exercícios 3, 5, 6 e 7 ao longo dos três dias.

---

## Passo 12 — GitOps: adotar o Argo CD

**Objetivo:** o Argo CD existente passa a sincronizar o `platform-lab`.

```bash
kubectl get clusterpolicy 2>/dev/null       # Kyverno: alguma política barra Namespace/Deployment sem labels ou limits?
./bootstrap/install-argocd.sh               # adota o Argo CD existente e aplica a root app
kubectl -n argocd get applications
```

**Validação:** `root`, `guardrails`, `envoy-gateway` com `Synced/Healthy`; PriorityClasses `homelab-critical` e `lab-default` criadas.

Em seguida, com os CRDs da Gateway API já instalados:

```bash
helm upgrade external-dns <repo>/external-dns --version 1.17.0 -n cloudflare --reuse-values \
  --set 'sources={ingress,gateway-httproute}'
```

**Rollback:** `kubectl -n argocd delete application root` (as Applications filhas são removidas; os Helm releases antigos continuam).

**CKA:** exercícios 8, 9 e 10 (Helm, Kustomize, CRDs).

---

## Passo 13 — Gateway, demo e o teste do X-Forwarded-Proto

**Objetivo:** provar o caminho túnel → Envoy → backend sem tocar em nenhum site real.

```bash
kubectl -n argocd get application gateway demo
kubectl -n envoy-gateway-system get pods --show-labels | grep homelab
kubectl -n envoy-gateway-system get svc -o wide          # confira a porta interna (10080) do Service gerado
kubectl -n envoy-gateway-system get endpoints envoy-homelab
kubectl run t --rm -it --image=curlimages/curl -- \
  curl -s -H "Host: demo.wsiqueira.cloud" http://envoy-homelab.envoy-gateway-system.svc.cluster.local/ | head -20
```

No painel da Cloudflare: **Tunnels → kubernetes-tunnel-cloudflare → Routes → Add route**: `demo.wsiqueira.cloud` → `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80`. Registre em `docs/cloudflare-tunnel-rotas.md`.

**Validação:** `https://demo.wsiqueira.cloud` mostra a página do echoserver. Procure `x-forwarded-proto`:
- `https`: seguir com HTTP até os backends.
- `http`: Plano B (TLS entre túnel e Envoy). Pare e revise antes do passo 14.

**CKA:** exercício 11 (HTTPRoute com divisão de tráfego).

---

## Passo 14 — Corte do argocd.wsiqueira.cloud

**Objetivo:** primeiro host real migrado, com rollback em segundos.

1. Descomentar a rota `argocd` em `platform/gateway/03-routes.yaml`, commit, push, esperar o sync.
2. Ativar o modo HTTP do Argo CD **e** trocar a rota no painel, juntos:

   ```bash
   helm upgrade argocd argo/argo-cd --version 10.11.6 -n argocd --reuse-values \
     --set 'configs.params.server\.insecure=true'
   ```

   Painel: rota `argocd.wsiqueira.cloud` → `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80`, sem `noTLSVerify` e sem `originServerName`.

**Validação:** login no Argo CD pelo navegador, sem loop de redirect.

**Rollback:** mesmo `helm upgrade` com `=false` e a rota de volta para `https://ingress-nginx-controller.kube-system.svc.cluster.local:443` com `noTLSVerify` e `originServerName`.

---

## Passo 15 — Fechamento da etapa

- [ ] 7 nós em v1.36, containerd 2.x, `machine-id` únicos.
- [ ] Istio removido; Calico atualizado.
- [ ] Backups: etcd fora do nó, Velero recente, snapshots (apague os antigos depois de 7 dias estáveis).
- [ ] Argo CD sincronizando o `platform-lab`; `selfHeal` desfaz alteração manual.
- [ ] `demo` e `argocd` via Envoy Gateway.
- [ ] 12 exercícios de CKA em até 66 minutos.
- [ ] ADR-0002 atualizado com o resultado; post no LinkedIn.

Pendente para a etapa 2: baseplus e Keycloak (HTTPRoutes no repositório da baseplus), Passbolt (opcional), remoção do ingress-nginx e do kcert, rotas do túnel em Terraform.

---

## Lições aprendidas (material de entrevista)

| Situação | Causa | O que fiz | O que mostra |
| --- | --- | --- | --- |
| `kubectl` no master respondia 401 | Certificado de cliente do kubeconfig antigo; o cluster tem 2 anos | Copiei o `admin.conf` atual; conferi `kubeadm certs check-expiration` | Ciclo de vida de certificados do kubeadm |
| 7 VMs com o mesmo `machine-id` e chave SSH | Clones do VMware sem generalização | Script que troca a identidade nó a nó com drain e uncordon | Higiene de templates; impacto em telemetria |
| Drain travado | PDBs impossíveis (1 réplica) e volumes locais presos ao nó | Auditoria de PDB antes; `--disable-eviction` consciente | PDB, StatefulSet com volume local, janela de manutenção |
| DNS apontando para um túnel "diferente" | `tunnelId` sobrando no values; o real vem do secret | Confirmei pelos logs do cloudflared e pelo painel | Investigar pela fonte da verdade, não pela config |
| Mudar o values do túnel não mudaria nada | Túnel com configuração remota (painel) | Corte por host no painel; plano de levar para Terraform | Entender onde a configuração realmente vive |
| Componentes vencidos (Istio 1.21, Calico 3.28, ingress-nginx) | Cluster sem ciclo de upgrade | Matriz de compatibilidade antes de cada salto | Gestão de dependências e upgrade seguro |
