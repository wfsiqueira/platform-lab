# ADR-0001 — GitOps como única via de mudança

- **Status:** aceito
- **Data:** 2026-11

## Contexto

O cluster do homelab cresceu com `kubectl apply` manual ao longo de 2 anos. Não há como recriá-lo do zero nem saber o que mudou e quando. O laboratório de plataforma vai adicionar mais de 10 componentes.

## Decisão

Toda mudança no cluster entra por commit neste repositório e é aplicada pelo Argo CD, no padrão app-of-apps. O único passo manual é `bootstrap/install-argocd.sh`. `selfHeal` fica ligado: alteração feita à mão é desfeita.

## Alternativas consideradas

- **Flux CD:** equivalente em capacidade; o Argo CD foi escolhido pela UI (útil em demo de entrevista) e por já ter sido usado em produção.
- **Helm/kubectl via CI (push):** exige credencial de cluster no CI e não detecta drift.

## Consequências

- (+) Cluster reconstruível, histórico auditável, rollback por `git revert`.
- (+) O repositório vira o portfólio.
- (−) Segredos precisam de solução própria (External Secrets ou SOPS) — fica para a Fase 1.
- (−) Debug manual exige pausar o `selfHeal` da Application antes.
