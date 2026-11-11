# CKA — Exercícios das semanas 1 e 2

Faça cada um **cronometrado**, com só a doc oficial aberta (kubernetes.io, helm.sh, gateway-api.sigs.k8s.io). As soluções estão em `solucoes.md` — só abra depois de tentar.

Use um namespace descartável: `kubectl create ns cka-pratica`. Ao final, `kubectl delete ns cka-pratica`.

| # | Domínio | Tempo-alvo | Tarefa |
| --- | --- | --- | --- |
| 1 | Arquitetura | 6 min | Faça um snapshot do etcd em `/opt/cka/etcd-snap.db` e mostre o status em tabela. |
| 2 | Arquitetura | 4 min | No worker01, crie um static pod `static-web` (imagem `nginx:alpine`) que o kubelet suba sozinho. Depois remova. |
| 3 | Arquitetura | 3 min | Descubra, sem olhar a doc, qual versão o `kubeadm upgrade plan` permite e por que ele não oferece pular uma minor. |
| 4 | Manutenção | 5 min | Crie um Deployment `web` com 3 réplicas e um PDB com `minAvailable: 3`. Tente drenar o nó de uma das réplicas. Explique o que acontece e resolva sem apagar o PDB. |
| 5 | RBAC | 5 min | Crie a Role `pod-reader` em `cka-pratica` (get/list/watch em pods) e associe ao usuário `dev-ana`. Prove com `kubectl auth can-i`. |
| 6 | RBAC | 5 min | Crie a ServiceAccount `deployer` em `cka-pratica` com permissão de criar Deployments **em todos os namespaces**, mas sem poder apagar. Prove com `auth can-i --as`. |
| 7 | RBAC / certificados | 8 min | Gere chave e CSR para o usuário `dev-ana`, aprove via API `CertificateSigningRequest`, monte um kubeconfig `ana.kubeconfig` com contexto próprio e teste o exercício 5 com ele. |
| 8 | Helm | 5 min | Instale o chart `bitnami/nginx` na versão anterior à mais recente, no namespace `cka-pratica`, com 2 réplicas. Atualize para a mais recente e faça rollback. |
| 9 | Kustomize | 5 min | Crie uma base com Deployment `api` (1 réplica) e um overlay `prod` que muda para 3 réplicas e adiciona o label `env=prod`. Aplique só o overlay. |
| 10 | CRDs | 3 min | Liste os CRDs do Argo CD e mostre os campos de `spec.syncPolicy` de uma Application usando só o `kubectl`. |
| 11 | Gateway API | 6 min | Crie um HTTPRoute que mande 80% do tráfego de `demo.wsiqueira.cloud/v2` para o Service `echo-v2` e 20% para `echo`, no Gateway `homelab`. |
| 12 | Troubleshooting | 6 min | Em um cluster de teste (killer.sh ou kind), pare o kubelet de um worker. Diagnostique pelo `kubectl`, ache a causa no nó e recupere. |

**Meta para a semana 2:** fazer os 12 em até 66 minutos (a prova dá cerca de 2 horas para 15 a 20 tarefas).
