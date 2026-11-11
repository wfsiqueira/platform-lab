# CKA — Soluções das semanas 1 e 2

Existem outras soluções válidas. O que importa na prova é o resultado no cluster.

## 1. Snapshot do etcd

```bash
sudo mkdir -p /opt/cka
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/cka/etcd-snap.db
sudo etcdutl snapshot status /opt/cka/etcd-snap.db -w table
```

Atalho para achar os caminhos: `grep -E 'cert|key|listen-client' /etc/kubernetes/manifests/etcd.yaml`.

## 2. Static pod

```bash
# descubra a pasta que o kubelet vigia
ssh worker01 'sudo grep staticPodPath /var/lib/kubelet/config.yaml'   # normalmente /etc/kubernetes/manifests
kubectl run static-web --image=nginx:alpine --dry-run=client -o yaml > static-web.yaml
scp static-web.yaml worker01:/tmp/ && ssh worker01 'sudo mv /tmp/static-web.yaml /etc/kubernetes/manifests/'
kubectl get pods -A | grep static-web        # aparece como static-web-<nome-do-nó>
ssh worker01 'sudo rm /etc/kubernetes/manifests/static-web.yaml'   # remover = apagar o arquivo
```

## 3. Upgrade plan

`kubeadm upgrade plan` mostra a versão alvo dentro da minor do pacote `kubeadm` instalado. A política de *version skew* só permite subir o control plane uma minor por vez, porque kubelets com até 3 minors abaixo do apiserver precisam continuar funcionando durante o upgrade. Para ir de 1.33 a 1.36, você instala `kubeadm` 1.34, aplica, e repete.

## 4. Drain com PDB

```bash
kubectl -n cka-pratica create deploy web --image=nginx:alpine --replicas=3
kubectl -n cka-pratica create pdb web --selector=app=web --min-available=3
NODE=$(kubectl -n cka-pratica get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=60s
```

O drain fica tentando despejar e falha por timeout: com `minAvailable: 3` e 3 réplicas, nenhuma pode sair. Solução sem apagar o PDB: escalar antes (`kubectl -n cka-pratica scale deploy web --replicas=4`), esperar a 4ª réplica subir em outro nó e drenar de novo. Depois, `kubectl uncordon "$NODE"`.

## 5. Role + RoleBinding para usuário

```bash
kubectl -n cka-pratica create role pod-reader --verb=get,list,watch --resource=pods
kubectl -n cka-pratica create rolebinding pod-reader-ana --role=pod-reader --user=dev-ana
kubectl -n cka-pratica auth can-i list pods --as=dev-ana     # yes
kubectl -n cka-pratica auth can-i delete pods --as=dev-ana   # no
kubectl auth can-i list pods -n default --as=dev-ana         # no
```

## 6. ServiceAccount com ClusterRole

```bash
kubectl -n cka-pratica create sa deployer
kubectl create clusterrole deploy-creator --verb=create,get,list --resource=deployments.apps
kubectl create clusterrolebinding deployer-all --clusterrole=deploy-creator --serviceaccount=cka-pratica:deployer
kubectl auth can-i create deployments -n kube-system --as=system:serviceaccount:cka-pratica:deployer  # yes
kubectl auth can-i delete deployments -n kube-system --as=system:serviceaccount:cka-pratica:deployer  # no
```

## 7. Usuário via CSR API + kubeconfig

```bash
openssl genrsa -out ana.key 2048
openssl req -new -key ana.key -out ana.csr -subj "/CN=dev-ana/O=devs"

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: dev-ana
spec:
  request: $(base64 < ana.csr | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages: ["client auth"]
EOF
kubectl certificate approve dev-ana
kubectl get csr dev-ana -o jsonpath='{.status.certificate}' | base64 -d > ana.crt

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
kubectl --kubeconfig=ana.kubeconfig config set-cluster homelab --server="$SERVER" --certificate-authority=ca.crt --embed-certs=true
kubectl --kubeconfig=ana.kubeconfig config set-credentials dev-ana --client-key=ana.key --client-certificate=ana.crt --embed-certs=true
kubectl --kubeconfig=ana.kubeconfig config set-context ana@homelab --cluster=homelab --user=dev-ana --namespace=cka-pratica
kubectl --kubeconfig=ana.kubeconfig config use-context ana@homelab
kubectl --kubeconfig=ana.kubeconfig get pods          # funciona
kubectl --kubeconfig=ana.kubeconfig get pods -A       # Forbidden
```

Apague `ana.key` e `ana.kubeconfig` depois. Eles **não** entram no repositório (estão no `.gitignore`).

## 8. Helm: versão anterior, upgrade e rollback

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm search repo bitnami/nginx --versions | head -3          # pegue a 2ª linha
helm install web bitnami/nginx --version <ANTERIOR> -n cka-pratica --set replicaCount=2
helm upgrade web bitnami/nginx -n cka-pratica --reuse-values
helm history web -n cka-pratica
helm rollback web 1 -n cka-pratica
```

## 9. Kustomize

```bash
mkdir -p k/base k/overlays/prod
kubectl create deploy api --image=nginx:alpine --dry-run=client -o yaml > k/base/deploy.yaml
cat > k/base/kustomization.yaml <<'EOF'
resources: [deploy.yaml]
EOF
cat > k/overlays/prod/kustomization.yaml <<'EOF'
resources: [../../base]
namespace: cka-pratica
labels:
  - pairs: { env: prod }
    includeSelectors: false
replicas:
  - name: api
    count: 3
EOF
kubectl kustomize k/overlays/prod      # confira antes
kubectl apply -k k/overlays/prod
```

## 10. CRDs

```bash
kubectl get crd | grep argoproj.io
kubectl explain application.spec.syncPolicy --recursive | head -40
```

## 11. HTTPRoute com divisão de tráfego

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-canary
  namespace: lab-demo
spec:
  parentRefs:
    - { name: homelab, namespace: gateway, sectionName: demo-https }
  hostnames: ["demo.wsiqueira.cloud"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /v2 }
      backendRefs:
        - { name: echo-v2, port: 80, weight: 80 }
        - { name: echo,    port: 80, weight: 20 }
```

## 12. Kubelet parado

```bash
kubectl get nodes                       # nó NotReady
kubectl describe node <nó> | grep -A5 Conditions   # "Kubelet stopped posting node status"
ssh <nó> 'sudo systemctl status kubelet'          # inactive/failed
ssh <nó> 'sudo journalctl -u kubelet -n 50 --no-pager'   # causa: config errada, swap, cert, binário
ssh <nó> 'sudo systemctl enable --now kubelet'
```

Variações frequentes na prova: caminho errado do binário no `kubelet.service` (veja `systemctl cat kubelet`), CA errada em `/var/lib/kubelet/config.yaml` ou porta errada do apiserver em `/etc/kubernetes/kubelet.conf`.
