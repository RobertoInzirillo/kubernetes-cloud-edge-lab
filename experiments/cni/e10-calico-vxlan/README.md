# E10 — Calico VXLAN con data plane Linux

**Data:** 5 agosto 2026<br>
**Identificativo:** `20260805T160549Z`<br>
**Esito:** completato e verificato

## 1. Domanda sperimentale

Mantenendo invariati K3s, topologia, CIDR, workload, kube-proxy e matrici di
E01/E02, quali componenti e artefatti realizza Calico Open Source in modalità
VXLAN con data plane Linux, e quali differenze sono attribuibili a CNI, IPAM e
policy engine Calico?

## 2. Configurazione

- Calico Open Source `v3.32.1` installato tramite chart e Tigera Operator;
- CNI Calico e `calico-ipam`;
- IPPool `10.42.0.0/16`, blocchi `/26`, VXLAN sempre attivo;
- BGP disabilitato;
- `linuxDataplane: Iptables` e forwarding dei container abilitato;
- kube-proxy mantenuto con `kubeProxyManagement: Disabled`;
- Flannel e controller NetworkPolicy K3s disabilitati;
- Calico API server abilitato; Goldmane
  e Whisker disabilitati;
- nessun data plane extended Berkeley Packet Filter (eBPF), IP-in-IP,
  WireGuard o altro componente opzionale.

La configurazione pubblica è nei file
[`manifests/cni/calico/`](../../../manifests/cni/calico/).

## 3. Versioni rilevanti

| Componente | Versione o integrità |
|---|---|
| Docker Engine/CLI | `29.7.1` |
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| kubectl | `v1.34.9` |
| Helm | `v3.21.3` |
| Calico Open Source | `v3.32.1` |
| Tigera Operator | `v1.42.3` |
| chart CRD | SHA-256 `0fa7fa4fc7df7942f6a2472d7ac52a26929b6864c9f3563034e2284c6fcce6f0` |
| chart operator | SHA-256 `563f75f29bdbb13dde13a1d51244b96f42b4fe0eef5be763fb55fa9756f31c93` |
| immagine operator `linux/amd64` | SHA-256 `9ca16aacd5676df68535e08e77529f6c1988ffecbff451e0ff5777e1b126dd91` |

L'`ImageSet` versionato contiene nove immagini Calico per digest. L'immagine
Tigera Operator viene fissata separatamente dal
[post-renderer](../../../scripts/cni/calico/pin-tigera-operator-image.sh).

## 4. Topologia

```text
server-0: control plane, nessun workload del test
agent-0: client, server-a
agent-1: server-b
```

I blocchi CIDR restano `10.42.0.0/16` per i Pod e `10.43.0.0/16` per i
Service. Il workload HTTP e le due NetworkPolicy sono gli stessi artefatti
comuni usati nei casi Flannel e Cilium.

## 5. Riproduzione

Download e verifica dei chart, rendering, installazione dell'operator,
ImageSet, Installation, API server e prove del data plane sono descritti nella
[sezione E10 del manuale](../../../docs/reproduction-guide.md#10-e10--calico-vxlan-con-data-plane-linux).

La configurazione pubblica incorpora lo stato finale con Calico API server
abilitato. La transizione intermedia osservata durante l'esperimento non è una
fase richiesta della riproduzione.

## 6. Risultati osservati

- tre nodi `Ready`; Calico CNI/IPAM attivi, Flannel e controller K3s assenti;
- IPPool `10.42.0.0/16`, blocchi `/26`, MTU 1450 e `vxlan.calico` su UDP 4789,
  VNI 4096;
- collegamento dei Pod mediante veth `cali*` e route di livello 3, senza
  bridge `cni0`;
- ICMP e HTTP intra-node e inter-node riusciti;
- singolo GET osservato internamente con IP dei Pod e su `eth0` come VXLAN fra
  indirizzi underlay; incremento esterno di 50 byte;
- Service attribuito a kube-proxy iptables tramite catene
  `KUBE-SVC`/`KUBE-SEP`, DNAT e
  delta dei contatori;
- matrice NetworkPolicy: 6/6 consentiti, 6/6 negati, poi 4 consentiti e 2
  negati;
- log Felix, selector, IPSet, catene e contatori coerenti con la matrice.

## 7. Attribuzione

Calico CNI collega gli endpoint; Calico IPAM assegna gli indirizzi mediante
pool e blocchi. Felix calcola e programma route, VXLAN e artefatti policy del
data plane Linux. Il kernel applica forwarding e filtraggio.

In Kubernetes Datastore, `calico-kube-controllers` eseguiva soltanto i
controller `node,loadbalancer`. La traduzione e programmazione delle policy
osservate vanno attribuite al calculation graph e a Felix, non al policy
controller valido per il datastore etcd. Kube-proxy, mantenuto intenzionalmente,
ha realizzato i flussi Service osservati.

## 8. Evidenze pubbliche

La [selezione delle evidenze originali](evidence/) documenta configurazione
finale, CNI/IPAM, percorso L3/VXLAN, attribuzione Service e NetworkPolicy.
L'indice distingue output, catture, matrici e riepiloghi originali, indicando
anche il materiale procedurale escluso; `SHA256SUMS` ne verifica l'integrità.

## 9. Limiti

- modalità Calico specifica: Open Source 3.32.1, VXLAN e Linux iptables;
- BGP/no-overlay, IP-in-IP, nftables, VPP ed eBPF non testati;
- nodi k3d containerizzati, kernel condiviso e underlay Docker;
- nessuna conclusione su prestazioni, scala o fabric fisico;
- Docker `29.7.1` differisce dalla versione E01/E02;
- identificativi runtime e contatori validi soltanto per la sessione.

## 10. Rimozione

Il manuale elimina esclusivamente `tesi-e10-calico-vxlan` dopo i controlli
finali; iptables, IPSet e interfacce non vengono rimossi manualmente.
