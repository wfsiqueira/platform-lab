# Etapa 4 — Infraestrutura self-service com Crossplane (Fase 3 do roteiro)

Feito em 24/11/2026. ADR: `docs/adr/0006-crossplane-e-terraform-atlantis.md`.

## O que foi montado

| Peça | Arquivo | Detalhe |
|---|---|---|
| Crossplane 2.5.0 | `platform/apps/50-crossplane.yaml` | namespace `lab-crossplane` (quota 1 vCPU, 3 GiB de limite); core + rbac-manager medidos em ~200 MiB; métricas ligadas |
| Functions | `platform/crossplane/functions.yaml` | `function-go-templating` v0.13.3 e `function-auto-ready` v0.7.4 |
| RBAC | `platform/crossplane/rbac.yaml` | ClusterRole agregado (`aggregate-to-crossplane`) só com os tipos que as Compositions criam |
| API `PostgresDatabase` | `platform/crossplane/postgresdatabase/` | XRD v2 namespaced, `size: small` (1 instância, 1 GiB) ou `medium` (2 instâncias, 2 GiB); compõe um `Cluster` do CloudNativePG |
| API `AppEnvironment` | `platform/crossplane/appenvironment/` | XRD v2 cluster-scoped; compõe Namespace `lab-<nome>`, quota, LimitRange, NetworkPolicy, `PostgresDatabase` e (opcional) Application do Argo CD |
| Pedido de exemplo | `platform/environments/exemplo.yaml` e `platform/apps/52-environments.yaml` | 10 linhas de YAML |
| Teste | `platform/crossplane/tests/` e `.github/workflows/crossplane-render.yml` | `crossplane render` sem cluster, no CI |

O que o time escreve:

```yaml
apiVersion: platform.wsiqueira.cloud/v1alpha1
kind: AppEnvironment
metadata:
  name: exemplo
spec:
  tier: small
  database:
    size: small
```

Resultado medido: em cerca de 90 s existiam o namespace `lab-exemplo` com quota, LimitRange e NetworkPolicy, e o `Cluster` do CloudNativePG `db` em "Cluster in healthy state" (1 instância), com o Secret `db-app` (usuário, senha e URI) e o serviço `db-rw.lab-exemplo.svc`. O `AppEnvironment` ficou `READY=True` depois da correção da readiness (veja as lições).

Verificações feitas em 24/11/2026:
- **Conexão**: um pod no namespace `lab-exemplo` conectou com a `uri` do Secret `db-app` (PostgreSQL 18.6, usuário e banco `app`).
- **NetworkPolicy**: um pod em `lab-keda` não alcança `db-rw.lab-exemplo.svc` (`pg_isready` sem resposta); o do próprio namespace alcança. O CNI aplica a política.
- **GitOps pelo pedido**: com `spec.gitops`, o Crossplane criou o Application `exemplo` no Argo CD, que sincronizou `platform/exemplo-app` (ConfigMap `exemplo-app`) para `lab-exemplo`; tudo Synced e Healthy.

## Como repetir e demonstrar

```bash
kubectl get appenv,pgdb -A                 # os pedidos e o estado
kubectl -n lab-exemplo get cluster,pods,secret
kubectl get composition,xrd,function       # a API de plataforma
# renderizar sem cluster (CLI: https://cli.crossplane.io/stable/v2.5.0/bin/<os>_<arch>/crossplane)
cd platform/crossplane
crossplane render tests/appenvironment-xr.yaml appenvironment/composition.yaml functions.yaml
# "antes e depois" para o portfólio: apagar platform/environments/exemplo.yaml e ver o namespace e o banco saírem
```

## Lições

| Problema | Causa | Correção |
|---|---|---|
| O roteiro previa `provider-kubernetes` e `provider-helm` e "claims" | O roteiro é do Crossplane v1. No v2 a Composition compõe qualquer recurso e não existem claims: o time cria o XR direto (namespaced) | Sem providers (menos pods); XRs namespaced e cluster-scoped |
| `AppEnvironment` cluster-scoped | Um XR namespaced só pode compor recursos do próprio namespace, e este XR cria o Namespace | `scope: Cluster` no XRD do `AppEnvironment`; o `PostgresDatabase` continua namespaced |
| Kind `Database` do roteiro | Colide com `databases.postgresql.cnpg.io` (`kubectl get database` fica ambíguo) | Kind `PostgresDatabase` (atalho `pgdb`) |
| CLI do Crossplane: `crank` dá 404 | A partir da v2.3 a CLI mora em `cli.crossplane.io` e se chama `crossplane`; o binário de `releases.crossplane.io/.../crossplane` é o controller | Baixar de `cli.crossplane.io/stable/<versão>/bin/<os>_<arch>/crossplane` |
| `AppEnvironment` ficava `READY=False` com tudo criado | `function-auto-ready` só reconhece recursos com condição `Ready`; quota, LimitRange, NetworkPolicy e Application não têm | Anotação `gotemplating.fn.crossplane.io/ready: "True"` nesses; o `Cluster` do CNPG fica pronto pela fase `Cluster in healthy state` |
| App `environments` em retry com "no matches for kind AppEnvironment" | O pedido sincronizou antes de o XRD criar o CRD; o retry com backoff reaplicou a operação antiga | Esperar o retry (sync-waves 50/51/52 e `SkipDryRunOnMissingResource` já ajudam); se prender, `operation: null` e novo sync |
| NetworkPolicy de entrada mínima derrubaria o banco | O operador do CloudNativePG consulta a porta 8000 de cada instância a partir de `cnpg-system` | `cnpg-system` na lista de origens permitidas, junto com `envoy-gateway-system` e `lab-observability` |

## Exercício de CKA ligado a esta etapa

- Crie na mão uma CRD simples (`kubectl explain` e `kubectl get crd -o yaml`) e compare com a CRD que o Crossplane gerou do XRD (`kubectl get crd postgresdatabases.platform.wsiqueira.cloud -o yaml`).
- Explique por que o Crossplane precisou do ClusterRole agregado: leia `kubectl get clusterrole crossplane -o yaml` e ache a regra agregada.
- Escreva uma NetworkPolicy de ingress mínimo e prove, com um pod de teste, quem alcança o banco e quem não alcança.
- Descubra o dono de cada recurso criado (`kubectl get ns lab-exemplo -o yaml`, `ownerReferences`) e o que acontece ao apagar o `AppEnvironment`.

## Pendências

1. **Backup do banco** no Garage (item do roteiro): exige o plugin Barman Cloud; o suporte nativo do CloudNativePG sai na 1.31.
2. **CloudNativePG e cert-manager** foram instalados antes do lab, fora do GitOps; adotar com Argo CD (e decidir o dono do `baseplus-pg`).
3. **Bônus Karpenter** (EKS temporário pelo Crossplane): só com `provider-aws`, credencial restrita e alerta de orçamento.
