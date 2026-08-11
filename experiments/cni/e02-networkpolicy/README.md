# E02 — Attribuzione delle NetworkPolicy in K3s/Flannel

## 1. Domanda sperimentale

Mantenendo invariati K3s, Flannel VXLAN, topologia e workload, l'enforcement
delle NetworkPolicy è realizzato da Flannel oppure dal controller
NetworkPolicy incorporato in K3s?

## 2. Configurazione

Sono stati creati in sequenza due cluster puliti. L'unica variabile
indipendente era il controller NetworkPolicy:

| Ambiente | Configurazione |
|---|---|
| `tesi-e02-flannel-netpol-on` | controller K3s predefinito attivo |
| `tesi-e02-flannel-netpol-off` | `--disable-network-policy` sul server |

Entrambi usavano Flannel VXLAN, un server, due agent, Traefik disabilitato e
lo stesso workload di E01. La matrice causale usava HTTP diretto agli indirizzi
IP dei Pod, non DNS o ClusterIP, per non introdurre resolver e kube-proxy come
fattori di confondimento.

## 3. Versioni rilevanti

| Componente | Versione o riferimento |
|---|---|
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| immagine K3s `linux/amd64` | `docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d` |
| Flannel | `v0.28.4` incorporato in K3s |
| controller NetworkPolicy | `v2.6.3-k3s1`, basato sulla libreria netpol di kube-router |
| Docker Engine/CLI | `29.6.2` |
| workload | BusyBox `1.38.0` per digest nel manifest comune |

## 4. Topologia

In entrambi i cluster:

```text
agent-0: client, server-a
agent-1: server-b
server-0: control plane, senza workload del test
```

Ogni flusso è stato aperto due volte con una nuova connessione TCP:

- `client → server-a`;
- `client → server-b`;
- `server-a → server-b`, controllo negativo per l'allow mirata.

## 5. Riproduzione

La procedura completa dei cluster ON e OFF, comprese le 18 connessioni per
cluster e le letture iptables/IPSet, è nella
[sezione E02 del manuale](../../../docs/reproduction-guide.md#9-e02--attribuzione-delle-networkpolicy-nello-stack-k3s).

## 6. Risultati osservati

| Stato | Cluster ON | Cluster OFF |
|---|---:|---:|
| nessuna policy | 6/6 consentiti | 6/6 consentiti |
| `default-deny-ingress` | 6/6 negati | 6/6 consentiti |
| deny + allow mirata | 4 consentiti, 2 negati | 6/6 consentiti |

Nel cluster OFF gli oggetti dell'API sono
passati da zero a uno e poi a due, ma tutte le 18 connessioni sono riuscite.
Quattro confronti normalizzati degli artefatti kernel con la baseline OFF
sono rimasti byte-identici.

Nel cluster ON sono comparsi catene e IPSet policy-specifici e contatori
coerenti con deny e allow. I Pod destinazione sono rimasti pronti e senza
restart, escludendo un guasto applicativo come spiegazione dei flussi negati.

## 7. Attribuzione

L'esperimento separa quattro responsabilità:

1. l'API Kubernetes conserva la dichiarazione;
2. il controller K3s basato su kube-router la traduce;
3. il kernel Linux applica gli artefatti netfilter/ipset;
4. Flannel continua a fornire connettività Pod-to-Pod.

Il controllo OFF è decisivo: la presenza degli oggetti senza cambiamenti nei
flussi o nel data plane dimostra che l'API da sola non applica la policy. Nella
configurazione provata, l'enforcement non appartiene a Flannel.

## 8. Evidenze pubbliche

La [selezione delle evidenze originali](evidence/) mantiene separati
`policy-on/` e `policy-off/`. L'indice collega oggetti API, matrici HTTP,
artefatti netfilter/IPSet e confronti invarianti all'attribuzione causale;
`SHA256SUMS` copre tutti i file pubblicati.

## 9. Limiti

- conclusione circoscritta a K3s `v1.34.9+k3s1`, Flannel VXLAN e policy
  ingress TCP 8080;
- nessuna valutazione di egress, DNS, Service o altre varianti Flannel;
- nodi k3d con kernel host condiviso;
- indirizzi underlay diversi fra ON e OFF, ma ruoli e blocchi CIDR dei Pod,
  workload e flussi logici equivalenti;
- contatori kernel riferiti a pacchetti e regole, non al numero di richieste.

## 10. Rimozione

Il manuale elimina ON e OFF in momenti distinti. La rimozione dei cluster
dedicati elimina anche le NetworkPolicy senza modificare manualmente il data
plane dell'host.
