# Confronto controllato Flannel, Calico e Cilium

## Scopo e perimetro

Questo documento presenta E30. Le osservazioni **O** e le interpretazioni
**I** derivano esclusivamente da quattro esperimenti; gli elementi **T**
aggiungono contesto teorico/documentale e non sono risultati sperimentali:

- [E01 — Flannel VXLAN](../experiments/cni/e01-flannel-vxlan/README.md);
- [E02 — attribuzione NetworkPolicy](../experiments/cni/e02-networkpolicy/README.md);
- [E10 — Calico VXLAN/Linux](../experiments/cni/e10-calico-vxlan/README.md);
- [E20 — Cilium VXLAN/eBPF](../experiments/cni/e20-cilium-vxlan/README.md).

E30 non ha creato cluster, generato traffico o prodotto benchmark. Confronta
configurazioni precise:

- Flannel VXLAN nello stack K3s `v1.34.9+k3s1`;
- Calico Open Source (OSS) 3.32.1, Calico IP Address Management (IPAM), Virtual
  Extensible LAN (VXLAN), Border Gateway Protocol (BGP) disabilitato e data
  plane Linux iptables;
- Cilium 1.19.6, Cluster Pool IPAM, VXLAN e data plane virtual Ethernet
  (veth)/extended Berkeley Packet Filter (eBPF), con kube-proxy mantenuto.

Per il contesto architetturale generale si veda la
[panoramica dei CNI](cni-overview.md); per il perimetro e i limiti delle
conclusioni si veda [Limitazioni e lavoro futuro](limitations.md).

## Tipo di evidenza

Quando utile, la matrice distingue:

- **O — osservato:** fatto rilevato direttamente nel laboratorio;
- **I — interpretazione:** conclusione ricavata dalle osservazioni;
- **T — teorico:** informazione non verificata sperimentalmente.

La combinazione `O/I` indica che la cella contiene dati diretti e la loro
attribuzione. `O/T` separa un limite osservato dalle varianti teoriche non
provate. Una capacità `T` non diventa un risultato sperimentale.

## Elementi controllati e differenze residue

Gli esperimenti hanno mantenuto K3s `v1.34.9+k3s1`, un server e due agent,
blocchi Classless Inter-Domain Routing (CIDR) Pod `10.42.0.0/16` e Service
`10.43.0.0/16`, namespace, workload,
immagine BusyBox, topologia logica e manifest NetworkPolicy. `client` e
`server-a` erano sullo stesso agent; `server-b` sull'altro. E10 ed E20 hanno
mantenuto kube-proxy, mentre il controller NetworkPolicy K3s era disabilitato
per evitare un secondo policy engine.

I tre casi Pod-to-Pod hanno usato VXLAN. Questo rende confrontabile lo stesso
meccanismo generale, ma non copre routing senza overlay.

Non tutte le differenze ambientali sono state eliminate. Docker Engine e
Command Line Interface (CLI) erano `29.6.2` in E01/E02, `29.7.1` in E10 e
`29.7.2` in E20. I controlli non hanno rilevato un cambiamento funzionale che
invalidasse gli esperimenti, ma la variazione resta un limite. Indirizzi,
veth, identità, contatori e altri identificativi runtime differiscono per
definizione. Queste versioni appartengono alle sessioni che hanno prodotto le
evidence storiche pubblicate; la successiva validation completa end-to-end al
commit `d392dfb9b54753eb7e998d9620e02b01dbc36a2a` ha rieseguito E01, E02, E10 ed
E20 con Docker Engine/CLI `29.7.2`.

## Matrice principale

La matrice usa inoltre User Datagram Protocol (UDP), Virtual Tunnel Endpoint
(VTEP), Virtual Network Identifier (VNI) e Container Network Interface (CNI).

| Natura e dimensione | Flannel VXLAN nello stack K3s | Calico OSS 3.32.1, VXLAN, Linux iptables | Cilium 1.19.6, VXLAN, veth/eBPF |
|---|---|---|---|
| **I — ruolo** | rete Pod essenziale e trasporto L3 inter-node; policy e Service separati | CNI, IPAM, raggiungibilità e policy integrati; Service delegato | CNI, IPAM, raggiungibilità, policy, load balancing e osservabilità eBPF; kube-proxy mantenuto |
| **O — CNI** | concatenazione `flannel`, `portmap`, `bandwidth` osservata nel laboratorio, ma non documentata da un output autonomo nella selezione pubblica E01 | CNI Calico e `calico-ipam`; Flannel assente | `05-cilium.conflist`; Cilium primario esclusivo; Flannel assente |
| **O/I — IPAM** | subnet `/24` e delega `host-local` osservate nel laboratorio, ma non documentate da un output autonomo nella selezione pubblica E01 | IPPool `10.42.0.0/16`, blocchi `/26` e affinità Calico | Cluster Pool IPAM e blocchi `/24` in `CiliumNode` |
| **O — Pod–nodo** | veth collegate al bridge `cni0` | veth `cali*` e routing L3, senza `cni0` | veth `lxc*`, route tramite `cilium_host` e hook eBPF TCX, senza `cni0` |
| **O/I — intra-node** | veth → `cni0` → veth | route L3 diretta fra veth `cali*` | veth e route L3 Cilium con programmi e mappe eBPF; nessun tunnel locale |
| **O — inter-node** | veth → `cni0` → `flannel.1` → `eth0` | veth `cali*` → `vxlan.calico` → `eth0` | veth `lxc*` → `cilium_vxlan` → `eth0` |
| **O — interfaccia tunnel** | `flannel.1` | `vxlan.calico` | `cilium_vxlan` |
| **O — porta VXLAN** | UDP destinazione `8472` | UDP destinazione `4789` | UDP destinazione `8472` |
| **O/I — VNI/tunnel ID** | VNI fisso `1` | VNI fisso `4096` | `21766` in andata e `16090` al ritorno, coincidenti con l'identità della sorgente |
| **O/I — stato di raggiungibilità** | subnet manager, annotazioni Flannel, route e vicini VTEP nel kernel | IPPool, IPAMBlock/BlockAffinity, Pod IP/nodo, route e stato Felix; BGP disabilitato | `CiliumNode`, IP cache, endpoint e security identity |
| **I — data plane** | bridge, routing e VXLAN del kernel Linux configurati da CNI/Flannel | routing, netfilter/iptables, IPSet e VXLAN del kernel programmati da Felix | programmi e mappe eBPF su veth/TCX, routing e VXLAN del kernel |
| **O/I — Service** | controllo incluso nella procedura, ma non documentato da output autonomi nella selezione pubblica E01; attribuzione causale non isolata | kube-proxy iptables: catene `KUBE-SVC`/`KUBE-SEP`, Destination Network Address Translation e delta dei contatori | per due flussi: load balancing, reverse NAT e conntrack `TCP SVC` eBPF; regole kube-proxy presenti ma senza delta |
| **O/I — NetworkPolicy** | enforcement del controller K3s separato quando attivo, non di Flannel | calculation graph e Felix traducono e programmano la policy | Cilium associa policy e identità agli endpoint e applica la decisione in eBPF |
| **O — artefatti policy** | catene/ipset policy-specifici `KUBE-*` e contatori soltanto nel controllo ON | NetworkPolicy Kubernetes, selector, IPSet e catene iptables con riferimenti alle policy | policy revision, policy map eBPF, contatori e verdetti Hubble |
| **O — osservabilità usata** | file CNI, route, bridge, netfilter, log K3s e `tcpdump` | risorse Calico, log Felix, IPSet/iptables, route e `tcpdump` | `CiliumEndpoint`, identità, mappe/programmi eBPF, `cilium-dbg`, Hubble e `tcpdump` |
| **I — deleghe** | bridge/IPAM ai plugin CNI; policy al controller K3s; Service separato da Flannel | Service a kube-proxy; applicazione finale al kernel Linux | kube-proxy resta installato; il kernel eBPF applica forwarding, Service e policy nei flussi osservati |
| **O/T — limiti specifici** | non provati `host-gw` e altri backend; Service non isolato causalmente | non provati BGP/no-overlay, IP-in-IP, nftables o eBPF | non provati native routing o kube-proxy replacement |

WorkloadEndpoint rimane il modello logico con cui Calico rappresenta un
endpoint di workload. Nel
[Kubernetes API datastore (KDD)](https://docs.tigera.io/calico/latest/getting-started/kubernetes/hardway/the-calico-datastore),
gli endpoint dei workload Kubernetes sono rappresentati internamente a
partire dai Pod, non da una CRD WorkloadEndpoint dedicata nel datastore
sottostante. Il
[Calico API server](https://docs.tigera.io/calico/latest/reference/architecture/overview)
può esporre tramite `kubectl` le API v3 aggregate `projectcalico.org/v3`: è un
percorso distinto dalla query diretta delle CRD del datastore tentata nel
laboratorio. In E10 quella query non ha esposto una CRD WorkloadEndpoint
dedicata; le osservazioni correlano quindi Pod IP e nodo, interfacce `cali*`,
route, IPAMBlock/BlockAffinity e dataplane Felix.

I numeri del VNI non sono una metrica di qualità. Nei casi Flannel e Calico
identificano il dominio VXLAN configurato. Nel caso Cilium osservato, il
tunnel identifier trasporta la security identity della sorgente e cambia nei
due versi.

## Percorsi e modello degli endpoint

Sul medesimo nodo Flannel introduce un bridge di livello 2 esplicito. Calico
e Cilium adottano un modello di livello 3 basato su route verso veth; Cilium
aggiunge programmi eBPF TCX agli endpoint osservati. Calico usa invece il data
plane Linux tradizionale programmato da Felix.

Fra nodi, tutte e tre le configurazioni conservano gli IP dei Pod nel
pacchetto interno e aggiungono un involucro underlay VXLAN. Differiscono
interfaccia, porta, VNI o tunnel identifier e stato usato per distribuire la
raggiungibilità.

Indirizzo, raggiungibilità e identità di sicurezza non sono lo stesso dato:

- lo stack K3s/Flannel assegna subnet per nodo e delega l'allocazione a
  `host-local`;
- Calico IPAM usa pool, blocchi e affinità;
- Cilium Cluster Pool usa `CiliumNode` e affianca agli indirizzi endpoint e
  security identity impiegate anche da policy e osservabilità.

## Service

La procedura E01 controlla che il ClusterIP raggiunga backend Ready, ma la
selezione pubblica E01 non contiene output autonomi del Service e non sostiene
quindi questo punto come risultato pubblicamente dimostrato. E01 non isola
comunque in modo causale il componente che seleziona il backend e applica la
traduzione. L'architettura dello stack assegna normalmente questa
responsabilità a kube-proxy, ma E01 non viene presentato come una prova
causale.

In E10, regole, Destination Network Address Translation (DNAT) e delta dei
contatori attribuiscono a kube-proxy iptables le connessioni osservate. In
E20 kube-proxy era presente e configurato; tuttavia, per due connessioni
controllate, sono comparse nuove entry conntrack eBPF `TCP SVC` con backend e
reverse NAT correlati, mentre i contatori kube-proxy pertinenti sono rimasti
invariati. La conclusione non esclude che altri percorsi o tipi di Service
possano attraversare kube-proxy.

## NetworkPolicy

La stessa coppia di manifest Kubernetes ha prodotto la seguente matrice:

| Stato | K3s/Flannel ON | K3s/Flannel OFF | Calico | Cilium |
|---|---:|---:|---:|---:|
| baseline | 6/6 consentiti | 6/6 consentiti | 6/6 consentiti | 6/6 consentiti |
| default deny | 6/6 negati | 6/6 consentiti | 6/6 negati | 6/6 negati |
| deny + allow mirata | 4 consentiti, 2 negati | 6/6 consentiti | 4 consentiti, 2 negati | 4 consentiti, 2 negati |

Il controllo ON/OFF dimostra che la dichiarazione nell'API non equivale a
enforcement. Con il controller K3s disabilitato, gli oggetti erano presenti,
tutte le 18 connessioni restavano consentite e quattro confronti kernel erano
identici alla baseline. Con il controller attivo comparivano comportamento e
artefatti policy-specifici.

Calico ha realizzato lo stesso intento con calculation graph, Felix,
iptables e IPSet. Cilium lo ha realizzato con revisione degli endpoint,
policy map eBPF e verdetti Hubble `FORWARDED` o `POLICY_DENIED`.

## Osservabilità

Il confronto non produce una classifica assoluta:

- Flannel/K3s richiede soprattutto strumenti Linux e log del controller di
  policy separato;
- Calico aggiunge risorse e log propri, mentre route, IPSet e iptables restano
  leggibili nel data plane provato;
- Cilium espone endpoint, identità, programmi, mappe e verdetti; Hubble ha
  correlato le decisioni ai flussi.

`tcpdump` è rimasto necessario per dimostrare direttamente
l'incapsulamento esterno in tutti e tre i casi.

## Conclusioni e gap

Il campione mostra differenze concrete fra:

- bridge Linux e fabric Flannel con policy delegata;
- routing L3, IPAM e policy Linux/Felix di Calico;
- endpoint, identità, Service e policy nel data plane eBPF Cilium.

Non dimostra quale soluzione sia più veloce o più scalabile. Non copre
Flannel `host-gw`, Calico BGP/no-overlay, Calico eBPF, Cilium native routing,
kube-proxy replacement, OVS, Antrea o OVN-Kubernetes. Flannel `host-gw` e
Calico BGP/no-overlay sono possibili estensioni, non esperimenti esistenti; un
caso OVS non fa parte del campione.

La panoramica teorica è quindi più ampia dell'evidenza sperimentale. La
distinzione impedisce di trasformare capacità documentate in risultati e
delimita correttamente il valore di E30.
