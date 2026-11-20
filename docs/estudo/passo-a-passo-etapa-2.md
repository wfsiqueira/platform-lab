# Etapa 2 — Observabilidade (Fase 1 do roteiro)

Meta: Prometheus, Loki, Tempo e um armazenamento S3 sob o Grafana, com o OpenTelemetry como camada de coleta neutra, mais duas apps Python com fila gerando telemetria e dois SLOs. Entregável: dashboard de SLO e um GIF indo do alerta ao trace e ao log da requisição com erro.

## Decisões desta etapa

| Decisão | Escolha | Por quê |
| --- | --- | --- |
| Backend de métricas | kube-prometheus-stack (Prometheus + Alertmanager + Grafana), sem Mimir | O cluster não tinha Prometheus nem Grafana (o roteiro supunha que sim). Mimir pesa na memória dos workers de 7,4 GiB; entra depois via `remote_write` se valer a pena |
| Armazenamento de objetos | **Garage** (não MinIO) | A edição comunitária do MinIO deixou de publicar imagens e binários em out/2025 e o repositório foi arquivado em 2026 (fonte: reportagens da época). Garage é leve (um binário, sem JVM) e fala S3 |
| App de demonstração | Duas apps Python com fila no meio | Leve e reaproveitável na etapa do KEDA |
| Acesso ao Grafana | `kubectl port-forward` por enquanto | Expor na internet exige autenticação na frente (Cloudflare Access); decidir depois |

## Orçamento de recursos

Namespace `lab-observability`, definido em `platform/guardrails/namespaces.yaml`: 3 vCPU de request, 4 GiB de request de memória, 8 GiB de limite, 10 PVCs. Cada worker tinha cerca de 4–5 GiB livres no início da etapa.

## Passo 1 — Prometheus, Alertmanager e Grafana (feito em 20/11/2026)

O que entrou no Git:

- `bootstrap/appproject-platform-lab.yaml`: três repositórios Helm novos em `sourceRepos` (prometheus-community, grafana, open-telemetry). Esse objeto não é gerido pelo Argo CD: aplique com `kubectl apply -f`.
- `platform/guardrails/namespaces.yaml`: namespace `lab-observability` com `ResourceQuota` e `LimitRange`.
- `platform/apps/30-observability.yaml`: Application do `kube-prometheus-stack` na versão 93.6.0.

Antes do primeiro sync, crie o Secret do Grafana (não vai para o Git):

```bash
PW=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
umask 077; printf 'usuario: admin\nsenha: %s\n' "$PW" > ~/grafana-admin-lab.txt
kubectl -n lab-observability create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$PW"
```

Acesso: `kubectl -n lab-observability port-forward svc/kube-prometheus-stack-grafana 3000:80` e abra `http://localhost:3000`.

### Verificação

```bash
kubectl -n argocd get app kube-prometheus-stack            # Synced / Healthy
kubectl get --raw '/api/v1/namespaces/lab-observability/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/targets?state=active'
```

Resultado em 20/11: 58 de 59 alvos *up* (apiserver, kubelet, coredns, node-exporter, kube-state-metrics e o próprio Prometheus); o Grafana foi o último a ficar pronto.

### Lições

| Problema | Causa | Correção |
| --- | --- | --- |
| Sync preso com "namespace kube-system is not permitted in project" | O chart cria o Service do CoreDNS em `kube-system`, e o AppProject do lab não escreve ali | `coreDns.enabled: false` e um ServiceMonitor próprio lendo o Service `kube-dns` existente |
| Dashboards de CoreDNS vazios | Esperam `job="coredns"` | `relabelings` trocando o `job` no ServiceMonitor |
| Alertas de etcd, scheduler, controller-manager e kube-proxy | No kubeadm eles escutam só em `127.0.0.1` | Desligados no chart; veja o exercício abaixo |
| `kube-state-metrics` duplicado | Já existe um release em `kube-system`, sem scrape | Mantido o do chart; remover o antigo depois de conferir que nada o usa |

### Exercício de CKA ligado a este passo

Os componentes do control plane expõem métricas em `127.0.0.1`. Para o Prometheus enxergá-los, edite os manifestos estáticos em `/etc/kubernetes/manifests/` (`kube-scheduler.yaml`, `kube-controller-manager.yaml`) trocando `--bind-address=127.0.0.1` por `0.0.0.0`, e o `metrics-bind-address` do kube-proxy no ConfigMap `kube-proxy`. Para o etcd, use `--listen-metrics-urls`. É exercício clássico de edição de static pod e de troubleshooting do control plane; só reative depois os `kube*.enabled` do chart.

## Próximos passos

2. Garage (S3) no `lab-observability`, com buckets para Loki e Tempo.
3. Loki e Tempo apontando para o Garage, conectados ao Grafana como data sources.
4. OpenTelemetry Operator e Collector (DaemonSet e gateway).
5. Duas apps Python com fila, com auto-instrumentação pela anotação do Operator.
6. Correlação trace → logs, métrica → trace (exemplars) e service graph.
7. Dois SLOs (disponibilidade e latência p95) com Sloth ou Pyrra e alerta de burn rate.
8. ADR: OpenTelemetry como camada de coleta neutra, para trocar Dynatrace ou Datadog sem reinstrumentar.
