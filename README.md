# platform-lab

Laboratório de engenharia de plataforma no meu homelab: um *golden path* em que um desenvolvedor pede um serviço e recebe repositório, deploy via GitOps, banco de dados, autoscaling e telemetria sem abrir ticket.

> Status: **Semanas 1–2 — Fundação** (GitOps, Gateway API, cluster atualizado).

## Ambiente

| Item | Valor |
| --- | --- |
| Cluster | kubeadm sobre VMware, CentOS Stream 9, 1 control-plane + 6 workers |
| Nós | 8 vCPU / 7,4 GiB RAM cada, containerd 2.x |
| Rede | Calico (operator) + MetalLB (192.168.3.160–199) |
| Storage | OpenEBS `openebs-hostpath` (local, sem réplica) + Velero |
| Entrada | Cloudflare Tunnel → Gateway API (Envoy Gateway), migrando do ingress-nginx |
| DNS e TLS | external-dns + TLS na borda da Cloudflare |
| GitOps | Argo CD (Helm) com padrão app-of-apps |

## Estrutura

```
bootstrap/          # o único passo manual: instalar o Argo CD e a root app
platform/apps/      # Applications do Argo CD (uma por componente)
platform/guardrails # namespaces, quotas, LimitRange, PriorityClass
platform/gateway/   # GatewayClass, Gateway, ClusterIssuer, rotas
platform/demo/      # app de teste para validar a entrada
scripts/            # preflight e backup do etcd
docs/adr/           # decisões de arquitetura
docs/runbooks/      # upgrade do cluster, backup e restore do etcd
```

## Como subir do zero

```bash
./scripts/preflight.sh          # só leitura: confere versões, recursos e entrada
./bootstrap/install-argocd.sh   # adota o Argo CD existente e aplica a root app
```

A partir daí, toda mudança entra por Pull Request neste repositório.

## Decisões

- [ADR-0001 — GitOps como única via de mudança](docs/adr/0001-gitops-como-unica-via-de-mudanca.md)
- [ADR-0002 — Gateway API no lugar do ingress-nginx](docs/adr/0002-gateway-api-no-lugar-do-ingress-nginx.md)

## Estudo

- [Passo a passo da Etapa 1 (semanas 1 e 2)](docs/estudo/passo-a-passo-etapa-1.md)
- [Roteiro de 12 semanas](docs/estudo/roteiro.md)
- [Guia das semanas 1 e 2](docs/estudo/guia-semanas-01-02.md)

## Runbooks

- [Identidade única nos nós clonados](docs/runbooks/reset-identidade-clones.md)
- [Calico e Istio antes do upgrade](docs/runbooks/upgrade-calico-istio.md)
- [Upgrade do cluster kubeadm](docs/runbooks/upgrade-kubeadm.md)
- [Backup e restore do etcd](docs/runbooks/etcd-backup-restore.md)
- [Migração dos Ingress pelo Cloudflare Tunnel](docs/runbooks/migracao-ingress.md)

## Segurança

Nenhum segredo é versionado. O `pre-commit` roda o gitleaks em todo commit.
