# Etapa 3 — Autoscaling orientado a eventos com KEDA (Fase 2 do roteiro)

Feito em 20/11/2026. ADR: `docs/adr/0005-keda-em-vez-de-hpa-puro.md`.

## O que foi montado

| Peça | Arquivo | Detalhe |
|---|---|---|
| KEDA 2.21.1 | `platform/apps/40-keda.yaml` | namespace `lab-keda` (quota 1 vCPU, 2 GiB de limite), ServiceMonitors ligados, `ServerSideApply` por causa dos CRDs grandes |
| ScaledObjects | `platform/autoscaling/scaledobjects.yaml` e `platform/apps/41-autoscaling.yaml` | worker (fila Redis, 0 a 6), api (Prometheus, 1 a 3), loadgen (cron 8h às 22h) |
| Quotas | `platform/guardrails/namespaces.yaml` | `lab-demo` subiu para 2 vCPU, 2 GiB de request, 4 GiB de limite e 30 pods |
| Teste de carga | `platform/loadtest/k6-job.yaml` | k6 1.8.3 como Job, fora do Argo CD: 1 min subindo a 20 req/s, 4 min segurando, 1 min descendo |
| Dashboard | `platform/autoscaling/dashboard.yaml` | "Autoscaling KEDA do demo-pipeline": réplicas, fila, req/s, p95 da API, vCPU-hora evitada |

Os Deployments api, worker e loadgen perderam o campo `replicas`: o KEDA gerencia um HPA por ScaledObject e o Argo CD com `selfHeal` brigaria com ele.

## Resultado do teste de carga (20 req/s por 4 min)

- **worker**: fila em 200+ e 1 → 6 réplicas em menos de 1 minuto. Com 6 réplicas (cerca de 3 pedidos/s cada) a fila continuou subindo até ~580 itens, porque 20 req/s excede a capacidade de 18/s. Esvaziou em cerca de 1 minuto depois do fim do teste.
- **api**: o gatilho de req/s (alvo 8 por réplica) levou de 1 a 3 réplicas em ~35 s, acompanhando 12 → 20 req/s.
- **Descida**: o HPA espera 5 minutos de estabilização antes de reduzir; o worker chegou a 0 réplicas cerca de 4 minutos depois de a fila esvaziar. Como o loadgen contínuo (~2 req/s) reabastece a fila, o worker volta a subir ao ver itens: a partir de zero a primeira réplica leva de dezenas de segundos a alguns minutos (puxa dependências no start), dependendo do nó.
- **vCPU-hora evitada**: [Provável] cerca de 0,26 vCPU em média na última hora, em relação a manter 6 workers e 3 apis fixos (request de 0,05 vCPU por réplica). O painel projeta isso para 24 h, mas só conta o período desde a instalação. A comparação é contra a capacidade máxima fixa, que é o cenário mais favorável ao KEDA; é estimativa de request, não de uso medido.

## Como repetir e demonstrar

```bash
kubectl -n lab-demo delete job k6-spike --ignore-not-found
kubectl apply -f platform/loadtest/k6-job.yaml
# escala a zero de verdade: pausar o gerador de carga contínuo
kubectl -n lab-demo annotate scaledobject loadgen autoscaling.keda.sh/paused-replicas=0
kubectl -n lab-demo annotate scaledobject loadgen autoscaling.keda.sh/paused-replicas-   # retomar
```

## Lições

| Problema | Causa | Correção |
|---|---|---|
| `namespace kube-system is not permitted in project` | O chart do KEDA cria um RoleBinding em `kube-system` (leitor da autenticação do apiserver de extensão) | Destino `kube-system` no AppProject, com a ressalva registrada no arquivo |
| `no matches for kind "ScaledObject"` | A app dos ScaledObjects sincronizou antes dos CRDs | sync-wave 28 (KEDA) e 29 (autoscaling) mais retry |
| Tempo em OOMKilled (limite 768Mi) e gatilho da api em 0 req/s | Todas as requisições sem `traceparent` caíam no mesmo trace id: o auto-instrumentation Python deixa o span raiz do processo (`python -m uvicorn`) no contexto ambiente, então um trace de ~10 mil spans passou de 5 MB (`TRACE_TOO_LARGE`) e sobrecarregou o ingester. O k6 tinha sido suspeito, mas não era a causa | `otel_context.attach(otel_context.Context())` na importação do `api.py` (causa real); k6 também com `traceparent` por requisição; limite do Tempo em 1536Mi |
| Pod do Tempo não pegou o novo limite | StatefulSet não atualiza um pod que nunca fica Ready | `kubectl delete pod tempo-0` |
| Grafana em OOMKilled (limite 384Mi) | Dashboards novos aumentaram o uso de memória | Limite em 768Mi; o uso chegou a ~730Mi, então é preciso acompanhar e subir para 1Gi se voltar a estourar |
| Loadgen travava ~57 s depois de trocar o pod da api | `curl` sem timeout em conexão pendurada | `curl -m 5` no loadgen |
| `git push`/edição sem efeito no repositório | A pasta antiga `platform-lab` não tinha `.git` | Clone novo em `platform-lab-novo`; a pasta antiga está obsoleta |
| Painel de vCPU-hora vazio | Soma de vetores com rótulos diferentes (`deployment="worker"` e `"api"`) não casa | `sum()` em cada parcela |
| Worker oscila entre 0 e 6 com carga baixa | A fila enche enquanto não há réplica, o KEDA acorda o worker e ele esvazia a fila em seguida | Esperado em escala a zero; para produção, imagem com dependências embutidas e `minReplicaCount: 1` se a latência da primeira réplica importar |

A dependência mais importante: o gatilho da api só funciona enquanto a telemetria funciona. Se o Tempo ou o gateway do OTel cair, o KEDA enxerga zero e para de escalar (o scaler da fila do Redis não tem essa fraqueza). Vale um alerta para "métrica de span ausente".

## Exercício de CKA ligado a esta etapa

- Crie na mão um HPA `autoscaling/v2` com `behavior.scaleDown.stabilizationWindowSeconds` e compare com o que o KEDA gerou (`kubectl get hpa keda-hpa-worker -o yaml`).
- Estoure a ResourceQuota de `lab-demo` de propósito (`maxReplicaCount` acima da quota) e ache o `FailedCreate` em `kubectl describe rs`.
- Explique por que o StatefulSet do Tempo não aplicou o novo limite sozinho (`podManagementPolicy`, `updateStrategy` e pod nunca Ready).
- Cadastre um APIService e leia `kubectl get apiservice v1beta1.external.metrics.k8s.io` para entender como o HPA lê métricas externas.

## Pendências

1. Conferir o dashboard "Autoscaling KEDA do demo-pipeline" na interface (os painéis foram validados só por consulta direta ao Prometheus).
2. ~~Alerta de span metrics ausente~~: feito em 23/11 (`TempoDown`, `SpanMetricsAbsent`) com receiver Telegram (ver Passo 8 da Etapa 2).
3. Escala por cron do loadgen: fora das 8h às 22h os SLOs da Etapa 2 ficam sem dados.
