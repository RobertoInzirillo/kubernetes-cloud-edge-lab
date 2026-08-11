# Evidenze pubbliche E10

Questa directory conserva una selezione degli output originali autorevoli di
E10. Tutti i file elencati sono copie byte-identiche dalla sessione del 5
agosto 2026; questo indice e `SHA256SUMS` sono metadata editoriali della
selezione pubblica.

| File o gruppo | Tipo | Affermazione sostenuta |
|---|---|---|
| `baseline-calico-resources.yaml`, `imageset-observed-final.yaml`, `final-calico-pod-images.txt` | output originali | Configurazione finale Calico 3.32.1, CNI/IPAM Calico, data plane iptables e immagini effettive per digest. |
| `baseline-ipam-vxlan-dataplane.log`, `workload-ipam-after.yaml` | output originali | IPPool `10.42.0.0/16`, blocchi `/26`, VXLAN e allocazione Calico IPAM. |
| `baseline-node-network.log`, `workload-topology-validation.log`, `workload-pod-veth-mapping.log` | output originali | Rete dei nodi, topologia del workload, veth `cali*`, route L3 e assenza di `cni0`. |
| `networking-matrix.log`, `intra-node-attribution.log` | output originali | Connettività ICMP/HTTP e percorso intra-node tramite veth e routing L3. |
| `inter-node-vxlan-capture.log`, `inter-node-vxlan-http-flow.log`, `inter-node-vxlan-summary.log` | cattura e controlli originali | Il GET riuscito è correlato al percorso `cali*`–`vxlan.calico`–`eth0`, UDP 4789, VNI 4096 e incremento di 50 byte. |
| `service-kube-proxy-attribution-corrected.log` | output originale autorevole | Catene `KUBE-SVC`/`KUBE-SEP`, DNAT e delta mirato dei contatori attribuiscono i flussi Service a kube-proxy iptables. |
| `policy-matrix-*.log`, `policy-*-api.yaml` | matrici e viste API originali | Le tre matrici producono 6/6 consentite, 6/6 negate e 4/6 consentite con gli oggetti Kubernetes attesi. |
| `policy-final-agent-*-ipsets.log`, `policy-final-agent-*-netfilter.log` | snapshot originali | Selector, IPSet, catene e contatori finali corrispondono alla allow mirata. |
| `policy-structural-deltas.log`, `policy-counter-deltas.log` | confronti originali | Le variazioni strutturali e dei contatori seguono i tre stati della matrice. |
| `policy-controller-felix-logs.log`, `policy-attribution-summary.log` | log e riepilogo originali | Felix riceve gli aggiornamenti dal calculation graph e programma policy/IPSet; kube-router è assente e kube-controllers espone soltanto `node,loadbalancer`. |

La cattura e il log HTTP appartengono allo stesso GET controllato. Sono stati
esclusi i tentativi procedurali superati, la prima lettura non autorevole del
Service, i rendering Helm e gli inventari duplicati. I riferimenti runtime,
inclusi sandbox dei Pod, PID, IP, veth e nomi delle catene, valgono soltanto
per l'esecuzione originale.
