# Kubernetes Cloud–Edge Lab

Repository tecnica della tesi magistrale:

> **Federated Multicluster Orchestration and Networking in the Cloud–Edge
> Continuum**

Questa versione documenta la prima fase dello studio, dedicata al networking
Kubernetes e alla Container Network Interface (CNI) in ambito single-cluster.
L'obiettivo è confrontare concretamente approcci differenti alla rete dei Pod,
al traffico fra nodi, ai Service e alle NetworkPolicy. Il campione comprende
Flannel VXLAN nello stack K3s, Calico Open Source 3.32.1 con VXLAN e data plane
Linux iptables, e Cilium 1.19.6 con VXLAN e data plane eBPF. Il confronto
riguarda configurazioni precise, non i progetti in astratto.

Il campione rappresenta tre profili architetturali: Flannel come baseline
semplice di networking L3 con overlay VXLAN, senza enforcement NetworkPolicy
proprio; Calico come soluzione più estesa e modulare, con IPAM, policy e data
plane Linux tradizionale nel profilo provato; Cilium come approccio eBPF, con
data plane e osservabilità significativamente differenti. La scelta non
esaurisce l'ecosistema CNI: la panoramica teorica copre altre famiglie senza
moltiplicare gli esperimenti.

Multicluster, federazione, cloud-edge e networking inter-cluster sono
deliberatamente fuori dal perimetro di questa prima fase single-cluster.
Saranno affrontati nel seguito della tesi sulla base delle indicazioni del
correlatore.

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
    ├── common/
    │   ├── lab-env.sh
    │   ├── capture.sh
    │   └── service.sh
    ├── k3s/e02-policy.sh
    ├── calico/
    │   ├── e10-policy.sh
    │   ├── e10-service.sh
    │   └── pin-tigera-operator-image.sh
    └── cilium/
        ├── network-policy.sh
        ├── policy-observers.sh
        └── service.sh
```

I manifest fissano workload, NetworkPolicy e configurazioni dei CNI. Gli script
raccolgono le operazioni ripetibili di preparazione, cattura e osservazione;
la guida di riproduzione mostra i comandi, il loro scopo e gli output da
controllare.

## Percorso di lettura

1. La [panoramica CNI](docs/cni-overview.md) introduce il modello CNI, i
   principali approcci al networking Kubernetes e le soluzioni considerate.
2. La [guida di riproduzione](docs/reproduction-guide.md) prepara l'ambiente e
   accompagna nell'esecuzione di E01, E02, E10 ed E20.
3. I README dei [singoli esperimenti](experiments/cni/) riepilogano le domande
   sperimentali, le configurazioni utilizzate, i risultati osservati e le
   relative attribuzioni.
4. Il [confronto controllato](docs/cni-comparison.md) mette a confronto
   Flannel, Calico e Cilium sulla base delle configurazioni effettivamente
   studiate.
5. I [limiti](docs/limitations.md) definiscono l'ambito nel quale i risultati
   possono essere interpretati e generalizzati.

La procedura è stata verificata end-to-end, includendo una riproduzione
avviata da un'installazione Linux pulita. Ambiente, versioni e riferimenti
necessari sono documentati nella guida; le evidence pubblicate sono protette
da checksum SHA-256.

La baseline usa k3d `v5.9.0`, K3s `v1.34.9+k3s1`, Kubernetes `1.34.9`,
`kubectl` `v1.34.9`, Helm `v3.21.3` e BusyBox `1.38.0`. Le immagini K3s e
BusyBox sono referenziate mediante digest. Calico e Cilium hanno artefatti
versionati dedicati.

Ogni esperimento include una selezione delle evidenze originali necessarie a
sostenere i risultati, con indice pubblico e SHA-256. La selezione non
comprende tutti i comandi e gli output prodotti durante lo sviluppo.
