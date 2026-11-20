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

## Passo 2 — Garage (S3) (feito em 20/11/2026)

Arquivos: `platform/apps/31-garage.yaml` (Application) e `platform/observability/garage/` (`garage.yaml` com StatefulSet de 1 réplica, e `bootstrap.sh`).

Ordem: o Secret `garage-secrets` (rpc-secret e admin-token) é criado fora do Git; o Argo CD sobe o pod; o `bootstrap.sh` aplica o layout (uma zona, 10 GiB), cria os buckets `loki` e `tempo`, uma chave por bucket e grava os Secrets `loki-s3` e `tempo-s3` sem imprimir valores.

| Problema | Causa | Correção |
| --- | --- | --- |
| Pod em CrashLoop (45 reinícios) | `/health` do Garage responde 503 até existir layout, e o liveness matava o pod antes do bootstrap | Liveness por TCP na porta RPC; readiness continua em `/health` (pod só fica 1/1 depois do layout) |

Por que não o AWS Emulator do cluster: o estado dele fica em `emptyDir` e some quando o pod reinicia, e a observabilidade não deve depender de uma ferramenta de teste.

## Passo 3 — Loki, Tempo e correlação no Grafana (feito em 20/11/2026)

- `platform/apps/32-loki.yaml`: chart `grafana/loki` 7.7.0, modo SingleBinary, chunks no Garage, retenção de 72 h.
- `platform/apps/33-tempo.yaml`: chart `grafana/tempo` 1.24.4, traces no Garage, receptor OTLP (4317 e 4318) e metrics-generator escrevendo no Prometheus (service graph e span metrics).
- `platform/apps/30-observability.yaml`: datasources Loki e Tempo, exemplars do Prometheus apontando para o Tempo, log para trace por `trace_id` e trace para logs por `service.name`.
- As credenciais S3 entram por variável de ambiente (`extraEnvFrom`) e `config.expand-env`, então nenhum segredo vai para o Git.
- Lição: no Grafana, `$` literal em provisionamento precisa de `$$`.

Verificação: `/api/datasources/uid/loki/health` e `/tempo/health` devolvem OK.

## Passo 3b — Grafana público com Cloudflare Access (feito em 20/11/2026)

Caminho: navegador, Cloudflare Access, túnel, Envoy (`homelab`), HTTPRoute `grafana`, Service do Grafana.

Ordem que importa: primeiro a aplicação Access, depois a rota do túnel. Assim o hostname nunca fica público sem proteção.

1. Zero Trust, Access controls, Applications: aplicação `grafana` (self-hosted) em `grafana.wsiqueira.cloud`, com a política reutilizável "Somente Willian" (mesma do Argo CD).
2. Túnel `kubernetes-tunnel-cloudflare`: rota publicada `grafana.wsiqueira.cloud` para `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80`.
3. Git: `HTTPRoute grafana` em `platform/gateway/03-routes.yaml` e `grafana.ini` (`root_url`, `allow_sign_up: false`, anônimo desligado, cookie seguro) no `kube-prometheus-stack`.

Verificação: com o IP público forçado, `/`, `/api/health`, `/api/datasources` e `/metrics` respondem 302 para `*.cloudflareaccess.com`.

Lições:

| Sintoma | Causa | O que fazer |
| --- | --- | --- |
| `curl` falha com código 7 e `dig` mostra `192.168.3.164` | O roteador local (UniFi, 192.168.3.1) guardou o registro criado pelo external-dns antes da rota do túnel | Conferir pelo DNS-over-HTTPS (`cloudflare-dns.com/dns-query`) ou forçar o IP com `curl --resolve`; o cache expira sozinho |
| Dois criadores do mesmo registro | O external-dns cria o registro a partir do HTTPRoute e o túnel o substitui por um registro do tipo Tunnel proxied | O resultado final é o do túnel; manter o external-dns em `upsert-only` |

Defesa em duas camadas: o Access barra quem não é você; o login do Grafana (senha em `~/grafana-admin-lab.txt`) vale como segunda barreira.

## Próximos passos

4. OpenTelemetry Operator e Collector (DaemonSet e gateway).
5. Duas apps Python com fila, com auto-instrumentação pela anotação do Operator.
6. Correlação trace → logs, métrica → trace (exemplars) e service graph.
7. Dois SLOs (disponibilidade e latência p95) com Sloth ou Pyrra e alerta de burn rate.
8. ADR: OpenTelemetry como camada de coleta neutra, para trocar Dynatrace ou Datadog sem reinstrumentar.
