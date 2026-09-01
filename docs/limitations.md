# Limiti del laboratorio e delle conclusioni

Gli esperimenti sostengono attribuzioni funzionali e architetturali nelle
configurazioni provate. Non sono una graduatoria generale di Flannel, Calico
o Cilium e non misurano qualità, prestazioni o affidabilità complessive.

## Ambiente k3d e kernel condiviso

k3d esegue i nodi K3s come container Docker sullo stesso host. I nodi non
hanno kernel indipendenti: eBPF, netfilter, conntrack, moduli VXLAN e risorse
di calcolo dipendono dal medesimo kernel. Il laboratorio non riproduce kernel
eterogenei, isolamento dei guasti fra macchine, differenze di driver o
offload hardware.

La rete bridge Docker costituisce l'underlay. Le catture possono dimostrare
incapsulamento, indirizzi, porte e interfacce, ma non rappresentano switch e
router fisici, percorsi Equal-Cost Multi-Path (ECMP), Maximum Transmission
Unit (MTU) eterogenee o integrazioni con un cloud provider. Gli indirizzi dei
container nodo sono inoltre effimeri e possono cambiare dopo un riavvio.

## Famiglie IP e sistema operativo

Il laboratorio valuta networking IPv4 single-stack. Non valida IPv6 o
[dual-stack IPv4/IPv6](https://kubernetes.io/docs/concepts/services-networking/dual-stack/).
Host e nodi sono Linux; non vengono valutati nodi Windows né il relativo
[networking basato su Host Networking Service (HNS)](https://kubernetes.io/docs/concepts/services-networking/windows-networking/).
Questi confini definiscono lo scope della fase corrente e non implicano un
giudizio negativo sulle configurazioni escluse.

## Assenza di WAN, benchmark e scala

Il laboratorio non include Wide Area Network (WAN), siti edge fisicamente
separati, link intermittenti o domini amministrativi distinti. Non sono stati
misurati throughput, latenza, jitter, perdita sotto carico, consumo di CPU e
memoria o tempi di convergenza. La topologia di un server, due agent, tre Pod
e un Service non permette conclusioni sulla scala o sull'alta disponibilità.

## Variazioni del runtime host

K3s, topologia e manifest sono rimasti controllati, mentre Docker Engine/CLI
era `29.6.2` in E01 ed E02, `29.7.1` in E10 e `29.7.2` in E20. I controlli di
salute non hanno mostrato divergenze che invalidassero i singoli casi, ma il
runtime host non era byte-identico. Queste versioni appartengono alle sessioni
da cui derivano le evidence storiche. La procedura corrente usa Docker `29.7.2`
per tutti e quattro gli esperimenti e non modifica gli output storici.

Le evidence E20 registrano il kernel `7.0.0-28-generic`. Una nuova
riproduzione deve registrare la propria release; i risultati non vengono
generalizzati automaticamente a kernel differenti.

## Ambito delle prove Service e NetworkPolicy

La procedura E01 comprende il controllo del ClusterIP e dei due backend, ma la
selezione pubblica non conserva output autonomi di tali test e non ne sostiene
una dimostrazione pubblica; E01 non isola causalmente il componente Service.
E10 ha attribuito i flussi osservati a kube-proxy iptables. Nella sessione
storica E20, due nuove connessioni ClusterIP hanno prodotto stato conntrack
eBPF coerente, mentre i contatori kube-proxy pertinenti sono rimasti invariati.
La procedura B02 corrente applica lo stesso metodo a sei connessioni per
rafforzare la correlazione, senza modificare le evidence originali. La
conclusione vale soltanto per i flussi controllati dal Pod client; kube-proxy
era ancora installato.

La matrice NetworkPolicy riguarda regole ingress Kubernetes e nuove
connessioni HTTP dirette ai Pod IP sulla porta TCP 8080. Non valuta policy
egress, Domain Name System (DNS), policy proprietarie Calico o Cilium,
livello 7, grandi insiemi di regole o cambiamenti rapidi e frequenti degli
endpoint. Le evidence pubbliche conservano i tre stati baseline, default deny
e allow selettiva; il restore della guida corrente verifica soltanto il ritorno
alla baseline e non amplia il confronto scientifico.

## Configurazioni non incluse

Il confronto sperimentale copre tre modalità VXLAN. Possibili estensioni non
provate comprendono Flannel `host-gw`, Calico BGP/no-overlay, altri backend e
data plane Calico, Cilium native routing o kube-proxy replacement, un data
plane OVS, Antrea e OVN-Kubernetes. Non averle provate non costituisce un
risultato negativo su tali soluzioni.

## Selezione delle evidenze pubbliche

La repository conserva una selezione degli output originali necessari a
sostenere le conclusioni. Il materiale diagnostico preliminare, ridondante o
non necessario alle conclusioni non fa parte del dataset pubblico.
