# Evidenze pubbliche E20

Questa directory conserva gli output sperimentali originali selezionati per
sostenere i risultati E20. I file sono copie byte-identiche; questo README e
`SHA256SUMS` sono stati aggiunti per indicizzare e verificare la selezione.

| File o gruppo | Tipo | Affermazione sostenuta |
|---|---|---|
| `chart-integrity.log`, `helm-install.log` | output originali | Chart Cilium 1.19.6, checksum, installazione riuscita e valori effettivi finali. I percorsi riportati sono specifici dell'ambiente acquisito. |
| `node-ebpf-prerequisites.log`, `cilium-runtime-config.log`, `cni-bpf-datapath.log` | output originali | Prerequisiti eBPF, Cluster Pool IPAM, `CiliumNode`, configurazione CNI, mappe/programmi e `cilium_vxlan`. |
| `kubeproxy-flannel-netpol.log`, `optional-components.log` | output originali | kube-proxy è attivo; Flannel, controller NetworkPolicy K3s e componenti opzionali esclusi sono assenti. |
| `workload-topology-ipam.log`, `intra-node-path.log` | output originali | Pod IP, `CiliumEndpoint`, security identity, veth, route `cilium_host` e programmi TCX sostengono il percorso intra-node L3/eBPF. |
| `vxlan-capture-preflight.log`, `vxlan-capture-authoritative.log`, `vxlan-http-flow.log` | cattura e controlli originali | Un singolo GET riuscito è osservato su veth, `cilium_vxlan` ed `eth0`, con UDP 8472 fra gli indirizzi underlay. |
| `vxlan-capture-procedure.log`, `vxlan-capture-summary.log`, `vxlan-vni-offline-analysis.log` | output originali | Delimitano il falso negativo del parser e ricavano dal log esistente `instance=21766/16090`, coincidente con le identity delle sorgenti. |
| `service-topology.log`, `service-http-flows.log` | output originali | Il Service ha due backend Ready e le due connessioni controllate selezionano `server-a` e `server-b`. |
| `service-kubeproxy-before.log`, `service-kubeproxy-after.log`, `service-kubeproxy-delta.log` | snapshot originali | Le regole kube-proxy pertinenti esistono ma restano byte-identiche e con contatori invariati. |
| `service-cilium-bpf-before.log`, `service-cilium-bpf-after.log`, `service-cilium-ct-new.log` | snapshot originali | Frontend, RevNAT e backend eBPF sono presenti; dopo i flussi compaiono due entry `TCP SVC` con backend 7 e 8. |
| `service-hubble-flows.jsonl`, `service-attribution-summary.log` | flussi e riepilogo originali | Hubble correla le porte delle due connessioni ai backend e al percorso locale/overlay, sostenendo l'attribuzione circoscritta a Cilium eBPF. |
| `http-matrix-*.log`, `policy-apply-*.log`, `policy-reconcile-*.log` | matrici e output originali | Le normali Kubernetes NetworkPolicy producono 6/6 consentite, 6/6 negate e 4/6 consentite, con riconciliazione degli endpoint. |
| `policy-map-final-server-*.log`, `hubble-policy-representative.log` | snapshot e flussi originali | Le policy map consentono identity 21766 su 8080/TCP e Hubble mostra `FORWARDED` o `POLICY_DENIED` nei quattro casi rappresentativi. |
| `policy-comparison-summary.log`, `policy-final-gate.log` | riepiloghi finali | Revisioni 1→2→3, contatori, stato realizzato e componenti alternativi esclusi convergono sull'enforcement eBPF Cilium. |
| `inter-node-failure-diagnosis.log`, `recovery-reconciliation.log`, `recovery-inter-node-tests.log` | output originali mirati | Documentano in modo proporzionato la divergenza dell'endpoint underlay, la riconciliazione dopo il restart mirato e il ripristino ICMP/HTTP; la causa radice resta indeterminata. |

La selezione non include dati diagnostici preliminari, i JSONL Hubble completi
delle policy o snapshot duplicati quando un output mirato sostiene la stessa
affermazione. IP, PID, nomi dei Pod, veth, porte TCP e security identity sono
valori runtime e possono differire in una nuova replica.
