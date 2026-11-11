# Runbook — Calico e Istio antes do upgrade do Kubernetes

O preflight de 11/11/2026 mostrou dois bloqueios para chegar à v1.36:

| Componente | Versão atual | Kubernetes suportado pela versão atual | Situação |
| --- | --- | --- | --- |
| Calico | v3.28.1 | testado em 1.27 a 1.30 | O cluster (1.33) já está fora do intervalo testado |
| Istio | 1.21.2 | 1.26 a 1.29; fim de suporte em set/2024 | Fora de suporte e incompatível com 1.33+ |

Fontes: [requisitos do Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements) · [releases do Istio](https://istio.io/latest/docs/releases/supported-releases/)

Resolva os dois **antes** do primeiro salto (1.33 → 1.34). Snapshots das VMs e backup do etcd primeiro.

---

## 1. Istio: está sendo usado?

```bash
kubectl get ns -L istio-injection,istio.io/rev | grep -E 'enabled|[0-9]-[0-9]' || echo "nenhum namespace com injeção"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' | grep istio-proxy || echo "nenhum sidecar"
kubectl get gateways.networking.istio.io,virtualservices.networking.istio.io -A 2>/dev/null
```

**Resultado da coleta de 11/11/2026:** nenhum namespace com injeção, nenhum sidecar e nenhum Gateway/VirtualService do Istio. Falta só olhar o namespace `istio-ingress` (218 dias), que pode ter um gateway instalado à parte:

```bash
kubectl -n istio-ingress get all
helm list -n istio-ingress
```

**Nada em uso (confirmado, salvo o `istio-ingress`):** remova. Libera memória e tira um componente sem suporte do cluster.

```bash
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl get crd -o name | grep istio.io | xargs -r kubectl delete   # só depois de conferir que nada usa
kubectl delete ns istio-system istio-ingress   # istio-ingress só se estiver vazio ou sem uso
```

**Algo em uso:** o Istio só sobe uma minor por vez (1.21 → 1.22 → … → 1.30), com *canary upgrade* via `revision`. São cerca de 9 upgrades. Para um homelab, o caminho mais barato é tirar os sidecars dos workloads e reinstalar o Istio atual depois, numa fase própria (service mesh). Me avise antes, se for o caso.

---

## 2. Calico (instalação via operator, namespace `calico-system`)

Confirme o método de instalação e a versão alvo:

```bash
kubectl get installation default -o jsonpath='{.spec.variant}{"\n"}'     # Calico = instalado pelo tigera-operator
kubectl -n tigera-operator get deploy tigera-operator -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
helm list -A | grep -i -E 'calico|tigera' || echo "não é Helm: instalado por manifesto"
```

Escolha a versão alvo na página de requisitos: a mais recente que liste **1.33 a 1.36** entre as versões testadas (no início de nov/2026 a doc mostra a 3.32 como *latest*).

Leia antes: [Upgrade Calico on Kubernetes (operator)](https://docs.tigera.io/calico/latest/operations/upgrading/kubernetes-upgrade). [Provável] O operator aceita pular minors, mas confira na doc da versão alvo se há passo intermediário obrigatório a partir da 3.28.

Upgrade por manifesto (troque a versão):

```bash
CALICO=v3.32.0   # ajuste
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO}/manifests/operator-crds.yaml"   # se existir nessa versão
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO}/manifests/tigera-operator.yaml"
```

Acompanhe:

```bash
watch kubectl get tigerastatus          # tudo AVAILABLE=True, DEGRADED=False
kubectl -n calico-system get pods -o wide
kubectl -n calico-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Teste de rede depois do upgrade (pod a pod entre nós diferentes e DNS):

```bash
kubectl run net-a --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run net-b --image=busybox:1.36 --restart=Never --overrides='{"spec":{"nodeName":"vmkubernetesworkernode06"}}' -- sleep 3600
kubectl exec net-a -- ping -c3 "$(kubectl get pod net-b -o jsonpath='{.status.podIP}')"
kubectl exec net-a -- nslookup kubernetes.default
kubectl delete pod net-a net-b
```

---

## 3. Velero: backup de aplicação antes de tudo

O cluster já tem Velero 1.18. Antes do Calico e de cada salto do Kubernetes:

```bash
velero backup create pre-upgrade-$(date +%Y%m%d) --wait
velero backup describe pre-upgrade-$(date +%Y%m%d)
```

Confira se o backup inclui os volumes (`openebs-hostpath`) do Passbolt e do Keycloak; se o Velero não estiver com *file system backup* ativo, faça dump dos bancos manualmente.
