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
salute non hanno mostrato divergenze capaci di invalidare i singoli casi, ma
il confronto non è quindi byte-identico a livello di runtime host. Queste
versioni appartengono alle sessioni da cui derivano le evidence storiche; la
validation end-to-end della guida al commit
`d392dfb9b54753eb7e998d9620e02b01dbc36a2a` ha usato Docker `29.7.2` per tutti
e quattro gli esperimenti e non modifica gli output storici.

Le evidence storiche E20 registrano il kernel `7.0.0-28-generic`. Prima della
full validation sul validator era stato osservato `7.0.0-30-generic`, ma la
repository non conserva un output della full validation sufficiente ad
attribuirle con certezza una release kernel precisa. Le due osservazioni non
vengono quindi uniformate.

## Ambito delle prove Service e NetworkPolicy

La procedura E01 comprende il controllo del ClusterIP e dei due backend, ma la
selezione pubblica non conserva output autonomi di tali test e non ne sostiene
una dimostrazione pubblica; E01 non isola causalmente il componente Service.
E10 ha attribuito i flussi osservati a kube-proxy iptables. In E20 due nuove
connessioni ClusterIP hanno prodotto
stato conntrack eBPF coerente, mentre i contatori kube-proxy pertinenti sono
rimasti invariati. Quest'ultima conclusione vale soltanto per quei flussi dal
Pod client; kube-proxy era ancora installato.

La matrice NetworkPolicy riguarda regole ingress Kubernetes e nuove
connessioni HTTP dirette ai Pod IP sulla porta TCP 8080. Non valuta policy
egress, Domain Name System (DNS), policy proprietarie Calico o Cilium,
livello 7, grandi insiemi di regole o elevato churn degli endpoint.

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
