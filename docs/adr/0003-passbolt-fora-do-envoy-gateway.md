# ADR-0003 — Passbolt fica fora do Envoy Gateway

- **Status:** aceito
- **Data:** 2026-11-20

## Contexto

- O túnel Cloudflare já leva o `passbolt.wsiqueira.cloud` **direto** ao Service do Passbolt (`https://passbolt.application.svc.cluster.local:443`). Ele nunca passou pelo ingress-nginx; o `passbolt-ingress` existe só para o external-dns manter o registro DNS.
- Os outros 4 hosts (`argocd`, `demo`, `baseplus-hml`, `auth-baseplus-hml`) foram migrados para o Envoy Gateway (ADR-0002), que fala HTTP com o cloudflared.
- O Passbolt é o cofre de senhas: uma falha na entrada tem impacto maior do que em qualquer outro host.

## O que foi medido (20/11/2026, somente leitura)

- Porta 80 do pod: responde **302** para HTTPS mesmo com `X-Forwarded-Proto: https`, por causa de `PASSBOLT_SSL_FORCE=true`. Backend em HTTP puro causaria loop de redirect.
- Porta 443 do pod: certificado **autoassinado, gerado na subida do contêiner** (`CN=www.passbolt.local`), diferente em cada uma das 4 réplicas. O Secret `passbolt-sec-tls-internal` está montado, mas com nomes de arquivo que a imagem não lê.
- `BackendTLSPolicy` exige validar o certificado do backend contra uma CA; não há CA estável para validar.

## Decisão

Manter o Passbolt **fora** do Envoy Gateway. O túnel continua apontando direto para o Service, com TLS fim a fim até o pod.

## Alternativas consideradas

- **Certificado de verdade no Passbolt (cert-manager, nomes de arquivo corretos) + `BackendTLSPolicy`:** viável, mas exige reiniciar as 4 réplicas do cofre para um ganho funcional nulo.
- **API `Backend` do Envoy Gateway com `insecureSkipVerify`:** exige habilitar a extensão no controller e abre uma exceção insegura numa rota de credenciais. Não confirmado se o v1.10 suporta como esperado.
- **Passbolt em HTTP atrás do Envoy:** inviável (loop de redirect, ver acima).

## Consequências

- (+) Nenhuma mudança no cofre de senhas; menos um salto na entrada.
- (+) O que justifica a migração dos outros 4 hosts (fim do ingress-nginx aposentado) continua valendo: o Passbolt já não dependia dele.
- (−) A entrada tem dois padrões (Envoy e direto). O Passbolt não ganha as políticas do Gateway.
- (−) O `passbolt-ingress` deve ficar como **fonte DNS** do external-dns enquanto o Passbolt não tiver HTTPRoute; apagá-lo com `policy: sync` apagaria o registro. Ver o runbook de retirada do ingress-nginx.

## Quando reabrir

Se o Passbolt passar a ter certificado estável (emitido pelo cert-manager e montado com os nomes que a imagem lê), a migração vira só uma `BackendTLSPolicy` e uma troca de destino no túnel.
