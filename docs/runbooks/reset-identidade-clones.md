# Runbook — Identidade única nos nós clonados

**Diagnóstico (11/11/2026):** os **7 nós** têm o mesmo `/etc/machine-id` (`0eefb417…`) e a mesma chave de host SSH (`9vkYwv…`). O `product_uuid` é diferente em todos, então o kubeadm não é afetado. O master mantém a identidade; os 6 workers recebem uma nova.

| Nó | IP |
| --- | --- |
| vmkubernetesworkernode01 | 192.168.3.8 |
| vmkubernetesworkernode02 | 192.168.3.9 |
| vmkubernetesworkernode03 | 192.168.3.10 |
| vmkubernetesworkernode04 | 192.168.3.12 |
| vmkubernetesworkernode05 | 192.168.3.17 |
| vmkubernetesworkernode06 | 192.168.3.18 |

**Atalho:** `scripts/reset-identidade.sh <nó> <ip>`, rodado no master, faz o drain, a troca, o reboot, a espera e o uncordon de um nó. Os passos manuais estão abaixo.

**Por que corrigir antes da Fase 1:** o `machine-id` vira identificador de host no journald e no OpenTelemetry (`host.id`). Com ele repetido, a telemetria de nós diferentes se mistura. A chave SSH repetida impede detectar uma troca de máquina (MITM) na rede.

## 1. Verificar os workers 03–06 (pelo IP)

```bash
# no master
for ip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  echo "== $ip"
  ssh "$ip" 'hostname; cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | cut -d" " -f2'
done
```

## 2. Corrigir um nó por vez (exceto um, que pode manter os valores atuais)

Do Mac:

```bash
NODE=vmkubernetesworkernode01
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

No nó, como root:

```bash
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup                 # gera um machine-id novo
ln -sf /etc/machine-id /var/lib/dbus/machine-id

rm -f /etc/ssh/ssh_host_*
ssh-keygen -A                            # gera chaves de host novas
systemctl restart sshd

reboot
```

Do Mac, depois que o nó voltar:

```bash
kubectl uncordon "$NODE"
kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.machineID}{"\n"}'   # deve ser o novo
```

Em quem conecta por SSH (master e Mac), remova a chave antiga do `known_hosts`:

```bash
ssh-keygen -R vmkubernetesworkernode01 && ssh-keygen -R 192.168.3.8
```

## 3. Aproveite as janelas de drain

- Faça o worker03 junto com o alinhamento do containerd (runbook de upgrade, seção 0): um drain só para as duas tarefas.
- Cada drain e uncordon conta como treino de CKA (manutenção de nó).

## 4. Para os próximos clones

Use um template de VM "generalizado": `machine-id` vazio (`truncate -s 0 /etc/machine-id`) e chaves SSH apagadas antes de converter em template. Um `virt-sysprep` ou a customização de SO do vCenter faz isso automaticamente.
