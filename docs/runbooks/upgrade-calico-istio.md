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

**Estado em 11/11/2026:** variant `Calico`, operator `v1.34.3` (Calico 3.28.x), VXLANCrossSubnet, BGP ativo, dataplane iptables, com `calico-apiserver` (CRDs no modo aggregation API).

**Matriz consultada na documentação oficial:**

| Calico | Kubernetes testado |
| --- | --- |
| 3.28 | 1.27 a 1.30 |
| 3.30 | 1.31 a 1.35 |
| 3.32 | 1.34 a 1.36 |
| 3.33 (latest) | 1.35 a 1.37 |

O guia de upgrade cobre a partir das **duas versões anteriores**. Caminho: **3.28 → 3.30.7 → 3.32.3**. A 3.32 cobre todo o caminho do Kubernetes até 1.36. A 3.33 fica para depois, se o cluster for para 1.37.

### Salto A: 3.28 → 3.30.7

```bash
mkdir -p ~/calico-upgrade && cd ~/calico-upgrade
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.30.7/manifests/operator-crds.yaml
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.30.7/manifests/tigera-operator.yaml
kubectl apply --server-side --force-conflicts -f operator-crds.yaml
kubectl apply --server-side --force-conflicts -f tigera-operator.yaml
```

### Salto B: 3.30.7 → 3.32.3 (só depois do teste de rede do salto A)

A partir da 3.32 o manifesto de CRDs muda de nome. Este cluster usa o API server do Calico (aggregation API), então o arquivo é `v1_crd_projectcalico_org.yaml`.

```bash
cd ~/calico-upgrade
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.3/manifests/v1_crd_projectcalico_org.yaml
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.3/manifests/tigera-operator.yaml
kubectl apply --server-side --force-conflicts -f v1_crd_projectcalico_org.yaml
kubectl apply --server-side --force-conflicts -f tigera-operator.yaml
```

Fontes: [requisitos 3.32](https://docs.tigera.io/calico/3.32/getting-started/kubernetes/requirements) · [upgrade 3.32](https://docs.tigera.io/calico/3.32/operations/upgrading/kubernetes-upgrade) · [requisitos 3.30](https://docs.tigera.io/calico/3.30/getting-started/kubernetes/requirements) · [upgrade 3.30](https://docs.tigera.io/calico/3.30/operations/upgrading/kubernetes-upgrade)

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
