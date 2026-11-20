# ADR 0005: KEDA em vez de HPA puro; Karpenter fora do homelab

- Status: aceito (20/11/2026)
- Contexto: Etapa 3 (autoscaling orientado a eventos) do platform-lab

## Contexto

O HPA nativo escala por CPU e memória (e por métricas custom só com um adaptador à parte). Um consumidor de fila quase não usa CPU enquanto a fila cresce, então o HPA reage tarde. Também não escala até zero réplicas.

## Decisão

Usar o KEDA (chart 2.21.1, namespace `lab-keda`), com três gatilhos sobre o demo-pipeline:

- **worker**: scaler `redis`, alvo de 10 itens na lista `orders` por réplica, de 0 a 6 réplicas.
- **api**: scaler `prometheus` sobre as métricas de span do OTel (`traces_spanmetrics_calls_total`), alvo de 8 req/s por réplica, de 1 a 3 réplicas.
- **loadgen**: scaler `cron`, 1 réplica das 8h às 22h (America/Sao_Paulo) e zero fora disso. É a versão Kubernetes das Lambdas com EventBridge que desligavam ambientes não produtivos.

O KEDA cria e gerencia um HPA por ScaledObject. Por isso os Deployments não declaram `replicas` (o Argo CD com `selfHeal` brigaria com o KEDA).

## Alternativas descartadas

- **HPA puro**: sem escala a zero e cego ao tamanho da fila.
- **RabbitMQ ou Kafka como fila**: o roteiro sugeria um dos dois. Mantivemos o Redis que já existe. O scaler de lista do Redis exercita o mesmo mecanismo do KEDA e evita um broker a mais (~500 MiB) em nós que já estão entre 40% e 57% de memória. Troca futura é só mudar o `trigger`.
- **Karpenter**: provisiona nós, e o homelab tem 7 VMs fixas no vCenter. Só faz sentido em EKS; fica como bônus opcional da Fase 3 (Crossplane), com alerta de orçamento na AWS antes.

## Consequências

- Escala a zero economiza request de CPU e memória, mas a volta tem custo: o worker leva dezenas de segundos para ficar pronto porque o init container instala as dependências com `pip` a cada pod. Em produção, a imagem já traria as dependências.
- O scaler `prometheus` depende de a telemetria estar saudável: se o Tempo cair, o gatilho da api enxerga zero e para de escalar. A fila do Redis não tem essa dependência.
- O KEDA adiciona três pods (operator, metrics apiserver, webhooks) e um destino extra no AppProject (`kube-system`, para o RoleBinding de autenticação do metrics apiserver).
- Os limites do `maxReplicaCount` e a quota do namespace `lab-demo` precisam caminhar juntos; senão o `FailedCreate` do ReplicaSet aparece só depois do pico.
