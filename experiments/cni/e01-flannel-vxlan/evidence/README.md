# Evidenze pubbliche E01

Questa directory conserva quattro output sperimentali originali selezionati
per E01. I file `.log` sono copie byte-identiche; questo README e
`SHA256SUMS` sono stati aggiunti per indicizzare e verificare la selezione.

| File | Tipo | Affermazione sostenuta |
|---|---|---|
| `intra-node-client-veth.log` | cattura sperimentale | Il flusso HTTP intra-node attraversa la veth del `client` e termina correttamente, senza pacchetti scartati dal kernel. |
| `inter-node-vxlan-capture.log` | cattura sperimentale | Lo stesso flusso inter-node compare su veth, `cni0`, `flannel.1` ed `eth0`; l'involucro underlay usa UDP 8472 e VNI 1. |
| `inter-node-http-flow.log` | output applicativo | Il GET correlato alla cattura riceve `server-b` e termina con exit code `0`. |
| `inter-node-summary.log` | output di controllo | Registra IP, filtro, comando generale, exit code e assenza di processi residui della procedura inter-node. |

La correlazione fra `inter-node-http-flow.log` e
`inter-node-vxlan-capture.log` usa lo stesso intervallo temporale, gli stessi
indirizzi e il payload HTTP. Il confronto fra frame interno ed esterno
sostiene l'incremento di 50 byte attribuito all'incapsulamento.

La selezione è circoscritta a questi file e non contiene output autonomi per
ogni controllo preliminare, per l'intera matrice di connettività o per tutti i
test Service/DNS. PID, IP, porte e nomi delle veth sono identificativi runtime
e possono differire in una nuova replica.
