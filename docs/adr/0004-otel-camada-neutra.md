# ADR 0004: OpenTelemetry como camada neutra de coleta

- Status: aceito (20/11/2026)
- Contexto: Etapa 2 (observabilidade) do platform-lab

## Contexto

O lab precisa de traces, logs e métricas. Cada backend (Dynatrace, Datadog, Grafana Cloud, Tempo/Loki/Prometheus) traz seu próprio agente e seu próprio formato. Instrumentar a aplicação para um deles cria dependência: trocar de backend exige reinstrumentar o código e reimplantar tudo.

## Decisão

As aplicações emitem telemetria em OTLP, o padrão aberto do OpenTelemetry. O caminho é:

`app (auto-instrumentação do Operator) -> agent (DaemonSet) -> gateway (Deployment) -> backends`

- **Agent** (um por nó): recebe OTLP das apps e lê os logs dos contêineres dos namespaces das aplicações.
- **Gateway**: único ponto que conhece os backends. Os exporters ficam aqui: Tempo (traces), Loki por OTLP (logs) e Prometheus por remote write (métricas).
- **Operator**: injeta a auto-instrumentação por anotação no pod, sem mexer na imagem.

## Consequências

- Trocar ou somar um backend é mudar os exporters do gateway, sem tocar nas aplicações.
- É possível enviar o mesmo dado a dois destinos ao mesmo tempo (por exemplo, Tempo e Dynatrace) para comparar antes de migrar.
- Mais uma peça para operar (Operator, agent, gateway) e mais um salto de rede por sinal.
- A auto-instrumentação cobre bibliotecas conhecidas; código próprio sem spans manuais aparece só como tempo dentro do span pai.

## Alternativas descartadas

- **Agentes proprietários** (OneAgent, Datadog Agent): ótima cobertura, mas prendem a aplicação ao fornecedor.
- **Apps falando direto com Tempo e Loki**: menos peças, porém o endereço dos backends vai para cada aplicação.

## Quando reabrir

Se a cobertura da auto-instrumentação não bastar para uma linguagem em uso, ou se o custo de memória do agent por nó pesar nos workers de 7,4 GiB.
