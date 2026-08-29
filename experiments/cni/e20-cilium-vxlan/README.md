# E20 — Cilium VXLAN con data plane eBPF

## 1. Domanda sperimentale

Mantenendo K3s, topologia, CIDR, workload, VXLAN, kube-proxy e matrici di
E01/E02, come cambiano percorso Pod-to-Pod, Service e
NetworkPolicy quando il data plane è realizzato dai programmi e dalle mappe
extended Berkeley Packet Filter (eBPF) di Cilium?

## 2. Configurazione

- Cilium `1.19.6` come CNI primario esclusivo;
- Cluster Pool IPAM sul pool CIDR `10.42.0.0/16`, maschera per nodo `/24`;
- IPv4, VXLAN, underlay IPv4 e data path virtual Ethernet (veth);
- `kubeProxyReplacement: "false"` e socket load balancing disabilitato;
- kube-proxy K3s mantenuto;
- NetworkPolicy Kubernetes applicate da Cilium; controller K3s disabilitato;
- Hubble locale con TLS; Relay e interfaccia grafica disabilitati;
- Envoy e livello 7, BGP, cifratura, Cluster Mesh, Ingress, Gateway API, host
  firewall ed egress gateway disabilitati.

I valori completi sono in
[`manifests/cni/cilium/values.yaml`](../../../manifests/cni/cilium/values.yaml).

## 3. Versioni rilevanti

| Componente | Versione o integrità |
|---|---|
| Docker Engine/CLI | `29.7.2` |
| containerd host / runc | `2.3.3` / `1.4.3` |
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| Cilium chart/app | `1.19.6` |
| chart Cilium | SHA-256 `21c43cf53841f9ab0375047d95aa4c64051ea52bbd2c679416e6408f5f1c9179` |
| agente Cilium | manifest list SHA-256 `0df5b2750b64c49843aba1d649e9eaf61467cb0645ad3171db6f6962c095ac92` |
| operator generic | manifest list SHA-256 `0db4ca4e06969d8904ee036617795d0e9c3228cf7b8d902ba74fc2bb98d2d665` |

Le evidence storiche
[`node-ebpf-prerequisites.log`](evidence/node-ebpf-prerequisites.log) e
[`policy-final-gate.log`](evidence/policy-final-gate.log) registrano il kernel
host `7.0.0-28-generic`, con cgroup v2, Berkeley Packet Filter filesystem
(bpffs), BPF Type Format (BTF), hook traffic control e supporto VXLAN. I
prerequisiti sono stati verificati anche dentro ogni nodo.

## 4. Topologia

```text
server-0: Cilium agent e control plane
agent-0: Cilium agent, client, server-a
agent-1: Cilium agent, server-b
```

Un solo Cilium Operator coordinava l'allocazione. Il Service `servers`
selezionava i due endpoint HTTP. Gli
identificativi `CiliumEndpoint`, le
security identity, i Pod IP e le veth devono essere riletti a ogni esecuzione.

## 5. Riproduzione

Download e hash del chart, configurazione Helm, controlli eBPF, Hubble,
cattura VXLAN, Service e NetworkPolicy sono descritti nella
[sezione E20 del manuale](../../../docs/reproduction-guide.md#11-e20--cilium-vxlan-con-data-plane-ebpf).

L'anomalia underlay osservata dopo un riavvio Docker è presentata nel manuale
soltanto come troubleshooting condizionato.

## 6. Risultati osservati

### Installazione e percorso

- Cilium `3/3`, Operator `1/1`, tre nodi `Ready`, Cluster Pool IPAM con tre
  blocchi `/24`, VXLAN e data path veth/eBPF;
- percorso intra-node di livello 3 tramite veth, route `cilium_host` e
  programmi TCX `cil_from_container`, senza `cni0` o tunnel locale;
- cattura inter-node valida su veth, `cilium_vxlan` ed `eth0`, UDP 8472 fra
  indirizzi underlay e HTTP riuscito;
- il decoder ha mostrato `instance=21766` in andata e `instance=16090` al
  ritorno; l'analisi offline li ha ricondotti al campo VXLAN e alle security
  identity delle sorgenti, senza ripetere la cattura.

### Service

Due connessioni al ClusterIP hanno selezionato `server-a` e `server-b`. Le
regole kube-proxy pertinenti erano presenti ma i loro contatori sono rimasti
invariati. Sono invece comparse due nuove entry conntrack eBPF `TCP SVC`
(Transmission Control Protocol Service), con
reverse Network Address Translation e backend coerenti con le risposte;
Hubble ha correlato le stesse porte.

### NetworkPolicy

| Stato | Risultato |
|---|---|
| nessuna policy | 6/6 consentiti |
| `default-deny-ingress` | 6/6 negati |
| deny + allow mirata | 4/6 consentiti, 2/6 negati |

Le revisioni endpoint sono avanzate da 1 a 2 e 3. Policy map eBPF, contatori e
verdetti Hubble `FORWARDED` o `POLICY_DENIED` erano coerenti con ciascun
flusso.

### Anomalia e ripristino

Dopo un riavvio Docker, `agent-1` aveva underlay corrente `172.19.0.3`, mentre
`CiliumNode`, vista nodi e IP cache conservavano `172.19.0.2` come tunnel
endpoint. ICMP e HTTP inter-node fallivano. La ricreazione del solo Pod Cilium
su `agent-1` ha riallineato lo stato a `172.19.0.3`; ICMP e HTTP sono tornati
funzionanti. Il ripristino è verificato, la causa della mancata riconciliazione
automatica non è stata determinata.

## 7. Attribuzione

Cilium CNI e Cluster Pool IPAM realizzano collegamento e allocazione;
`CiliumNode`, IP cache, endpoint e security identity distribuiscono lo stato.
Programmi e mappe eBPF applicano forwarding, selezione Service e
NetworkPolicy nei flussi osservati; VXLAN del kernel trasporta il traffico
inter-node.

Per il Service, la sola configurazione `kubeProxyReplacement=false` non era
sufficiente. Nuove entry conntrack `TCP SVC`, backend/reverse NAT, Hubble e
contatori kube-proxy invariati sostengono l'attribuzione delle due
connessioni a Cilium eBPF. Kube-proxy resta installato e la conclusione non
viene estesa ad altri percorsi.

Per le policy, l'API dichiara l'intento;
Cilium lo associa agli endpoint e alle identità; policy map e programmi eBPF
applicano la decisione, osservata da Hubble. Flannel e il controller K3s erano
assenti.

## 8. Evidenze pubbliche

La [selezione delle evidenze originali](evidence/) copre configurazione eBPF,
IPAM, percorsi, cattura VXLAN, Hubble, attribuzione Service e matrice
NetworkPolicy. L'indice conserva soltanto tre output mirati per l'anomalia
underlay e distingue gli output originali dal README; `SHA256SUMS` ne verifica
l'integrità.

## 9. Limiti

- k3d, kernel condiviso e rete Docker come underlay;
- nessun benchmark, test di scala, fabric fisico o offload hardware;
- native routing, Geneve e kube-proxy replacement non provati;
- funzioni L7, cifratura, BGP e Cluster Mesh escluse;
- attribuzione Service limitata a due connessioni ClusterIP dal Pod client;
- anomalia di riconciliazione circoscritta all'ambiente osservato, con causa
  non determinata;
- identificativi e indirizzi da rilevare nuovamente in ogni replica.

## 10. Rimozione

Il manuale elimina esclusivamente `tesi-e20-cilium-vxlan` e verifica il
listener `6449`. Programmi e mappe eBPF, route e netfilter non vengono rimossi
manualmente.
