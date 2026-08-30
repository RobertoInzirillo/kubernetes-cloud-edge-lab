# Networking Kubernetes ed ecosistema CNI

## Perimetro e natura delle affermazioni

Questa panoramica separa due piani:

- **documentazione ufficiale**: architetture e capacità descritte dalle fonti
  ufficiali consultate e verificate fino al 29 agosto 2026;
- **risultati sperimentali**: configurazioni osservate nel laboratorio k3d con
  Flannel, Calico e Cilium.

Una capacità documentata non viene presentata come risultato sperimentale.
Antrea, OVN-Kubernetes, kube-router, Canal, Multus e le famiglie cloud non
sono stati installati nel laboratorio.

## Modello di rete Kubernetes

Secondo il [modello di rete Kubernetes](https://kubernetes.io/docs/concepts/services-networking/),
ogni Pod possiede un indirizzo Internet Protocol (IP) univoco nel cluster. I
container dello stesso Pod condividono il namespace di rete e comunicano
tramite `localhost`. In assenza di segmentazione intenzionale, i Pod devono
potersi raggiungere direttamente anche se risiedono su nodi differenti.

Kubernetes definisce il modello e le Application Programming Interface (API),
ma non implementa da solo ogni tratto del percorso. Occorre distinguere:

- il runtime che crea la sandbox e invoca i plugin di rete;
- la rete dei Pod e l'allocazione degli indirizzi;
- il meccanismo che distribuisce la raggiungibilità fra nodi;
- il data plane che inoltra o filtra i pacchetti;
- la realizzazione dei Service;
- il motore che traduce e applica le NetworkPolicy.

La coesistenza nello stesso cluster non implica che tutte queste funzioni
appartengano al componente chiamato “CNI”.

## Container Network Interface

La [specifica Container Network Interface](https://www.cni.dev/docs/spec/)
(CNI) definisce:

- il formato della configurazione di rete;
- il protocollo con cui il runtime invoca i plugin;
- la concatenazione di più plugin;
- gli argomenti e i tipi di risultato restituiti.

La specifica comprende operazioni come `ADD`, `DEL`, `CHECK`, `GC`, `STATUS`
e `VERSION`. In un flusso tipico, il runtime crea il namespace di rete del
container, invoca `ADD` e passa l'identificativo del container, il namespace e
il nome dell'interfaccia. Il plugin collega la sandbox alla rete e restituisce
il risultato; un plugin IPAM può fornire indirizzo, gateway e route.

CNI non prescrive Virtual Extensible LAN (VXLAN), Border Gateway Protocol
(BGP), bridge, routing nativo, extended Berkeley Packet Filter (eBPF) o Open
vSwitch (OVS). Queste sono scelte della soluzione e della sua configurazione.
Per questo “soluzione di networking Kubernetes” è spesso più preciso di
“plugin CNI”.

### Ruoli dei plugin e concatenazione

Il termine CNI copre ruoli differenti; questa tassonomia sintetica non è un
catalogo esaustivo:

- i plugin di **interfaccia/rete**, come `bridge`, `ptp`, `macvlan`, `ipvlan`,
  `vlan` e `host-device`, collegano il namespace a una rete o a un dispositivo;
- i plugin **IPAM**, come `host-local`, `static` e DHCP, assegnano gli
  indirizzi e restituiscono gateway e route;
- i **meta-plugin o plugin concatenati**, come `portmap`, `bandwidth` e
  `tuning`, elaborano il risultato o l'interfaccia creati da altri plugin;
  Multus è invece un meta-CNI che invoca più delegate per associare più reti;
- le **soluzioni o provider di networking Kubernetes**, come Flannel, Calico,
  Cilium, Antrea, OVN-Kubernetes e kube-router, coordinano più funzioni di rete,
  con confini diversi fra CNI, IPAM, routing, policy e Service.

Un file `conflist` può quindi concatenare più plugin. Lo stack K3s/Flannel
studiato combina già Flannel con `bridge`, `host-local`, `portmap` e
`bandwidth`, anziché affidare tutte le funzioni a un singolo eseguibile.

## IP Address Management

IP Address Management (IPAM) comprende selezione, assegnazione, registrazione
e rilascio degli indirizzi dei workload. Può essere:

- delegato a un plugin generico come `host-local`;
- integrato nella soluzione, mediante pool, blocchi o risorse dedicate;
- coordinato con il control plane Kubernetes;
- integrato con interfacce e indirizzi di un cloud provider.

Un PodCIDR assegnato a un nodo non prova da solo quale componente abbia scelto
l'indirizzo di uno specifico Pod. Nel laboratorio sono stati osservati tre
modelli differenti: `host-local` nello stack K3s/Flannel, pool e blocchi
Calico, blocchi per nodo in `CiliumNode` con Cluster Pool IPAM.

## Collegamento fra Pod e nodo

Il runtime crea il namespace del Pod. Una coppia virtual Ethernet (veth)
collega normalmente l'interfaccia `eth0` del Pod a un'interfaccia nel
namespace del nodo. Da questo punto le implementazioni divergono:

- un bridge Linux può collegare più veth in un segmento locale;
- route di livello 3 possono indirizzare direttamente ciascun endpoint;
- programmi eBPF possono essere collegati agli hook delle veth;
- una porta OVS può inserire il workload in un data plane OpenFlow.

Un flusso intra-node non richiede necessariamente lo stesso meccanismo usato
fra nodi. Nel campione verificato, Flannel/K3s usa il bridge `cni0`; Calico e
Cilium usano modelli di livello 3 senza `cni0`, con Cilium che collega
programmi eBPF agli endpoint osservati.

## Underlay, overlay e VXLAN

L'**underlay** è la rete che rende raggiungibili i nodi. Un **overlay** crea
una rete logica sopra di essa, di solito incapsulando il pacchetto originale.

VXLAN trasporta frame della rete virtuale dentro datagrammi User Datagram
Protocol (UDP). Occorre distinguere:

- pacchetto interno, con indirizzi dei Pod;
- pacchetto esterno, con indirizzi dei nodi;
- Virtual Tunnel Endpoint (VTEP) che incapsula e decapsula;
- Virtual Network Identifier (VNI) o tunnel identifier;
- Maximum Transmission Unit (MTU), ridotta per lasciare spazio agli header
  esterni.

La sola presenza di un'interfaccia VXLAN prova che il tunnel è configurato,
non che uno specifico flusso lo abbia attraversato. Una dimostrazione causale
correla il pacchetto interno e quello esterno mediante interfacce, timestamp,
indirizzi, porte e payload.

Tutte e tre le configurazioni sperimentate hanno usato VXLAN, ma con
interfacce e parametri differenti: `flannel.1` su UDP 8472 e VNI 1,
`vxlan.calico` su UDP 4789 e VNI 4096, `cilium_vxlan` su UDP 8472 con tunnel
identifier coincidente con la security identity della sorgente nei flussi
osservati.

## Routing nativo e BGP

Un percorso senza overlay evita l'incapsulamento. Richiede però che ogni nodo
o l'infrastruttura sottostante conosca le route verso le reti dei workload.
La raggiungibilità può derivare da route statiche, integrazione cloud o un
protocollo dinamico.

Border Gateway Protocol (BGP) scambia informazioni di raggiungibilità. In una
rete Kubernetes route-centric può operare fra nodi, route reflector e router
esterni. BGP non è sinonimo di CNI e non è obbligatorio in tutte le modalità
di una soluzione: Calico può disabilitarlo in una rete esclusivamente VXLAN.

Flannel `host-gw` e Calico BGP/no-overlay non sono inclusi nel campione;
nessun percorso no-overlay è stato verificato nel laboratorio.

## eBPF

Extended Berkeley Packet Filter (eBPF) consente di caricare programmi
verificati nel kernel e collegarli a hook del percorso di rete. Una
piattaforma può usare programmi e mappe eBPF per forwarding, policy,
bilanciamento dei Service, Network Address Translation (NAT) e osservabilità.

eBPF non determina automaticamente il trasporto inter-node: può convivere con
un tunnel o con routing nativo. Nel caso Cilium verificato, il data plane veth
eBPF è stato combinato con VXLAN e con kube-proxy ancora attivo. Per i due
flussi ClusterIP controllati, nuove entry conntrack eBPF e contatori
kube-proxy invariati hanno attribuito selezione del backend e reverse NAT a
Cilium; la conclusione non viene estesa ad altri percorsi o tipi di Service.

## Trasporto inter-node e packet processing: due assi distinti

Il trasporto/routing inter-node descrive come il traffico raggiunge le reti
remote: mediante VXLAN, Geneve o IP-in-IP, oppure tramite routing nativo con
route statiche o distribuite da BGP. Il packet processing descrive invece come
i pacchetti vengono elaborati: bridge e routing Linux, iptables/nftables,
OVS/OVN o eBPF.

I due assi sono ortogonali: una soluzione può combinare, per esempio, VXLAN
con iptables oppure con eBPF. Nei profili provati tutte e tre le soluzioni
usano VXLAN, ma il packet processing osservato rimane specifico di E01, E10 ed
E20.

## Service Kubernetes

Un Service fornisce un indirizzo virtuale stabile e seleziona endpoint pronti.
La realizzazione del ClusterIP può essere affidata a kube-proxy, a un proxy
alternativo o al data plane della soluzione di rete.

La presenza di kube-proxy non dimostra che ogni flusso Service lo attraversi;
analogamente, la presenza di una mappa eBPF non ne dimostra l'uso. Occorre
osservare regole e contatori, entry conntrack, traduzione della destinazione o
telemetria riferita alle connessioni generate.

Nel laboratorio:

- la procedura E01 comprende il controllo del ClusterIP e dei due backend, ma
  la selezione pubblica E01 non conserva output autonomi di questi test e non
  li presenta quindi come risultati pubblicamente dimostrati;
- E10 ha attribuito i flussi osservati a kube-proxy iptables;
- E20 ha attribuito due connessioni controllate al data plane eBPF Cilium,
  pur mantenendo kube-proxy installato.

## NetworkPolicy

Una risorsa Kubernetes `NetworkPolicy` dichiara quali flussi sono ammessi per
i Pod selezionati, principalmente per indirizzo, protocollo e porta. L'API non
filtra i pacchetti: un controller deve tradurre la dichiarazione e un data
plane deve applicarla.

Il confronto E02 ha isolato questa responsabilità nello stack K3s/Flannel. Con
il controller NetworkPolicy K3s attivo, la policy ha prodotto la matrice deny
e allow e artefatti netfilter/ipset coerenti; con il controller disabilitato,
gli stessi oggetti erano presenti nell'API ma tutte le connessioni restavano
consentite e gli snapshot kernel pertinenti non cambiavano. Flannel manteneva
la connettività in entrambi i casi.

E10 e E20 hanno applicato gli stessi manifest con motori differenti: Felix e
il data plane Linux iptables in Calico; revisioni endpoint, policy map e
programmi eBPF in Cilium, con verdetti Hubble sui flussi.

## Matrice dei ruoli architetturali

Legenda: **N** = funzione nativa; **O** = modalità o modulo opzionale; **D** =
delegata; **C** = composizione; **—** = non è un obiettivo proprio. La matrice
riassume famiglie di configurazioni documentate e non sostituisce la modalità
effettivamente installata.

| Soluzione | Ruolo | Rete Pod e IPAM | Trasporto/routing inter-node | Data plane / packet processing | Policy | Service |
|---|---|---|---|---|---|---|
| Flannel | fabric L3 essenziale | C/D | N: VXLAN, `host-gw`, WireGuard | C: routing/bridge Linux e plugin delegati | D | D |
| Calico | networking L3, sicurezza e IPAM | N, `host-local` O | N: VXLAN, IP-in-IP o routing nativo/BGP | N: Linux iptables/nftables; eBPF o VPP O | N | D/cooperazione con kube-proxy nei data plane Linux iptables/nftables; N con eBPF o VPP |
| Cilium | piattaforma eBPF dai livelli 3–7 | N, più modalità | N: VXLAN/Geneve o routing nativo | N: eBPF e routing Linux | N | N: ClusterIP in-cluster per-packet con `kubeProxyReplacement=false`; sostituzione completa con `true` |
| Antrea | piattaforma L3/L4 basata su OVS | N/D | N: Encap, NoEncap, Hybrid | N: OVS/OpenFlow | N | N/O tramite AntreaProxy |
| OVN-Kubernetes | Software Defined Network OVN/OVS | N | N: Geneve; no-overlay L3/BGP O | N: OVN/OVS | N tramite Access Control List | N tramite load balancer OVN |
| kube-router | agente Linux modulare | D | N/O: BGP, IP-in-IP, Foo-over-UDP | N/O: routing Linux, iptables, IPVS | N/O | N/O tramite IP Virtual Server |
| Canal | composizione Flannel e Calico | C | C: backend Flannel | C: bridge/routing Linux e netfilter Calico | C | D |
| Multus | meta-plugin per più reti | D | D | D | D | D |
| CNI cloud | integrazione con il provider | N/C | N/C: underlay o overlay gestito | N/C/D: provider, kernel o eBPF | N/O/D | N/D |

## Soluzioni e famiglie

### Flannel

Il [progetto Flannel](https://github.com/flannel-io/flannel) è focalizzato
sulla connettività di livello 3 fra subnet dei nodi. In
Kubernetes viene composto con plugin che collegano il container al nodo e con
IPAM, mentre il backend stabilisce come raggiungere le subnet remote. Le
modalità comprendono VXLAN, `host-gw` e, in K3s, `wireguard-native`. Non
implementa autonomamente NetworkPolicy o Service.

**Verificato:** VXLAN e separazione dal controller NetworkPolicy K3s in E01 ed
E02. **Non verificato:** `host-gw`, WireGuard e altri backend.

### Calico

L'[architettura Calico](https://docs.tigera.io/calico/latest/reference/architecture/overview)
integra CNI, IPAM, routing e policy. Con il data plane Linux Felix
programma route e netfilter; il traffico inter-node può usare VXLAN,
IP-in-IP o routing senza overlay. BGP può distribuire la raggiungibilità, ma
non è necessario in una rete solo VXLAN. Calico dispone anche di data plane
eBPF, nftables e VPP, che sono configurazioni distinte.

Nel Kubernetes Datastore, Felix riceve gli aggiornamenti rilevanti e applica
la policy; il policy controller di `calico-kube-controllers` documentato per
il datastore etcd non va attribuito alla configurazione provata. Con i data
plane Linux iptables/nftables i Service restano normalmente a kube-proxy; il
[data plane eBPF](https://docs.tigera.io/calico/latest/operations/ebpf/use-cases-ebpf)
può sostituirlo, mentre il
[data plane VPP](https://docs.tigera.io/calico/latest/getting-started/kubernetes/vpp/getting-started)
implementa nativamente i Service senza kube-proxy.

**Verificato:** Calico Open Source 3.32.1, Calico IPAM, VXLAN, BGP
disabilitato, Linux iptables, policy Felix e kube-proxy mantenuto in E10.
**Non verificato:** BGP/no-overlay, IP-in-IP, nftables, VPP ed eBPF.

### Cilium

Cilium usa programmi e mappe eBPF per networking, policy, bilanciamento e
osservabilità. La documentazione della versione studiata descrive
[routing e tunnel](https://github.com/cilium/cilium/blob/v1.19.6/Documentation/network/concepts/routing.rst),
mentre [Hubble](https://github.com/cilium/cilium/blob/v1.19.6/Documentation/observability/hubble/index.rst)
espone identità, flussi e motivi di drop. Le policy Kubernetes e quelle proprie
sono realizzate in eBPF. In Cilium 1.19.6,
[`kubeProxyReplacement=false`](https://github.com/cilium/cilium/blob/v1.19.6/Documentation/network/kubernetes/kubeproxy-free.rst)
abilita comunque il bilanciamento per-packet dei ClusterIP in-cluster;
`kubeProxyReplacement=true` abilita la sostituzione completa di kube-proxy.

**Verificato:** Cilium 1.19.6, Cluster Pool IPAM, VXLAN, veth/eBPF, Hubble
locale, normali NetworkPolicy Kubernetes e kube-proxy mantenuto in E20.
**Non verificato:** native routing, Geneve, kube-proxy replacement,
cifratura, funzioni L7 e Cluster Mesh.

### Antrea

La [documentazione Antrea 2.6.2](https://antrea.io/docs/v2.6.2/) descrive una
rete primaria basata su OVS e flussi OpenFlow. Supporta modalità
Encap, NoEncap e Hybrid; il controller distribuisce lo stato e gli agenti
programmano OVS. Implementa NetworkPolicy e può usare AntreaProxy per i
Service. `antctl`, Traceflow e l'ispezione OpenFlow sono strumenti centrali.

**Ambito:** descrizione teorica; non incluso nel laboratorio.

### OVN-Kubernetes

L'[architettura OVN-Kubernetes](https://ovn-kubernetes.io/1.3/design/architecture/)
traduce oggetti Kubernetes in switch, router, Access Control
List (ACL) e load balancer logici OVN; OVS realizza il forwarding sui nodi.
L'overlay predefinito usa Geneve; la
[modalità no-overlay](https://ovn-kubernetes.io/1.3/okeps/okep-5259-no-overlay/)
usa routing diretto L3 e BGP per scambiare le route delle subnet Pod. EVPN è
un [meccanismo BGP distinto](https://ovn-kubernetes.io/1.2/okeps/okep-5088-evpn/)
per integrare reti primarie user-defined L2 o L3 con fabric esterni. Policy e
Service appartengono al modello logico OVN.

**Ambito:** descrizione teorica; non incluso nel laboratorio.

### kube-router

Secondo la documentazione su
[come opera kube-router](https://www.kube-router.io/docs/how-it-works/), il
progetto combina moduli separabili per routing Pod, firewall NetworkPolicy
e Service proxy. Può scambiare PodCIDR con BGP, programmare policy con
iptables/ipset e implementare Service tramite IP Virtual Server (IPVS).
L'invocazione CNI per-Pod resta delegata ai plugin configurati.

K3s incorpora la libreria del solo controller NetworkPolicy: E02 non ha
misurato i moduli BGP o IPVS di kube-router.

### Canal

La [configurazione Canal documentata da Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/flannel/install-for-flannel)
è una composizione: Flannel e `host-local` forniscono trasporto e
indirizzamento, mentre componenti Calico forniscono CNI e policy. Non è un
quarto data plane autonomo. I Service restano normalmente delegati a
kube-proxy.

**Ambito:** descrizione teorica; non incluso nel laboratorio.

### Multus

La [documentazione Multus](https://k8snetworkplumbingwg.github.io/multus-cni/)
lo definisce come meta-plugin: riceve la chiamata CNI e delega a una rete
primaria e a reti secondarie descritte da `NetworkAttachmentDefinition`,
associando più interfacce allo stesso Pod. Le reti aggiuntive possono essere
realizzate, per esempio, con `macvlan` o `ipvlan`; con SR-IOV, Multus passa al
plugin delegato l'identificativo del dispositivo assegnato. Questa composizione
è pertinente a workload multi-homed e a scenari NFV/telco o industriali che
richiedono reti separate o accesso diretto a dispositivi. Multus non decide
autonomamente IPAM, trasporto inter-node, policy o Service: tali proprietà
appartengono ai delegate.

**Ambito:** descrizione teorica; non incluso nel laboratorio.

### Famiglie CNI cloud

Le soluzioni cloud integrano rete Kubernetes, indirizzi e interfacce del
provider:

- [Amazon Elastic Kubernetes Service (EKS) VPC CNI](https://docs.aws.amazon.com/eks/latest/best-practices/vpc-cni.html)
  gestisce Elastic Network
  Interface, prefissi e indirizzi Virtual Private Cloud; policy e Service
  dipendono dai componenti abilitati;
- [Azure CNI](https://learn.microsoft.com/en-us/azure/aks/concepts-network-cni-overview)
  offre modalità flat e overlay; Azure CNI powered by Cilium combina
  il control plane Azure con il data plane eBPF;
- [Google Kubernetes Engine (GKE) VPC-native](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
  usa alias IP, mentre Dataplane V2
  è una configurazione Cilium/eBPF distinta.

Senza l'infrastruttura del provider, k3d non può riprodurre i meccanismi
caratteristici di queste famiglie. **Ambito:** descrizione teorica; famiglie
non incluse nel laboratorio.

## Fonti principali

- [Kubernetes: Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [CNI Specification](https://www.cni.dev/docs/spec/)
- [CNI reference plugins](https://github.com/containernetworking/plugins)
- [Flannel](https://github.com/flannel-io/flannel)
- [Calico: architecture](https://docs.tigera.io/calico/latest/reference/architecture/overview)
- [Calico: networking options](https://docs.tigera.io/calico/latest/networking/determine-best-networking)
- [Cilium 1.19.6: routing](https://github.com/cilium/cilium/blob/v1.19.6/Documentation/network/concepts/routing.rst)
- [Cilium 1.19.6: Hubble](https://github.com/cilium/cilium/blob/v1.19.6/Documentation/observability/hubble/index.rst)
- [Antrea 2.6.2](https://antrea.io/docs/v2.6.2/)
- [OVN-Kubernetes architecture](https://ovn-kubernetes.io/1.3/design/architecture/)
- [kube-router: how it works](https://www.kube-router.io/docs/how-it-works/)
- [Calico 3.32.1: Canal](https://docs.tigera.io/calico/latest/getting-started/kubernetes/flannel/install-for-flannel)
- [Multus documentation](https://k8snetworkplumbingwg.github.io/multus-cni/)
- [SR-IOV CNI](https://github.com/k8snetworkplumbingwg/sriov-cni)
- [Amazon EKS VPC CNI](https://docs.aws.amazon.com/eks/latest/best-practices/vpc-cni.html)
- [Azure CNI](https://learn.microsoft.com/en-us/azure/aks/concepts-network-cni-overview)
- [GKE VPC-native](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
