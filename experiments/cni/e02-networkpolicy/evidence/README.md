# Evidenze pubbliche E02

La selezione mantiene separati il cluster con controller NetworkPolicy K3s
attivo (`policy-on/`) e quello con controller disabilitato (`policy-off/`). I
file nelle due sottodirectory sono output originali byte-identici. Questo
README e `SHA256SUMS` sono stati aggiunti per indicizzare e verificare la
selezione.

| File o gruppo | Tipo | Affermazione sostenuta |
|---|---|---|
| `policy-on/topology-validation.log` e `policy-off/topology-validation.log` | output originali | I due casi usano la stessa collocazione logica di client e server e workload pronti. |
| `policy-on/http-matrix-*.log` | matrici originali | Con controller attivo: baseline 6/6 consentita, default deny 6/6 negata, deny più allow 4/6 consentita. |
| `policy-off/http-matrix-*.log` | matrici originali | Con controller disabilitato tutte le 18 connessioni restano consentite. |
| `policy-on/*-apply-and-api.log` e `policy-off/*-apply-and-api.log` | output originali API | Nei due casi sono applicati gli stessi oggetti `NetworkPolicy`, con uno e poi due oggetti presenti nell'API. |
| `policy-on/controller-netfilter-baseline.log` | snapshot originale | Il controller `v2.6.3-k3s1` è avviato nel caso ON e sono presenti le catene kube-router di base. |
| `policy-on/counters-*.log` | snapshot originali mirati | Regole deny/allow, IPSet e contatori policy-specifici sono coerenti con i flussi osservati nel caso ON. |
| `policy-on/snapshot-comparison-summary.log` | riepilogo originale | Il numero di catene e IPSet cresce nei tre stati del caso ON. |
| `policy-off/kernel-artifacts-*.log` | snapshot originali mirati | Nessun artefatto IPv4, IPv6 o IPSet policy-specifico compare nel caso OFF. |
| `policy-off/delta-kernel-*.diff` | confronti originali | I quattro file vuoti registrano confronti byte-identici con la baseline OFF. |
| `policy-off/snapshot-comparison-summary.log` e `policy-off/on-off-comparison-summary.log` | riepiloghi originali | API, matrici e stato kernel convergono sull'attribuzione dell'enforcement al controller separato da Flannel. |

Gli snapshot completi e i delta più estesi che duplicavano queste prove non
sono inclusi. I file vuoti sotto `policy-off/` sono intenzionali: il loro hash
SHA-256 documenta l'assenza di differenze nel perimetro filtrato. Nomi di
catene, IPSet, contatori e indirizzi sono valori runtime e possono differire
in una nuova replica.
