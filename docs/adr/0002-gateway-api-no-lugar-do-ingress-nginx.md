# ADR-0002 — Gateway API (Envoy Gateway) no lugar do ingress-nginx

- **Status:** proposto (vira "aceito" quando o último host for migrado)
- **Data:** 2026-11

## Contexto

- O ingress-nginx da comunidade (v1.15.1 no `kube-system`) foi aposentado em março de 2026: sem novas releases, correções ou patches de segurança.
- Ele atende 5 hosts: Passbolt (cofre de senhas), Argo CD, a aplicação baseplus (HTTP + WebSocket) e o Keycloak dela.
- O tráfego externo chega por Cloudflare Tunnel; o TLS público termina na Cloudflare e o ingress-nginx é só ClusterIP.
- A Gateway API é o sucessor oficial do Ingress e faz parte do temário da CKA.

## Decisão

Adotar a Gateway API com o **Envoy Gateway**: um `Gateway` compartilhado no namespace `gateway`, com um listener HTTP para `*.wsiqueira.cloud`, rotas liberadas só para namespaces com `gateway-access=true`, e um Service ClusterIP de nome fixo (`envoy-homelab`) como destino do cloudflared. A migração é feita host a host, trocando o destino no túnel, com rollback imediato.

## Alternativas consideradas

- **Manter o ingress-nginx:** risco de segurança crescente, inclusive no cofre de senhas.
- **Istio como implementação da Gateway API:** já estava instalado, mas na 1.21 (sem suporte e incompatível com 1.33+). Atualizar exigiria cerca de 9 upgrades de minor. Removido; service mesh pode voltar numa fase própria.
- **NGINX Ingress da F5:** mantido, mas continua preso à API Ingress e a anotações proprietárias.
- **Traefik:** suporta Gateway API; o Envoy Gateway foi escolhido por ser projeto CNCF focado só em Gateway API.
- **Cilium Gateway:** exigiria trocar o CNI (Calico).

## Consequências

- (+) Fim da exposição a CVEs sem correção; separação de papéis entre infra (Gateway) e times (rotas).
- (+) O corte é reversível em segundos, trocando o destino no cloudflared.
- (−) As anotações do nginx precisam ser traduzidas para políticas do Envoy Gateway.
- (−) O external-dns precisa ser ajustado antes de apagar os Ingress, para não apagar registros DNS.
