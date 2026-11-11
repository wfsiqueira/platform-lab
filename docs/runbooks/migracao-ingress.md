# Runbook — Migração dos 5 Ingress para Gateway API pelo Cloudflare Tunnel

## Como o tráfego chega hoje (confirmado em 11/11/2026)

```
Internet → Cloudflare (TLS) → túnel kubernetes-tunnel-cloudflare (616ad2e0…, 2 réplicas no cluster)
   ├─ passbolt            → https://passbolt.application:443          (direto, sem nginx)
   ├─ argocd, baseplus-hml, auth-baseplus-hml → https://ingress-nginx-controller.kube-system:443
   └─ qualquer outro      → 404
DNS: external-dns, sources=[ingress], policy=sync, CNAME proxied para 616ad2e0….cfargotunnel.com
```

- **As rotas do túnel são configuradas no painel da Cloudflare** (configuração remota, versão 6). O `cloudflare.ingress` do values do Helm é ignorado.
- O corte de cada host é editar o destino dele em **Zero Trust → Networks → Tunnels → kubernetes-tunnel-cloudflare → Routes**. O estado atual e o alvo estão em `docs/cloudflare-tunnel-rotas.md`.

## Bloqueio 0 — qual túnel atende o tráfego? (resolvido em 11/11/2026)

- Túnel em uso: `kubernetes-tunnel-cloudflare` (`616ad2e0…`), com 2 réplicas no cluster (worker04 e worker06). O `tunnelId: 523115fe…` do values é sobra.
- Configuração **remota** (painel): o cloudflared loga `Updated to new configuration … version=6` com as 4 rotas. O ConfigMap com o curinga não é usado.

## Antes do primeiro corte (dia 2, antes de qualquer drain)

1. **cloudflared com 2 réplicas no values.** Já rodam 2, mas o values diz 1; um `helm upgrade` futuro reduziria para uma. Aplique `platform/cloudflare/tunnel-ingress.yaml`, que só fixa `replicaCount: 2`.
2. **external-dns em modo seguro.** Com `policy: sync`, apagar um Ingress apaga o registro DNS dele. Durante a migração:

   ```bash
   helm repo list   # nome do repo do chart external-dns
   helm upgrade external-dns <repo>/external-dns --version 1.17.0 -n cloudflare --reuse-values \
     --set policy=upsert-only
   ```

   Adicione `gateway-httproute` aos sources só no dia 8, depois que o Envoy Gateway instalar os CRDs da Gateway API: [Provável] sem os CRDs, o external-dns falha ao iniciar com esse source.

   ```bash
   helm upgrade external-dns <repo>/external-dns --version 1.17.0 -n cloudflare --reuse-values \
     --set 'sources={ingress,gateway-httproute}'
   ```

   Antes, veja como o external-dns sabe o destino dos registros hoje (provavelmente uma anotação `external-dns.alpha.kubernetes.io/target` com o CNAME do túnel). Os HTTPRoutes vão precisar da mesma anotação.
3. Guarde o estado atual (fora do repo): `helm get values cloudflare -n cloudflare > ~/cloudflare-values-antes.yaml` e `kubectl get ingress -A -o yaml > ~/ingress-antes.yaml`.
4. Liste as anotações dos Ingress: `kubectl get ingress -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations | keys | join(", "))"'`.
5. Gere um rascunho: `ingress2gateway print --providers=ingress-nginx -A > ~/rascunho-httproutes.yaml` e compare com `platform/gateway/03-routes.yaml`.
6. DNS: **não existe curinga**. Para o `demo`, adicionar a rota no painel do túnel já cria o CNAME automaticamente. Para os hosts existentes, o registro continua vindo das anotações dos Ingress até o external-dns ler os HTTPRoutes.

## Teste do X-Forwarded-Proto (dia 9, com o demo)

O túnel vai falar HTTP com o Envoy. Backends como Argo CD, Passbolt e Keycloak geram URLs e redirecionam conforme o `X-Forwarded-Proto`. Abra `https://demo.wsiqueira.cloud` e procure na resposta do echoserver:

- `x-forwarded-proto=https`: [Provável] o cloudflared envia e o Envoy preserva por vir de IP interno. Siga com HTTP até os backends.
- `x-forwarded-proto=http`: use o **Plano B**.

**Plano B:** manter TLS entre túnel e Envoy, como é hoje com o nginx: um listener HTTPS 443 no Gateway com o certificado emitido pelo cert-manager existente (issuer `cloudflare-letsencrypt`, que exige `config.enableGatewayAPI=true` no release do cert-manager) e o túnel apontando para `https://envoy-homelab…:443` com `noTLSVerify`. Me chame se cair aqui; eu gero os manifestos.

## Casos específicos por host

- **argocd:** hoje o nginx fala HTTPS com o `argocd-server`. Para o Envoy (HTTP), ative `server.insecure` **no mesmo momento** em que mover o host no túnel, porque isso quebra o caminho pelo nginx:
  `helm upgrade argocd argo/argo-cd --version 10.11.6 -n argocd --reuse-values --set 'configs.params.server\.insecure=true'`
  Rollback: o mesmo comando com `=false` e o host de volta ao curinga.
- **passbolt:** já não usa o nginx. Se quiser passá-lo pelo Envoy (opcional), teste a porta 80 antes (comando em `platform/gateway/03-routes.yaml`).
- **baseplus e keycloak:** os Ingress pertencem às apps `baseplus-hml` e `baseplus-platform-hml` do Argo CD. Crie os HTTPRoutes **no repositório da baseplus** (exemplo pronto em `docs/exemplos/baseplus-httproutes.yaml`) e apague os Ingress também por lá; apagar à mão não adianta, porque o Argo CD recria.

## Tradução das anotações mais comuns do nginx

| Anotação nginx | No Envoy Gateway |
| --- | --- |
| `nginx.ingress.kubernetes.io/backend-protocol: HTTPS` | `BackendTLSPolicy` (ou expor o backend em HTTP) |
| `proxy-body-size` | `ClientTrafficPolicy` → `connection.bufferLimit` |
| `proxy-read-timeout` / `proxy-send-timeout` | `BackendTrafficPolicy` → `timeout.http.requestTimeout` |
| `rewrite-target` | filtro `URLRewrite` no HTTPRoute |
| `ssl-redirect` | desnecessário: o HTTPS é feito na Cloudflare |
| WebSocket | suportado por padrão; ajuste só os timeouts |

## Ordem do corte (um host por vez, menor risco primeiro)

| Ordem | Host | Por quê |
| --- | --- | --- |
| 1 | `demo.wsiqueira.cloud` | Novo; valida túnel → Envoy sem risco |
| 2 | `argocd.wsiqueira.cloud` | Só você usa; ajuda a validar o fluxo GitOps |
| 3 | `baseplus-hml` + `auth-baseplus-hml` | Homologação; teste WebSocket (`/api/ws`) e login no Keycloak juntos |
| — | `passbolt.wsiqueira.cloud` | **Não depende do nginx** (o túnel vai direto ao Service). Migrar para o Envoy é opcional. Cuidado: apagar o `passbolt-ingress` com o external-dns em `sync` apaga o DNS do Passbolt |

Para cada host:

1. Descomentar a rota em `03-routes.yaml`, rotular o namespace, commit e esperar o sync.
2. Testar por dentro do cluster, sem mexer no túnel:
   `kubectl run t --rm -it --image=curlimages/curl -- curl -sI -H "Host: <host>" http://envoy-homelab.envoy-gateway-system.svc.cluster.local/`
3. No painel do túnel, editar a rota do host: destino `http://envoy-homelab.envoy-gateway-system.svc.cluster.local:80`, sem `noTLSVerify` nem `originServerName`. Atualizar `docs/cloudflare-tunnel-rotas.md` no mesmo commit.
4. Validar no navegador (login, WebSocket, Keycloak, extensão do Passbolt).
5. **Rollback:** no painel, voltar o destino para `https://ingress-nginx-controller.kube-system.svc.cluster.local:443` com `noTLSVerify` e `originServerName`. O Ingress antigo continua lá.

## Depois de todos os hosts

- Deixar o ingress-nginx e os Ingress por 7 dias sem tráfego.
- Garantir que os 4 hosts têm DNS vindo de HTTPRoute (ou criado pelo túnel), apagar os Ingress, voltar o external-dns para `policy=sync` com `sources={gateway-httproute}` e `helm uninstall ingress-nginx -n kube-system`.
- Avaliar remover o kcert (2024): com o TLS na Cloudflare, ele provavelmente não é mais necessário.
