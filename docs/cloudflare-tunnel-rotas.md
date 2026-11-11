# Rotas do túnel `kubernetes-tunnel-cloudflare` (616ad2e0…)

O túnel é gerenciado pelo **painel da Cloudflare** (configuração remota). Esta página é o registro em Git das rotas, até elas virarem código (ver "Próximo passo").

## Estado em 11/11/2026 (configuração versão 6)

| Ordem | Hostname | Destino (service) | originRequest |
| --- | --- | --- | --- |
| 1 | `passbolt.wsiqueira.cloud` | `https://passbolt.application.svc.cluster.local:443` | `noTLSVerify` |
| 2 | `baseplus-hml.wsiqueira.cloud` | `https://ingress-nginx-controller.kube-system.svc.cluster.local:443` | `noTLSVerify`, `originServerName` |
| 3 | `auth-baseplus-hml.wsiqueira.cloud` | `https://ingress-nginx-controller.kube-system.svc.cluster.local:443` | `noTLSVerify`, `originServerName` |
| 4 | `argocd.wsiqueira.cloud` | `https://ingress-nginx-controller.kube-system.svc.cluster.local:443` | `noTLSVerify`, `originServerName` |
| — | (qualquer outro) | `http_status:404` | — |

O **Passbolt não passa pelo ingress-nginx**: o túnel fala direto com o Service dele. O Ingress `passbolt-ingress` não recebe tráfego externo; hoje ele só serve para o external-dns manter o registro DNS do Passbolt.

## Destino após a migração

| Hostname | Destino |
| --- | --- |
| `demo.wsiqueira.cloud` (novo) | `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80` |
| `argocd.wsiqueira.cloud` | `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80` |
| `baseplus-hml.wsiqueira.cloud` | `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80` |
| `auth-baseplus-hml.wsiqueira.cloud` | `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80` |
| `passbolt.wsiqueira.cloud` | sem mudança (direto no Service); passar pelo Envoy é opcional |

Ao migrar um host, remova também o `originServerName`, que só existia por causa do SNI do nginx.

## Próximo passo: rotas como código

Mudar rota pelo painel não deixa histórico nem revisão. Depois da Fase 0, passe as rotas para Terraform com o provider `cloudflare` (recurso de configuração do túnel cloudflared), num diretório `infra/cloudflare/` deste repositório. É um bom item de portfólio porque junta Terraform, Cloudflare e GitOps.
