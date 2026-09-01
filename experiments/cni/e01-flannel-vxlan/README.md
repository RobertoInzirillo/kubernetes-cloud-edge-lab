# E01 — Flannel VXLAN

## 1. Domanda sperimentale

Come viene configurata la rete dei Pod e quale percorso segue un pacchetto
intra-node e inter-node in un cluster K3s/k3d con Flannel e VXLAN?

## 2. Configurazione

- K3s con Flannel incorporato e backend VXLAN predefinito;
- un server e due agent k3d;
- Traefik disabilitato;
- kube-proxy e controller NetworkPolicy K3s mantenuti;
- blocchi CIDR Pod `10.42.0.0/16` e Service
  `10.43.0.0/16` predefiniti;
- workload comune con `client` e `server-a` sullo stesso agent e `server-b`
  sull'altro.

La procedura di riproduzione verifica la concatenazione CNI di `flannel`,
`portmap` e `bandwidth`. Flannel fornisce la raggiungibilità inter-node;
bridge e IPAM sono realizzati dai plugin delegati dello stack K3s.

## 3. Versioni rilevanti

| Componente | Versione o riferimento |
|---|---|
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| immagine K3s `linux/amd64` | `docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d` |
| Flannel incorporato | `v0.28.4` |
| Docker Engine/CLI | `29.6.2` |
| workload BusyBox | `docker.io/library/busybox@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8` |

## 4. Topologia

```text
host Linux
└── rete Docker k3d
    ├── server-0
    ├── agent-0: client, server-a
    └── agent-1: server-b
```

Le label `tesi-placement=a` e `tesi-placement=b` determinano la collocazione.
Il Service `servers` seleziona i due Pod HTTP sulla porta TCP 8080.

## 5. Riproduzione

La procedura completa, dalla creazione del cluster alla mappatura Pod–veth,
alla cattura VXLAN e alla rimozione finale, è nella
[sezione E01 del manuale](../../../docs/reproduction-guide.md#8-e01--flannel-vxlan).
Questo README conserva la domanda scientifica e i risultati, mentre il
manuale è l'unica fonte operativa.

## 6. Risultati osservati

- flusso HTTP intra-node osservato sulla veth del `client`, con richiesta a
  `server-a` e risposta HTTP `200 OK`;
- percorso inter-node osservato `veth → cni0 → flannel.1 → eth0`, con
  risposta nel verso inverso;
- pacchetto interno con IP dei Pod conservati e datagramma esterno fra gli IP
  underlay, UDP 8472 e VNI 1;
- incremento di 50 byte fra frame interno ed esterno, coerente con Ethernet,
  IPv4, UDP e VXLAN;
- GET inter-node e procedura di cattura terminati con exit code `0`, zero
  pacchetti scartati dal kernel e nessun processo residuo.

## 7. Attribuzione

Flannel, il subnet manager e i plugin CNI configurano subnet, bridge, route e
VTEP. Il kernel Linux realizza bridge, forwarding e
incapsulamento nel data plane. La cattura correla lo stesso flusso applicativo
fra pacchetto interno e involucro underlay: il percorso non è dedotto dalla
sola presenza di `flannel.1`.

E01 non attribuisce causalmente il Service a kube-proxy con lo stesso livello
di isolamento usato negli esperimenti successivi. L'enforcement delle
NetworkPolicy viene studiato separatamente in E02.

## 8. Evidenze pubbliche

La [selezione delle evidenze originali](evidence/) conserva le catture
intra-node e inter-node, il GET correlato e il riepilogo della procedura. Il
relativo indice collega ciascun file alle affermazioni sostenute e ne esplicita
i limiti; `SHA256SUMS` permette di verificarne l'integrità. La selezione non
contiene output autonomi per readiness, configurazione CNI completa, matrice
di connettività o Service/DNS. La guida include tali controlli, ma, non essendo
presenti output autonomi nella selezione storica, non sono elencati qui come
risultati pubblicamente dimostrati.

Dalla directory dell'esperimento, verificare l'integrità della selezione con:

```bash
cd evidence
sha256sum -c SHA256SUMS
```

Tutti i file devono risultare `OK`.

## 9. Limiti

- nodi containerizzati, kernel host condiviso e rete Docker come underlay;
- nessuna conclusione su prestazioni o scala;
- `host-gw` e altri backend non provati;
- la cattura su `any` osserva lo stesso pacchetto su più interfacce;
- le indicazioni `bad udp cksum` sono compatibili con checksum offload e non
  indicano corruzione nel flusso riuscito.

## 10. Rimozione

Il comando e i controlli post-delete sono nella sezione E01 del manuale. La
rimozione riguarda esclusivamente il cluster `tesi-flannel-vxlan`.
