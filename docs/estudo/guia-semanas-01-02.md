# Guia de estudo — Semanas 1 e 2: Fundação + CKA (arquitetura do cluster)

*Versão 4 (11/11/2026), ajustada ao preflight e à coleta de Ingress, túnel e DNS.*

**Resultado ao fim da semana 2:** nós com identidade única, Calico atualizado e Istio 1.21 removido, cluster em v1.36 com kubeadm, backup do etcd e do Velero em dia, Argo CD gerenciando o repositório `platform-lab`, pelo menos `demo` e `argocd` servidos pelo Envoy Gateway via Cloudflare Tunnel, e os 12 exercícios de CKA feitos em até 66 minutos.

**Ritmo:** 2 h por dia, 10 dias úteis. Em geral, 1 h de laboratório e 1 h de CKA. Nos dias de upgrade, as 2 h vão para o cluster, porque o upgrade **é** o treino de CKA.

**Arquivos:** a pasta `platform-lab/` é o repositório pronto para `git init`. Os runbooks em `platform-lab/docs/runbooks/` têm os comandos de cada dia.

---

## O que o preflight mostrou (e mudou no plano)

| Achado | Impacto |
| --- | --- |
| CentOS Stream 9, kernel 5.14, cgroup v2 | Base adequada; o runbook usa `dnf` e `pkgs.k8s.io` (já configurado na v1.33) |
| master, worker01 e worker02 com o mesmo `machine-id` e a mesma chave SSH | Corrigir antes da Fase 1 (telemetria por host) |
| worker03 com containerd 1.7.27 (os outros em 2.4.2) | Alinhar antes do salto para 1.36 |
| **Calico v3.28.1** (testado até K8s 1.30) | **Bloqueio:** atualizar antes do 1º salto |
| **Istio 1.21.2** (suporta até 1.29, sem suporte desde set/2024), **sem nenhum uso** | **Bloqueio:** remover no dia 4 (conferir só o namespace `istio-ingress`) |
| ingress-nginx da comunidade (aposentado), 5 Ingress | Migrar para Gateway API, host a host |
| Entrada via **Cloudflare Tunnel**, curinga `*.wsiqueira.cloud` → nginx:443, **1 réplica** do cloudflared | O corte é pôr o host antes do curinga, apontando para o Envoy; subir para 2 réplicas antes dos drains |
| external-dns com `policy: sync` e `sources: [ingress]` | Apagar um Ingress apaga o DNS: usar `upsert-only` durante a migração |
| Túnel `616ad2e0…` roda no cluster (2 réplicas), com **rotas configuradas no painel** da Cloudflare | O corte de cada host é editar a rota no painel; o `ingress` do values do Helm é ignorado |
| Passbolt vai direto do túnel ao Service, **sem nginx** | Migração do Passbolt é opcional; só 3 hosts dependem do nginx |
| Sem DNS curinga; cada host tem CNAME próprio criado pelo external-dns | O `demo` precisa de registro (anotações no Gateway ou manual) |
| Ingress da baseplus pertencem a apps do Argo CD | Os HTTPRoutes dela vão para o repositório da baseplus |
| Também rodam: Kyverno, descheduler, CloudNativePG, Jenkins, `logging` | Kyverno pode barrar manifestos do lab; CNPG e `logging` entram nas Fases 1 e 3 |
| Argo CD (Helm), cert-manager v1.18 (Helm), MetalLB, OpenEBS, Velero já instalados | Adotar o que existe, não reinstalar |
| kubectl do Mac em 1.36 contra servidor 1.33 | Durante os saltos, usar o `kubectl` do master |

---

## Antes do dia 1 (20 min)

- [ ] Criar o repositório **público** `platform-lab` no GitHub e trocar `REPLACE_ME` pelo seu usuário em `bootstrap/root-app.yaml` e `platform/apps/*.yaml`.
- [ ] Renomear `pre-commit-config.yaml` para `.pre-commit-config.yaml` e rodar `chmod +x scripts/*.sh bootstrap/*.sh`.
- [ ] Apagar os arquivos marcados como OBSOLETO (`platform/apps/10-cert-manager.yaml`, `platform/gateway/00-envoyproxy-nodeport.yaml`, `platform/gateway/02-clusterissuers.yaml`).
- [ ] `ssh-copy-id` do master para os 6 workers, para parar de digitar senha.
- [ ] Instalar no Mac: `brew install helm pre-commit gitleaks kubent jq`.
- [ ] Comprar a CKA e agendar a prova para o fim da semana 6. Guarde os dois simulados do killer.sh para a semana 6.

---

## Agenda dia a dia

| Dia | Laboratório (1 h) | CKA (1 h) | Entregável |
| --- | --- | --- | --- |
| 1 | `git init`, `pre-commit install`, 1º commit. Salvar a saída do preflight em `docs/`. Conferir workers 03–06 com o loop do runbook de clones. | Arquitetura do control plane: static pods em `/etc/kubernetes/manifests`, kubelet, `crictl ps` no master. Exercício 2. | Repo no GitHub |
| 2 | `scripts/etcd-backup.sh` no master + cópia para o Mac. `velero backup create pre-upgrade-…`. Snapshots das 7 VMs no vCenter. Fixar **`replicaCount: 2`** do cloudflared no values e **external-dns em `upsert-only`** (runbook de migração), antes de qualquer drain. | etcd: `snapshot save`, `status`, `restore` (runbook do etcd). Exercício 1. | Três camadas de backup |
| 3 | **2 h no cluster:** identidade única (master, worker01, 02 e os que o loop apontar) e containerd 2.x no worker03, aproveitando o mesmo drain. | (drain/uncordon é treino) Exercício 4. | Nós únicos; containerd alinhado |
| 4 | **2 h no cluster:** remover o Istio (uso já descartado; conferir `istio-ingress`) e Calico 3.28 → versão atual, com o teste de rede do runbook. | (troubleshooting de rede é treino) | Bloqueios resolvidos |
| 5 | **2 h no cluster:** salto 1.33 → 1.34 (control plane + 6 workers). | Version skew e `kubeadm upgrade plan`. Exercício 3. | Cluster em 1.34 |
| 6 | **2 h no cluster:** salto 1.34 → 1.35. | RBAC: Role, ClusterRole, bindings, `auth can-i`. Exercícios 5 e 6. | Cluster em 1.35 |
| 7 | **2 h no cluster:** salto 1.35 → 1.36. Backup do etcd e do Velero no fim. | Usuários via CSR API e kubeconfig. Exercício 7. | Cluster em 1.36 |
| 8 | `kubectl get clusterpolicy` (Kyverno) para ver se algo barra o lab. `./bootstrap/install-argocd.sh` (adota o Argo CD existente e aplica a root app). Conferir `guardrails` e `envoy-gateway` *Synced/Healthy*. Adicionar `gateway-httproute` aos sources do external-dns. | Helm e Kustomize. Exercícios 8 e 9. | GitOps funcionando |
| 9 | Apps `gateway` e `demo`. Validar o Service `envoy-homelab` por dentro do cluster. Adicionar a rota `demo.wsiqueira.cloud` no painel do túnel (cria o DNS junto). **Teste do `X-Forwarded-Proto`** na resposta do echoserver (define HTTP ou Plano B). | CRDs, operators e Gateway API. Exercícios 10 e 11. | Demo no ar via túnel + Envoy |
| 10 | Corte do `argocd.wsiqueira.cloud`: `server.insecure=true` e a rota no painel, juntos. Levar o exemplo de HTTPRoutes para o repositório da baseplus. | Simulado: os 12 exercícios cronometrados (meta: 66 min). | 1º host migrado; post no LinkedIn |

O corte de baseplus e Keycloak fica para o início da semana 3. O Passbolt não depende do nginx, então a migração dele é opcional.

---

## Teoria essencial, com o link oficial de cada tema

**Arquitetura do cluster kubeadm.** O kubelet do master sobe apiserver, controller-manager, scheduler e etcd como *static pods*, lendo os YAMLs de `/etc/kubernetes/manifests`. Se o apiserver cair, o `kubectl` não funciona: o diagnóstico é no nó, com `crictl` e `journalctl -u kubelet`. → [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/) · [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)

**etcd.** Guarda todo o estado do cluster. Backup e restore são tarefa certa na CKA. O comando precisa de endpoint e três certificados, e o restore vai para um `data-dir` novo. → [Operating etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)

**Upgrade com kubeadm.** É feito uma minor por vez: primeiro o control plane (`kubeadm upgrade apply`), depois cada worker (`kubeadm upgrade node`), sempre com `drain` antes e `uncordon` depois. Antes de qualquer salto, os componentes do cluster (CNI, service mesh, operators) precisam suportar a versão de destino. → [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/) · [Version skew policy](https://kubernetes.io/releases/version-skew-policy/)

**CNI.** O Calico entrega rede entre pods e NetworkPolicy. Na CKA cai troubleshooting de rede: pod sem IP, DNS falhando, CNI ausente em `/etc/cni/net.d`. → [Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/) · [Calico — upgrade](https://docs.tigera.io/calico/latest/operations/upgrading/kubernetes-upgrade)

**RBAC.** Role e RoleBinding valem num namespace; ClusterRole e ClusterRoleBinding valem no cluster todo, ou uma ClusterRole pode ser ligada a um namespace por RoleBinding. Usuários não existem como objeto: são o CN do certificado. `kubectl auth can-i --as` prova tudo. → [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) · [Certificates and CSRs](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)

**Helm e Kustomize.** Ambos estão no temário atual da CKA. Helm empacota e versiona (install, upgrade, history, rollback). Kustomize aplica overlays sem template e é nativo do `kubectl -k`. → [Helm docs](https://helm.sh/docs/) · [Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

**CRDs e operators.** Um CRD estende a API. Um operator é um controller que reconcilia esse recurso. O tigera-operator (Calico), o Argo CD, o cert-manager e o Envoy Gateway são exatamente isso. → [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)

**Gateway API.** Separa papéis: a GatewayClass (provedor), o Gateway (porta de entrada, cuidado pela infra) e as rotas (HTTPRoute, cuidadas pelos times). Substitui o Ingress e suas anotações proprietárias. → [Gateway API](https://gateway-api.sigs.k8s.io/) · [Envoy Gateway](https://gateway.envoyproxy.io/docs/) · [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway)

**GitOps com Argo CD.** O padrão app-of-apps usa uma Application raiz que aponta para uma pasta de Applications. As *sync waves* ordenam a criação dos recursos. → [Argo CD — Cluster bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) · [Sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)

---

## Critérios de conclusão da etapa

- [ ] `machine-id` e chave SSH únicos nos 7 nós; containerd 2.x em todos.
- [ ] Istio 1.21 fora do cluster e Calico numa versão testada para 1.36.
- [ ] `kubectl get nodes` mostra os 7 nós em v1.36.x.
- [ ] Snapshot do etcd fora do master e backup do Velero recentes; você restaura o etcd sem consultar o runbook.
- [ ] O Argo CD mostra as Applications do `platform-lab` *Synced/Healthy*; uma alteração manual é desfeita pelo `selfHeal`.
- [ ] `demo` e `argocd` respondem via Cloudflare Tunnel → Envoy Gateway.
- [ ] Os 12 exercícios de CKA saem em até 66 minutos.
- [ ] README, ADRs 0001 e 0002 e runbooks publicados; post no LinkedIn sobre a migração do ingress-nginx.

## O que ainda preciso para a próxima etapa

- O resultado do teste de `X-Forwarded-Proto` no dia 9 (define HTTP ou Plano B).

Com isso eu gero o material das semanas 3 e 4 (corte de baseplus e Keycloak; rotas do túnel em Terraform; observabilidade com OTel e LGTM; CKA de workloads, scheduling e storage).
