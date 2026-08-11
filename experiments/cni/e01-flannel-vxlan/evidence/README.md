# Evidenze pubbliche E01

Questa directory conserva i quattro output originali conclusivi selezionati
dalla sessione E01 del 2 agosto 2026. I file `.log` sono copie byte-identiche;
questo indice e `SHA256SUMS` sono metadata creati per la selezione pubblica.

| File | Tipo | Affermazione sostenuta |
|---|---|---|
| `intra-node-client-veth.log` | output originale di cattura | Il flusso HTTP intra-node attraversa la veth del `client` e termina correttamente, senza pacchetti scartati dal kernel. |
| `inter-node-vxlan-capture.log` | output originale di cattura | Lo stesso flusso inter-node compare su veth, `cni0`, `flannel.1` ed `eth0`; l'involucro underlay usa UDP 8472 e VNI 1. |
| `inter-node-http-flow.log` | output originale applicativo | Il GET correlato alla cattura riceve `server-b` e termina con exit code `0`. |
| `inter-node-summary.log` | output originale di controllo | Registra IP, filtro, comando generale, exit code e assenza di processi residui della procedura inter-node. |

La correlazione fra `inter-node-http-flow.log` e
`inter-node-vxlan-capture.log` usa lo stesso intervallo temporale, gli stessi
indirizzi e il payload HTTP. Il confronto fra frame interno ed esterno
sostiene l'incremento di 50 byte attribuito all'incapsulamento.

La selezione storica E01 era già circoscritta a questi file autorevoli. Non
contiene output autonomi per ogni controllo preliminare, per l'intera matrice
di connettività o per tutti i test Service/DNS; non va quindi interpretata
come trascrizione completa della sessione. PID, IP, porte e nomi delle veth
sono identificativi validi soltanto per l'esecuzione originale.
