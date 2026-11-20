# Runbook — Retirada do ingress-nginx e do kcert

**Pré-condição:** baseplus, Keycloak, Argo CD e demo no Envoy há **1–2 dias** sem incidente; login, API e WebSocket (`/api/ws`) usados nesse período. O Passbolt fica de fora (ADR-0003).

## 0. Antes de mexer (backup, fora do repo)

```bash
helm get values ingress-nginx -n kube-system -o yaml > ~/ingress-nginx-values-antes.yaml
helm get values kcert -n kcert -o yaml > ~/kcert-values-antes.yaml
kubectl get ingress -A -o yaml > ~/ingress-antes-retirada.yaml
```

Confirme que o nginx está sem tráfego (nenhuma linha de acesso em 10 min):

```bash
kubectl -n kube-system logs deploy/ingress-nginx-controller --since=10m | tail
```

E que o túnel não aponta mais para ele (painel → Tunnels → Routes): só `passbolt` fica fora do Envoy.

## 1. Repo do baseplus (via Argo CD)

1. `deploy/envs/homolog/values.yaml`: `ingress.enabled: false` (remove os Ingress `baseplus` e `baseplus-ws`).
2. `deploy/platform/homolog/50-keycloak.yaml`: apagar o Ingress `keycloak` (manter o HTTPRoute).
3. Push; o Argo CD faz o prune. Verifique: `kubectl -n baseplus-hml get ingress` vazio e `https://baseplus-hml.wsiqueira.cloud` / `https://auth-baseplus-hml.wsiqueira.cloud` respondendo.

O external-dns está em `upsert-only`: apagar Ingress **não** apaga o DNS. Os registros dos hosts baseplus/keycloak dependem do `Gateway` (annotation `target`); o do argocd e do demo, dos HTTPRoutes.

## 2. Ingress manuais

```bash
kubectl -n argocd delete ingress argocd-server        # aplicado à mão; o HTTPRoute já atende
```

**Não apague o `passbolt-ingress`** (ADR-0003): é a fonte DNS do Passbolt para o external-dns. Ele fica inerte depois da remoção do controller.

## 3. ingress-nginx

```bash
helm uninstall ingress-nginx -n kube-system
kubectl get validatingwebhookconfiguration | grep -i ingress-nginx   # deve sumir junto
kubectl get ingressclass                                            # remover "nginx" se sobrar
```

**Rollback:** `helm install ingress-nginx ingress-nginx/ingress-nginx --version 4.15.1 -n kube-system -f ~/ingress-nginx-values-antes.yaml`, reaplicar `~/ingress-antes-retirada.yaml` e voltar as rotas do túnel (`https://ingress-nginx-controller.kube-system.svc.cluster.local:443`, `noTLSVerify`, `originServerName`).

## 4. kcert

Antes de remover, descubra o que depende dele (hoje: nada referenciado em Ingress; o LoadBalancer `kcert` usa 192.168.3.167):

```bash
kubectl get ingress,svc -A -o yaml | grep -i kcert
kubectl -n kcert logs deploy/kcert --tail=50
```

Se nada usar: `helm uninstall kcert -n kcert` e liberar o IP no MetalLB. O **cert-manager fica** (Keycloak/CNPG têm certificados próprios; remover é outra decisão).

## 5. external-dns

Mantenha `policy: upsert-only`. Voltar para `sync` só é seguro se **todo** host tiver uma fonte (Ingress ou HTTPRoute); o Passbolt só tem o `passbolt-ingress`, e `sync` apagaria registros órfãos. O ganho de `sync` é só limpeza de registros antigos, que pode ser feita à mão no painel.

Para mudar mesmo assim (mantendo as sources e o `--cloudflare-proxied`):

```bash
helm upgrade external-dns kubernetes-sigs/external-dns --version 1.17.0 -n cloudflare \
  --reuse-values --set policy=sync
```

## 6. Fechamento

- Atualizar `docs/cloudflare-tunnel-rotas.md` e marcar o ADR-0002 como concluído.
- Rodar o health check do cluster e registrar o resultado no checklist da Etapa 1.
