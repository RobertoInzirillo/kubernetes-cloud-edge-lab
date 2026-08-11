# Kubernetes Cloud–Edge Lab

Repository tecnica della tesi magistrale:

> **Federated Multicluster Orchestration and Networking in the Cloud–Edge
> Continuum**

Questa versione documenta lo studio del networking Kubernetes e della
Container Network Interface (CNI). Il campione sperimentale comprende Flannel
VXLAN nello stack K3s, Calico Open Source 3.32.1 con VXLAN e data plane Linux
iptables, e Cilium 1.19.6 con VXLAN e data plane eBPF. Il confronto riguarda
configurazioni precise, non i progetti in astratto.

## Risultati disponibili

| ID | Configurazione o domanda | Esito |
|---|---|---|
| E01 | Flannel VXLAN: percorso Pod-to-Pod intra-node e inter-node | Completato |
| E02 | NetworkPolicy K3s/Flannel con controller attivo e disabilitato | Completato |
| E10 | Calico 3.32.1, VXLAN e data plane Linux iptables | Completato |
| E20 | Cilium 1.19.6, VXLAN e data plane eBPF | Completato |
| E30 | Confronto controllato derivato da E01, E02, E10 ed E20 | Completato |

E30 è un confronto analitico: non ha creato cluster, generato traffico o
prodotto benchmark. Il routing Flannel `host-gw`, Calico BGP/no-overlay, i
data plane Open vSwitch (OVS) e altre modalità non sono inclusi nel campione;
possono costituire estensioni successive, ma non sono presentati come
esperimenti esistenti.

## Metodo in sintesi

- Le versioni, le immagini e le configurazioni rilevanti sono bloccate; gli
  identificativi effimeri sono rilevati nuovamente a ogni esecuzione.
- Il confronto usa cluster nuovi, la stessa topologia logica, lo stesso
  workload e flussi applicativi equivalenti.
- Una configurazione dichiarata viene distinta dal comportamento realmente
  osservato durante uno specifico flusso.
- Il percorso e l'attribuzione sono sostenuti da route, interfacce, catture,
  contatori, log o stato del data plane, non dalla sola connettività.
- I risultati sono circoscritti a nodi k3d containerizzati, kernel host
  condiviso e rete Docker usata come underlay.

## Struttura

```text
.
├── README.md
├── docs/
│   ├── cni-overview.md
│   ├── reproduction-guide.md
│   ├── cni-comparison.md
│   └── limitations.md
├── experiments/cni/
│   ├── e01-flannel-vxlan/
│   ├── e02-networkpolicy/
│   ├── e10-calico-vxlan/
│   └── e20-cilium-vxlan/
├── manifests/cni/
│   ├── common/
│   ├── calico/
│   └── cilium/
└── scripts/cni/calico/
```

I manifest comuni fissano workload e NetworkPolicy; le directory Calico e
Cilium contengono le configurazioni specifiche. Lo script Calico è il
post-renderer usato per bloccare l'immagine del Tigera Operator.

## Percorso di lettura e riproduzione

1. La [panoramica CNI](docs/cni-overview.md) introduce modello e tassonomia.
2. La [guida di riproduzione](docs/reproduction-guide.md) è il percorso
   operativo principale per E01, E02, E10 ed E20.
3. I README dei [singoli esperimenti](experiments/cni/) descrivono domande,
   configurazioni, risultati e attribuzioni.
4. Il [confronto controllato](docs/cni-comparison.md) sintetizza le differenze
   osservate.
5. I [limiti](docs/limitations.md) definiscono l'ambito nel quale i risultati
   possono essere generalizzati.

La baseline usa k3d `v5.9.0`, K3s `v1.34.9+k3s1`, Kubernetes `1.34.9`,
`kubectl` `v1.34.9`, Helm `v3.21.3` e BusyBox `1.38.0`. Le immagini K3s e
BusyBox sono referenziate mediante digest. Calico e Cilium hanno artefatti
versionati dedicati.

Ogni esperimento include una selezione delle evidenze originali necessarie a
sostenere i risultati, con indice pubblico e SHA-256. La selezione non è un
dataset esaustivo di ogni comando o tentativo della campagna storica.
