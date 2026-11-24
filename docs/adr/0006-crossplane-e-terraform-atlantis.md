# ADR 0006: Crossplane para a API de plataforma; Terraform + Atlantis para a infraestrutura de base

- Status: aceito (24/11/2026)
- Contexto: Etapa 4 (infraestrutura self-service) do platform-lab. O roteiro chamava este ADR de "ADR-004", mas esse número já é do ADR da camada neutra do OTel.

## Contexto

No PagBank, os times pediam infraestrutura abrindo PR em módulos Terraform e esperando o plan no Atlantis; o SRE mantinha o Atlantis e os módulos. Funciona, mas o time de produto precisa conhecer o módulo certo, as variáveis e o fluxo de revisão. O lab quer o oposto: o time pede um recurso de alto nível e a plataforma resolve o resto.

## Decisão

- **Crossplane v2 (chart 2.5.0)** expõe duas APIs do grupo `platform.wsiqueira.cloud`:
  - `PostgresDatabase` (namespaced; `size: small|medium`): compõe um `Cluster` do CloudNativePG.
  - `AppEnvironment` (cluster-scoped; `tier`, `database`, `gitops`): compõe Namespace, ResourceQuota, LimitRange, NetworkPolicy, um `PostgresDatabase` e, se pedido, um Application do Argo CD.
- Composições em **pipeline com Composition Functions** (`function-go-templating` e `function-auto-ready`), testadas sem cluster com `crossplane render` no CI.
- **Sem providers.** No v2 a Composition compõe qualquer recurso do Kubernetes, então `provider-kubernetes` e `provider-helm` (previstos no roteiro) ficaram de fora: menos pods e menos superfície em nós que já estão entre 40% e 60% de memória.
- O pedido do time é um YAML no Git (`platform/environments/`), aplicado pelo Argo CD.

## Quando usar cada um

| Situação | Ferramenta | Por quê |
|---|---|---|
| Rede, contas, VPC, EKS, IAM de base: poucos recursos, mudam pouco, exigem revisão humana do plan | Terraform + Atlantis | O plan em PR é o controle; o estado e o histórico de mudança são o que a auditoria quer |
| Recurso que o time de produto pede com frequência e com poucos parâmetros (banco, ambiente, fila) | Crossplane | Reconcilia continuamente, expõe uma API pequena e o time não precisa conhecer o módulo |
| Infra fora do Kubernetes, sem cluster de gestão disponível | Terraform | O Crossplane exige um control plane rodando antes |
| Detecção e correção de drift | Crossplane | O controller reaplica; no Terraform só aparece no próximo plan |

Regra prática: Terraform cria o chão (inclusive o cluster onde o Crossplane roda); Crossplane cria o que os times pedem em cima dele.

## Alternativas descartadas

- **Helm/Kustomize puros por ambiente**: sem API própria, sem validação de entrada (enum de tamanho, defaults) e sem composição entre banco e namespace.
- **Operators à mão, um por recurso**: cada um tem API diferente; o Crossplane unifica o pedido.
- **Backstage Scaffolder criando os manifestos direto**: fica para a Fase 4; ele vai gerar um `AppEnvironment` em vez de manifestos soltos.

## Consequências

- O Crossplane vira dependência de runtime (core, rbac-manager e dois pods de função, ~230 MiB no total medido) e o RBAC dele precisa listar os tipos que as Compositions criam (`platform/crossplane/rbac.yaml`).
- Apagar o arquivo do ambiente com `prune` ligado apaga namespace e banco. No lab é desejado; em produção exigiria `deletionPolicy` e backup.
- O CloudNativePG e o cert-manager já existiam no cluster fora do GitOps; a Etapa 4 usa o CNPG como está e deixa a adoção pelo Argo CD como pendência.
- O backup usa o plugin Barman Cloud (o suporte nativo do CNPG sai na 1.31) e o Garage. A chave do bucket é compartilhada entre os bancos do lab e copiada para cada namespace pelo Crossplane; em produção seria uma chave por banco ou identidade de carga de trabalho.
- O plugin roda em `cnpg-system`, compartilhado com outro projeto; o AppProject ganhou esse destino. O `delete` de Secrets entrou no ClusterRole agregado do Crossplane (ele já lia e gravava Secrets em todo o cluster).
