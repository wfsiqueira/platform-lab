# Roteiro de estudo — Laboratório de Engenharia de Plataforma

Nov 11, 2026 · @Willian Siqueira

## Objetivo e premissas

Em 12 semanas, com 2 h por dia e a CKA no meio do caminho, o resultado é um repositório público `platform-lab` que mostra um caminho dourado (golden path) completo: um desenvolvedor pede um serviço no Backstage e recebe repositório, deploy via ArgoCD, banco provisionado pelo Crossplane, autoscaling com KEDA e telemetria em OTel, sem abrir ticket para o SRE.

**Premissas do seu homelab**

- Cluster kubeadm sobre VMware: 1 control-plane + 6 workers, cada nó com 8 vCPU e 7,4 GiB de RAM, Kubernetes v1.33. Uso real medido: CPU perto de 1% e cerca de 29 GiB de RAM livres somando os workers. Já rodam Home Assistant, Passbolt, Grafana, Prometheus e Postfix.
- Domínio `wsiqueira.cloud` e UniFi Gateway Max para expor serviços.
- Ritmo: 2 h por dia (cerca de 10 h por semana em dias úteis). A CKA entra em paralelo nas semanas 1 a 6 (veja o cronograma integrado).

**Regra do laboratório:** tudo entra no cluster via Git (ArgoCD). Nada de `kubectl apply` manual, porque o repositório é o portfólio.

## Arquitetura alvo e decisões-chave

A decisão mais importante: no homelab o autoscaling fica com **KEDA**. O Karpenter entra só como bônus opcional, num EKS temporário.

| Camada | Ferramenta | Por quê | Confiança |
| --- | --- | --- | --- |
| GitOps | ArgoCD (app-of-apps) | Você já usa em produção; instala todo o resto | \[Certeza\] |
| Portal | Backstage | Catálogo, templates e TechDocs | \[Certeza\] |
| Infra self-service | Crossplane v2 + Composition Functions | API de plataforma em cima do Kubernetes | \[Provável\] que a v2 seja a versão atual; confira a doc antes |
| Banco local | CloudNativePG | Postgres operado por CRD, que o Crossplane compõe | \[Certeza\] |
| Autoscaling de pods | KEDA | Funciona em qualquer cluster, escala por fila, métrica ou cron | \[Certeza\] |
| Autoscaling de nós | Karpenter (opcional) | Precisa de provedor de nuvem; não há provedor oficial para vSphere | \[Provável\] |
| Telemetria | OpenTelemetry Operator + Collector | Instrumentação neutra de fornecedor | \[Certeza\] |
| Backends | Prometheus atual (Mimir só se sobrar memória), Loki e Tempo em modo monolítico, Grafana | Stack LGTM; correlação entre trace, log e métrica | \[Certeza\] |
| Armazenamento | MinIO (S3) sobre openebs-hostpath, que já está instalado | Loki, Tempo e Mimir guardam dados em objeto | \[Certeza\]: volume local, sem réplica e preso ao nó. A resiliência fica na aplicação (CloudNativePG com réplicas) |
| Segredos | External Secrets + Vault ou SOPS | Repositório público sem nenhum segredo | \[Certeza\] |
| Entrada de tráfego | Gateway API (Envoy Gateway ou Traefik), no lugar do ingress-nginx | O ingress-nginx da comunidade foi aposentado em mar/2026 e não recebe mais patches de segurança | \[Certeza\], se o seu for o da comunidade |

**Fluxo de ponta a ponta:** Backstage (template) → cria repo + manifestos → ArgoCD sincroniza → Crossplane cria o banco → app sobe com KEDA → OTel envia telemetria → Grafana mostra SLO.

## Cronograma integrado com a CKA

A CKA é feita no fim da semana 6. Até lá, as 2 h diárias se dividem entre prova e laboratório. Depois da prova, as 2 h vão inteiras para o lab.

| Semanas | Laboratório (1 h/dia) | CKA (1 h/dia) | Ligação entre os dois |
| --- | --- | --- | --- |
| 1 a 2 | Fase 0: GitOps, Gateway API, upgrade do cluster | Arquitetura do cluster, kubeadm, backup e restore do etcd, RBAC | O upgrade 1.33 com kubeadm é exercício de prova |
| 3 a 4 | Fase 1: OTel e LGTM | Workloads, scheduling (affinity, taints, requests), storage (PV, PVC, StorageClass) | Loki, Tempo e MinIO usam PVC no openebs-hostpath |
| 5 | Fase 2: KEDA | Services, NetworkPolicy, Gateway API, DNS, Helm e Kustomize | O KEDA é instalado via Helm e depende de CRDs |
| 6 | Pausa no lab | 2 h/dia: dois simulados killer.sh, revisão dos erros, troubleshooting de nó e de control plane | Prova no fim da semana |
| 7 a 8 | Fase 3: Crossplane (2 h/dia) | — | CRDs e operators aparecem de novo aqui |
| 9 a 11 | Fase 4: Backstage (2 h/dia) | — | — |
| 12 | Fase 5: game day e portfólio (2 h/dia) | — | Publicar o selo da CKA junto com o vídeo do lab |

- &#91;Provável\] Desde 2025 o temário da CKA inclui Helm, Kustomize, Gateway API e CRDs/operators, todos usados no lab. Confira o currículo oficial atual antes de começar.
- Pratique sempre com a doc oficial aberta, como na prova. Treine `kubectl` imperativo (`--dry-run=client -o yaml`) para ganhar tempo.
- Se os simulados da semana 6 ficarem abaixo de 70% \[Chute de margem segura\], adie a prova uma semana e empurre o resto do cronograma.

## Fase 0 — Fundação (semanas 1 a 2)

Ao fim desta fase, o cluster se reconstrói a partir do Git e os serviços que você já usa ficam protegidos do laboratório.

- [ ] Conferir requests e limits por nó com kubectl describe node. Há cerca de 29 GiB livres no total, mas cada nó tem só 7,4 GiB: nenhum componente deve pedir mais de 2 a 3 GiB.
- [ ] Criar namespaces `platform-*` com ResourceQuota e LimitRange, e uma PriorityClass alta para Home Assistant e Passbolt.
- [ ] Criar o repo público `platform-lab` com a estrutura `bootstrap/`, `platform/` (componentes), `apps/`, `docs/adr/` e `docs/diagrams/`.
- [ ] Instalar ArgoCD pelo próprio repo (app-of-apps ou ApplicationSet).
- [ ] Migrar do ingress-nginx para Gateway API com cert-manager, começando pelo Passbolt (exposto na internet). Use o ingress2gateway para converter os Ingress existentes. Depois, alinhar as versões (worker03 está em 1.33.3, os demais em 1.33.1) e fazer o upgrade do cluster com kubeadm, que é treino direto para a CKA.
- [ ] Configurar External Secrets (ou SOPS) e um `pre-commit` com gitleaks para nunca subir segredo.
- [ ] Escrever o ADR-001: "Por que GitOps como única via de mudança".

**Entregável:** README com diagrama da arquitetura e um `make bootstrap` (ou script) que sobe o ArgoCD do zero.

## Fase 1 — Observabilidade com OTel e LGTM (semanas 3 a 4)

Esta fase vem primeiro porque é a mais cobrada nas vagas de SRE que você está disputando, e as fases seguintes dependem dela para medir resultado.

- [ ] Subir MinIO como armazenamento de objetos para Loki, Tempo e Mimir.
- [ ] Instalar Loki, Tempo e Mimir (ou conectar o Prometheus atual via remote\_write), e conectar tudo ao Grafana que você já tem.
- [ ] Instalar o OpenTelemetry Operator e um Collector em dois modos: DaemonSet (logs e métricas do nó) e Deployment (gateway).
- [ ] Rodar uma app de demonstração. Opções: o OpenTelemetry Demo (mais pesado) ou dois serviços seus, em Python, com uma fila no meio.
- [ ] Ativar auto-instrumentação via anotação do Operator.
- [ ] Configurar a correlação: trace → logs (trace\_id no log), métricas → trace (exemplars) e service graph no Tempo.
- [ ] Definir dois SLOs (disponibilidade e latência p95) com Sloth ou Pyrra, com alerta de burn rate em várias janelas.
- [ ] ADR-002: "OTel como camada de coleta neutra: trocar Dynatrace ou Datadog sem reinstrumentar".

**Entregável:** dashboard de SLO + GIF navegando de um alerta até o trace e o log da requisição com erro.

**Gancho de entrevista:** compare com o Dynatrace (OneAgent, PurePath) que você usou na Hitss. Explique o que muda em custo, lock-in e esforço de operação.

## Fase 2 — Autoscaling orientado a eventos com KEDA (semana 5)

O objetivo é mostrar escala por demanda real (fila, métrica de negócio), não só por CPU, que é o limite do HPA.

- [ ] Instalar KEDA via ArgoCD.
- [ ] Colocar um RabbitMQ ou Kafka (você já operou os dois) entre os serviços da demo.
- [ ] Criar um ScaledObject por tamanho de fila, com escala até zero do consumidor.
- [ ] Criar um segundo ScaledObject com o scaler de Prometheus, usando uma métrica vinda do OTel (ex.: requisições por segundo).
- [ ] Criar um ScaledObject de cron para desligar ambientes fora do horário. É a versão Kubernetes das Lambdas com EventBridge da Hitss.
- [ ] Gerar carga com k6 e registrar em um dashboard: tamanho da fila × réplicas × latência.
- [ ] ADR-003: "KEDA em vez de HPA puro; Karpenter fora do homelab".

**Entregável:** gráfico de antes e depois do teste de carga + número de custo evitado com escala a zero (estimado em vCPU-hora).

**Bônus opcional (Karpenter):** criar um EKS temporário pelo Crossplane na Fase 3, instalar Karpenter, mostrar consolidação de nós e destruir no mesmo dia. Configure um alerta de orçamento na AWS antes.

## Fase 3 — Infraestrutura self-service com Crossplane (semanas 7 a 8)

Aqui você transforma sua experiência de 50 módulos Terraform no PagBank em uma API de plataforma. Essa é a história mais forte do portfólio.

- [ ] Instalar Crossplane e os providers `provider-kubernetes` e `provider-helm` (rodam 100% local). Opcional: `provider-aws` com credencial restrita.
- [ ] Instalar o CloudNativePG.
- [ ] Criar uma XRD `Database` (tamanho: small, medium) e uma Composition que gera um Cluster do CloudNativePG, um Secret de conexão e uma política de backup no MinIO.
- [ ] Criar uma XRD `AppEnvironment` que compõe namespace, ResourceQuota, NetworkPolicy, `Database` e Application do ArgoCD.
- [ ] Usar Composition Functions (`function-patch-and-transform` ou `function-go-templating`) em vez de patches legados.
- [ ] Escrever testes das Compositions com `crossplane render` no CI (GitHub Actions).
- [ ] ADR-004: "Crossplane × Terraform + Atlantis: quando usar cada um". Use sua vivência no PagBank como base.

**Entregável:** um YAML de 10 linhas que um time aplica e recebe ambiente completo com banco, documentado com antes e depois.

**Gancho de entrevista:** "No PagBank os times abriam PR no Atlantis; aqui eles pedem um recurso de alto nível e a plataforma resolve o resto."

## Fase 4 — Portal do desenvolvedor com Backstage (semanas 9 a 11)

O Backstage é a fase mais trabalhosa: é uma aplicação Node/TypeScript que você constrói e empacota, não só um Helm chart. Por isso ela ganha três semanas.

- [ ] Gerar o app com `npx @backstage/create-app`, criar a imagem com um pipeline no GitHub Actions e fazer o deploy via ArgoCD, com Postgres do CloudNativePG.
- [ ] Autenticação via GitHub OAuth.
- [ ] Catálogo: registrar todos os componentes do lab com `catalog-info.yaml` (owner, system, dependências).
- [ ] Plugins: Kubernetes, ArgoCD e um link ou embed do Grafana por serviço.
- [ ] TechDocs: publicar os ADRs e runbooks do repo dentro do portal.
- [ ] Software Template "Novo serviço Python": cria o repo, o Dockerfile, o pipeline e os manifestos com anotação OTel e ScaledObject, e um claim `AppEnvironment` do Crossplane.
- [ ] Medir o tempo do template até o primeiro deploy saudável. Esse é o seu número de DevEx.
- [ ] ADR-005: "Golden path opinativo em vez de liberdade total".

**Entregável:** vídeo de 3 a 5 minutos: clicar no template → serviço no ar com banco, autoscaling, dashboards e SLO, sem tocar no terminal.

## Fase 5 — SRE, game day e acabamento (semana 12)

A última semana prova que a plataforma aguenta falhas e deixa o repo pronto para um recrutador entender em 2 minutos.

- [ ] Rodar um game day com Chaos Mesh ou LitmusChaos: matar pods, injetar latência, derrubar um worker.
- [ ] Registrar o consumo de error budget e escrever um postmortem sem culpados em `docs/postmortems/`.
- [ ] Escrever runbooks para os alertas de SLO, linkados na anotação do alerta.
- [ ] Revisar o README: problema, arquitetura (diagrama), demo em vídeo, decisões (ADRs), números, o que faria diferente.
- [ ] Rodar gitleaks no histórico inteiro antes de divulgar.
- [ ] Publicar no LinkedIn: um post por fase, ou um post final com o vídeo.

## Como transformar o laboratório em material de entrevista

O laboratório também resolve a sua dificuldade de se apresentar: você passa a ter um roteiro pronto, com demo e números.

| Pergunta típica | Fase que responde | O que mostrar |
| --- | --- | --- |
| "Como você reduz o trabalho repetitivo dos times?" | 3 e 4 | O YAML de 10 linhas e o template do Backstage |
| "Como você define e acompanha SLO?" | 1 e 5 | Dashboard de burn rate e o postmortem do game day |
| "Como você controla custo em Kubernetes?" | 2 | Escala a zero e a conta de vCPU-hora |
| "Terraform ou Crossplane?" | 3 | O ADR-004 com o caso do PagBank |
| "Conte um incidente." | 5 | O postmortem, na estrutura STAR |

- Prepare um pitch de 90 segundos: problema → o que construí → um número → o que aprendi.
- Deixe o vídeo da Fase 4 fixado no topo do LinkedIn e no Workana.
- Em entrevistas remotas, ofereça compartilhar a tela e mostrar o portal ao vivo.

## Riscos, conciliação com a CKA e fatos que faltam

O maior risco é o lab competir com a CKA e com as entrevistas e nenhum dos três sair. Defina a ordem antes de começar.

**Conciliação com a CKA:** decidido: CKA em paralelo com as Fases 0 a 2 e prova no fim da semana 6, conforme o cronograma integrado.

**Riscos**

- Faltar recurso no cluster e derrubar Home Assistant ou Passbolt. Mitigação: quotas e PriorityClass da Fase 0.
- Vazar segredo ou nome interno de cliente no repo público. Mitigação: gitleaks e nenhum dado da Claro, do PagBank ou da Zup.
- Gastar semanas configurando o Backstage. Mitigação: limite de 3 semanas; se estourar, entregue só catálogo + template.
- Custo na AWS no bônus do Karpenter. Mitigação: alerta de orçamento e destruir o cluster no mesmo dia.

**Fatos que faltam para ajustar o plano**

- [ ] Respondido: 6 workers de 8 vCPU e 7,4 GiB, com cerca de 29 GiB livres no total.
- [ ] Respondido: openebs-hostpath (local) e NGINX Ingress. Falta confirmar se é o ingress-nginx da comunidade ou o NGINX Ingress da F5.
- [ ] Respondido: 2 h por dia.
- [ ] Respondido: CKA junto com o lab.
