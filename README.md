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

| ID | Configurazione o domanda |
|---|---|
| E01 | Flannel VXLAN: percorso Pod-to-Pod intra-node e inter-node |
| E02 | NetworkPolicy K3s/Flannel con controller attivo e disabilitato |
| E10 | Calico 3.32.1, VXLAN e data plane Linux iptables |
| E20 | Cilium 1.19.6, VXLAN e data plane eBPF |
| E30 | Confronto controllato derivato da E01, E02, E10 ed E20 |

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
└── scripts/cni/
    ├── common/lab-env.sh
    └── calico/
```

I manifest comuni fissano workload e NetworkPolicy; le directory Calico e
Cilium contengono le configurazioni specifiche. Lo script comune ricostruisce
l'ambiente di shell degli esperimenti; lo script Calico è il post-renderer
usato per bloccare l'immagine del Tigera Operator.

## Percorso di lettura

1. La [panoramica CNI](docs/cni-overview.md) introduce il modello CNI, i
   principali approcci al networking Kubernetes e le soluzioni considerate.
2. I README dei [singoli esperimenti](experiments/cni/) descrivono le domande
   sperimentali, le configurazioni utilizzate, i risultati osservati e le
   relative attribuzioni.
3. Il [confronto controllato](docs/cni-comparison.md) mette a confronto
   Flannel, Calico e Cilium sulla base delle configurazioni effettivamente
   studiate.
4. I [limiti](docs/limitations.md) definiscono l'ambito nel quale i risultati
   possono essere interpretati e generalizzati.

Per chi vuole replicare il laboratorio, la
[guida di riproduzione](docs/reproduction-guide.md) descrive la procedura
completa per preparare un sistema pulito ed eseguire E01, E02, E10 ed E20.
La procedura consolidata al commit
`1dbcb290f10cc8dfa51715db03d2ba7da71bd57e` è stata inoltre eseguita
integralmente da stato sperimentale pulito sul validator già predisposto, con
toolchain e versioni verificate: E01, E02, E10, E20 e cleanup finale hanno
avuto esito PASS. Non si è trattato di una nuova installazione Linux vergine;
la cronologia completa della validation è registrata nella guida.

La baseline usa k3d `v5.9.0`, K3s `v1.34.9+k3s1`, Kubernetes `1.34.9`,
`kubectl` `v1.34.9`, Helm `v3.21.3` e BusyBox `1.38.0`. Le immagini K3s e
BusyBox sono referenziate mediante digest. Calico e Cilium hanno artefatti
versionati dedicati.

Ogni esperimento include una selezione delle evidenze originali necessarie a
sostenere i risultati, con indice pubblico e SHA-256. La selezione non
comprende tutti i comandi e gli output prodotti durante lo sviluppo.
