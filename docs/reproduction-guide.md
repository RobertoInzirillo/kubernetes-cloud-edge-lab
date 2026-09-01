# Manuale di riproduzione degli esperimenti CNI

## 1. Come usare questa guida

### 1.1 Ottenere la repository

La procedura parte da una nuova installazione Zorin OS o Ubuntu compatibile con
Ubuntu 24.04 Noble, architettura `amd64`. Servono un account con `sudo` e
accesso a Internet. Installare Git, che verrà usato per ottenere la repository
e registrare con precisione lo snapshot riprodotto:

```bash
sudo -v
sudo apt-get update
sudo apt-get install -y git
git --version
```

Clonare quindi la repository nella home dell'utente ed entrarvi:

```bash
cd "$HOME"
git clone https://github.com/RobertoInzirillo/kubernetes-cloud-edge-lab.git
cd kubernetes-cloud-edge-lab
git status --short --branch
git rev-parse --verify HEAD
```

La validation end-to-end documentata di seguito ha usato il commit
`d392dfb9b54753eb7e998d9620e02b01dbc36a2a`. Per ogni nuova riproduzione,
registrare il tag o commit selezionato e il valore restituito da
`git rev-parse`.

### 1.2 Percorso della guida

Il manuale accompagna il lettore dalla preparazione di un host Linux alla
riproduzione di E01, E02, E10 ed E20. Preparazione e toolchain vanno eseguite
nell'ordine indicato; dopo le sezioni comuni ciascun esperimento può iniziare
dal proprio punto di ingresso. Salvo diversa indicazione, i comandi si
eseguono dalla radice della repository clonata. Ogni esperimento usa un
cluster distinto; eliminarlo al termine evita che interfacce, route o regole
residue influenzino il caso successivo.

La guida presenta la procedura consolidata per riprodurre configurazioni,
esperimenti, osservazioni e attribuzioni. Gli output già pubblicati descrivono
i risultati osservati nel laboratorio; una nuova esecuzione deve riprodurre i
comportamenti pertinenti, non gli stessi identificativi runtime.

Percorso di lavoro:

1. verificare la piattaforma e i comandi di sistema;
2. installare Docker Engine, kubectl, Helm e k3d;
3. controllare versioni, immagini e file bloccati;
4. definire le variabili e le funzioni comuni;
5. eseguire uno o più esperimenti dal relativo punto di ingresso;
6. controllare la rimozione dei cluster creati.

La prima validation incrementale di E01, E02, E10 ed E20 è marcata dal tag
`validation-pass-2026-08` sul commit
`ac33de8c31dc3d27efe1542b79ec05e4a4d886ae`. Successivamente, la guida al
commit `d392dfb9b54753eb7e998d9620e02b01dbc36a2a` è stata eseguita integralmente
da stato sperimentale pulito su un validator già predisposto, con Docker Engine
e CLI `29.7.2`, containerd.io host `2.3.4` e Docker Buildx `0.36.1`. E01, E02,
E10, E20 e cleanup finale hanno avuto esito PASS. Questa validation non è
partita da una nuova installazione Linux vergine e non sostituisce gli output
originali pubblicati come risultati degli esperimenti.

## 2. Ambiente di riferimento

Il validator già predisposto usato per la validation end-to-end eseguiva Zorin
OS 18.1, basato su Ubuntu 24.04 Noble, architettura `amd64`, control group v2
(cgroup v2) e Berkeley Packet Filter filesystem (bpffs). Prima della full
validation era stato osservato il kernel `7.0.0-30-generic`, ma non è
disponibile un output che lo attribuisca con certezza all'intera esecuzione. Le
evidence storiche E20 registrano invece `7.0.0-28-generic` e restano invariate.

I comandi APT seguenti sono scritti per Ubuntu Noble `amd64` e per il sistema
compatibile usato nel laboratorio. Altre distribuzioni possono essere
compatibili, ma non sono state verificate.

La macchina deve avere accesso a Internet per repository APT, registry delle
immagini, release binarie e chart Helm. Le catture richiedono `sudo` perché
entrano nel network namespace dei container nodo e aprono interfacce di rete.

## 3. Concetti pratici usati nel laboratorio

### Immagine container, tag e digest OCI

Un'immagine container contiene filesystem e configurazione necessari per
avviare un container. k3d usa l'immagine K3s per creare i nodi; Kubernetes usa
l'immagine BusyBox per i Pod del laboratorio.

Un **tag**, per esempio `rancher/k3s:v1.34.9-k3s1`, identifica una versione
logica ma può essere riassegnato. Un **digest Open Container Initiative (OCI)**,
per esempio `rancher/k3s@sha256:...`, identifica invece uno specifico manifest.
Gli esperimenti usano il digest `linux/amd64` per evitare ambiguità.

Un checksum SHA-256 verifica invece i byte di un file scaricato. Digest OCI e
checksum possono usare lo stesso algoritmo, ma identificano oggetti diversi.

### Helm, chart, values e post-renderer

Un **chart Helm** contiene template e valori predefiniti per risorse
Kubernetes; un file `values.yaml` ne personalizza il rendering. `helm template`
genera i manifest localmente senza installarli.

Un **post-renderer** riceve i manifest prodotti da Helm e li modifica prima
dell'applicazione. In E10 lo script versionato
[`scripts/cni/calico/pin-tigera-operator-image.sh`](../scripts/cni/calico/pin-tigera-operator-image.sh)
sostituisce il riferimento dell'immagine Tigera Operator con il digest
`linux/amd64` scelto per l'esperimento.

### CNI e IPAM

La Container Network Interface (CNI) definisce come il runtime configura la
rete dei Pod. L'IP Address Management (IPAM) assegna e rilascia i loro
indirizzi. La [panoramica CNI](cni-overview.md) approfondisce architetture e
responsabilità; qui i termini sono usati soltanto per leggere i comandi.

### Identificativi effimeri

Pod IP, ClusterIP, indirizzi underlay Docker, PID dei nodi, sandbox, veth,
porte sorgenti e security identity possono cambiare dopo una ricreazione o un
riavvio. Non vanno copiati dagli output pubblicati: le sezioni operative li
rileggono a runtime.

## 4. Preparazione dell'host

Installare le utility di download, verifica e diagnostica di rete richieste dal
laboratorio. Git è già stato installato per clonare la repository.

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  gpg \
  file \
  coreutils \
  diffutils \
  tar \
  gzip \
  grep \
  sed \
  mawk \
  tcpdump \
  util-linux \
  iproute2 \
  iptables \
  nftables \
  procps \
  kmod
```

Questo passaggio prepara anche `tcpdump`, `nsenter`, `ip`, `bridge`, `iptables`
e `nft`, usati più avanti per osservare namespace e data plane.

Controllare sistema, architettura e risorse disponibili:

```bash
cat /etc/os-release
uname -srmo
dpkg --print-architecture
getconf LONG_BIT
nproc
free -h
df -h /
stat -fc '%T %n' /sys/fs/cgroup
```

Il risultato deve indicare Ubuntu Noble o il sistema compatibile di
riferimento, `amd64`, 64 bit e `cgroup2fs` per `/sys/fs/cgroup`. Architettura e
cgroup v2 sono requisiti della baseline; se non corrispondono, non proseguire.

Per questo laboratorio a tre nodi sono raccomandati operativamente almeno 4
thread CPU, 8 GiB di RAM e 20 GiB liberi. Non sono minimi ufficiali di
Kubernetes o Cilium: se la macchina offre meno risorse, ridurre il carico
estraneo o prevedere timeout e possibili mancate convergenze durante la
replica.

Controllare forwarding, moduli di rete e prerequisiti eBPF. Il forwarding può
essere ancora `0` prima dell'avvio di Docker, ma dovrà risultare `1` nella
verifica finale. BTF e bpffs saranno necessari in E20.

```bash
sysctl net.ipv4.ip_forward
lsmod | grep -E '(^| )(br_netfilter|vxlan|overlay)( |$)' || true
ls -l /sys/kernel/btf/vmlinux
findmnt /sys/fs/bpf || true
```

Infine verificare che le utility installate siano disponibili nel `PATH`:

```bash
command -v gpg file sha256sum diff tar gzip grep sed awk \
  tcpdump nsenter timeout ip bridge ss iptables nft pgrep lsmod sysctl
iptables --version
nft --version
```

Se un comando richiesto non viene trovato, risolvere il problema prima di
installare la toolchain.

## 5. Installazione della toolchain

### 5.1 Docker Engine

Docker fungerà da runtime per i container che k3d userà come nodi K3s del
laboratorio. La procedura usa il repository APT ufficiale Docker per Ubuntu
Noble e installa le versioni della baseline consolidata.

Su un sistema appena installato non dovrebbero essere presenti pacchetti
Docker o containerd confliggenti. Controllarli senza rimuovere nulla:

```bash
dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' |
awk '
  $1 ~ /^(docker\.io|docker-compose|docker-compose-v2|docker-doc|docker-buildx|podman-docker|containerd|runc)(:[^[:space:]]+)?$/ &&
  $2 ~ /^ii/ { print }
'
```

L'output deve essere vuoto. Se vengono mostrati pacchetti confliggenti,
fermarsi e verificarli prima di proseguire. La guida non li rimuove
automaticamente.

Installare quindi certificati e client HTTP, poi il keyring e la definizione
del repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL \
  https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc
sudo apt-get update
```

La chiave deve essere intestata a `Docker Release (CE deb)` e mostrare la
fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`.

Controllare origine e disponibilità dei pacchetti:

```bash
apt-cache policy \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin
```

I candidati devono provenire da `download.docker.com`, suite Noble, canale
stable, architettura `amd64`. Se una versione esatta non è più disponibile,
fermarsi e registrare la differenza: le versioni correnti del repository non
sostituiscono automaticamente quelle validate.

Installare i pacchetti esatti:

```bash
sudo apt-get install -y \
  docker-ce=5:29.7.2-1~ubuntu.24.04~noble \
  docker-ce-cli=5:29.7.2-1~ubuntu.24.04~noble \
  containerd.io=2.3.4-1~ubuntu.24.04~noble \
  docker-buildx-plugin=0.36.1-1~ubuntu.24.04~noble
```

Il laboratorio usa il daemon Docker di sistema e `docker buildx imagetools`.
Docker Compose e la modalità rootless non fanno parte della baseline.
Controllare che Docker e containerd siano attivi:

```bash
systemctl is-active docker containerd
```

Entrambi i servizi devono risultare `active`. Versioni e configurazione del
daemon verranno controllate insieme al termine dell'installazione.

### 5.2 Accesso al daemon Docker

k3d deve raggiungere il daemon senza eseguire tutta la toolchain tramite
`sudo`. Aggiungere l'utente corrente al gruppo Docker:

```bash
sudo usermod -aG docker "$USER"
```

L'appartenenza al gruppo `docker` consente di avviare container privilegiati
e concede di fatto privilegi elevati sull'host. A questo punto effettuare
logout e login e **non proseguire nella vecchia shell**. Dopo il nuovo login,
tornare esplicitamente nella repository e verificare l'accesso:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
git status --short --branch
id -nG
docker info
```

`id -nG` deve includere `docker` e `docker info` deve rispondere senza `sudo`.
Se restituisce `permission denied`, chiudere completamente la sessione e
accedere nuovamente; non usare `sudo docker` come soluzione permanente.

Creare soltanto ora la directory temporanea usata per kubectl, Helm e k3d:

```bash
export TOOLCHAIN_DIR="$(mktemp -d)"
printf 'toolchain_dir=%s\n' "$TOOLCHAIN_DIR"
```

La directory appartiene a questa nuova sessione e non richiede di recuperare
variabili definite prima del logout.

### 5.3 kubectl

kubectl è il client usato per interrogare l'API server Kubernetes durante tutti
gli esperimenti. La versione `v1.34.9` usa la stessa minor di Kubernetes/K3s
del laboratorio. Scaricare il binario e verificarlo con il checksum validato:

```bash
KUBECTL_FILE="$TOOLCHAIN_DIR/kubectl-v1.34.9-linux-amd64"
KUBECTL_SHA256='73bb6f5063caadae1e73a39de018d8ad21755984bea35358484db817859e7634'

curl --fail --location --retry 3 \
  --output "$KUBECTL_FILE" \
  https://dl.k8s.io/release/v1.34.9/bin/linux/amd64/kubectl
printf '%s  %s\n' "$KUBECTL_SHA256" "$KUBECTL_FILE" | sha256sum --check -

sudo install -o root -g root -m 0755 \
  "$KUBECTL_FILE" /usr/local/bin/kubectl
kubectl version --client -o yaml
```

Il checksum deve risultare `OK` e la versione finale deve riportare `v1.34.9`.
Se la verifica SHA-256 fallisce, non installare il file.

### 5.4 Helm

Helm verrà usato per renderizzare e installare componenti come Calico e
Cilium. Scaricare l'archivio `v3.21.3`, verificarlo e installare il binario:

```bash
HELM_ARCHIVE="$TOOLCHAIN_DIR/helm-v3.21.3-linux-amd64.tar.gz"
HELM_EXTRACT_DIR="$TOOLCHAIN_DIR/helm-v3.21.3-extract"
HELM_ARCHIVE_SHA256='15e041a93a590dce8100f39385cd98c84a765c9e36aeeb9e2dc6ff9e4769e2e0'

curl --fail --location --retry 3 \
  --output "$HELM_ARCHIVE" \
  https://get.helm.sh/helm-v3.21.3-linux-amd64.tar.gz
printf '%s  %s\n' "$HELM_ARCHIVE_SHA256" "$HELM_ARCHIVE" | \
  sha256sum --check -
mkdir -p "$HELM_EXTRACT_DIR"
tar -xzf "$HELM_ARCHIVE" -C "$HELM_EXTRACT_DIR"
sudo install -o root -g root -m 0755 \
  "$HELM_EXTRACT_DIR/linux-amd64/helm" /usr/local/bin/helm
helm version --short
```

Il checksum dell'archivio deve risultare `OK` e Helm deve riportare
`v3.21.3+g1ad6e68`. Il binario validato ha SHA-256
`46870487d8cbd7f304b93dc38bb6d91e4813d5c9bfab061538f474d775006f42`.

### 5.5 k3d

k3d crea cluster K3s i cui nodi vengono eseguiti come container Docker,
permettendo di costruire una topologia multi-node sul singolo host. Il suo
default K3s incorporato non determina la versione degli esperimenti: ogni
comando di creazione usa esplicitamente l'immagine K3s bloccata.

```bash
K3D_FILE="$TOOLCHAIN_DIR/k3d-v5.9.0-linux-amd64"
K3D_SHA256='06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0'

curl --fail --location --retry 3 \
  --output "$K3D_FILE" \
  https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64
printf '%s  %s\n' "$K3D_SHA256" "$K3D_FILE" | sha256sum --check -

sudo install -o root -g root -m 0755 \
  "$K3D_FILE" /usr/local/bin/k3d
k3d version
```

Il checksum deve risultare `OK` e la versione deve indicare k3d `v5.9.0`. Il
default incorporato `v1.35.5-k3s1` non verrà usato.

### 5.6 Verifica finale della toolchain

Al termine delle installazioni, eseguire il controllo complessivo:

```bash
id -nG
docker --version
containerd --version
docker buildx version
docker info --format \
  'Server={{.ServerVersion}}; Driver={{.Driver}}; Cgroup={{.CgroupDriver}}; CgroupVersion={{.CgroupVersion}}'
kubectl version --client -o yaml
helm version --short
k3d version
stat -fc '%T %n' /sys/fs/cgroup
sysctl net.ipv4.ip_forward
ls -l /sys/kernel/btf/vmlinux
findmnt /sys/fs/bpf || true
```

Verificare che l'utente appartenga al gruppo `docker`, che il daemon risponda
senza `sudo`, che usi storage driver `overlayfs`, cgroup v2 e cgroup driver
`systemd`. Le CLI devono riportare le versioni bloccate e
`net.ipv4.ip_forward` deve valere `1`; in caso contrario non creare cluster.
BTF deve essere disponibile prima di E20. Il mount bpffs può essere verificato
nuovamente dentro i nodi dopo l'installazione di Cilium.

`TOOLCHAIN_DIR` serve soltanto durante la sezione 5. Dopo un esito positivo si
può eliminarla con il comando seguente; in caso di errore conservarla finché
non sono stati ispezionati file e checksum:

```bash
rm -rf -- "$TOOLCHAIN_DIR"
```

## 6. Versioni, immagini e artefatti bloccati

| Componente | Versione o riferimento |
|---|---|
| Docker della baseline consolidata | `29.7.2` |
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| kubectl | `v1.34.9` |
| Helm | `v3.21.3` |
| BusyBox | `1.38.0` |
| Calico | `v3.32.1` |
| Cilium | `1.19.6` |

Le versioni Docker associate alle evidence storiche erano `29.6.2` in
E01/E02, `29.7.1` in E10 e `29.7.2` in E20. La validation end-to-end al commit
`d392dfb9b54753eb7e998d9620e02b01dbc36a2a` ha usato `29.7.2` come baseline
consolidata per l'intera guida. Questo ne conferma l'operatività con la
baseline corrente, senza uniformare retroattivamente i runtime delle evidence
originali né ricreare la cronologia degli aggiornamenti intermedi.

### 6.1 Immagine K3s

Il tag scelto era `docker.io/rancher/k3s:v1.34.9-k3s1`. L'indice OCI
multiarch osservato aveva digest
`sha256:9c162556657a38e394d1f944081388ae7c0b85ec29134c509583083e287f804e`;
il manifest `linux/amd64` usato dai nodi era:

```text
sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d
```

Scaricare il manifest `linux/amd64` effettivamente usato dai nodi:

```bash
docker pull --platform linux/amd64 \
  docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d
```

L'ispezione dettagliata dell'indice OCI è facoltativa e non serve per
proseguire:

```bash
docker buildx imagetools inspect \
  docker.io/rancher/k3s:v1.34.9-k3s1
docker image inspect \
  --format 'RepoDigests={{json .RepoDigests}}; OS={{.Os}}; Architecture={{.Architecture}}; Size={{.Size}}' \
  docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d
```

La selezione del manifest `amd64` rende esplicita l'architettura della
piattaforma validata anziché affidarsi alla risoluzione automatica
dell'indice multiarch.

### 6.2 Immagine BusyBox

Il workload usa il tag logico `docker.io/library/busybox:1.38.0`. L'indice
OCI osservato aveva digest
`sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d`;
il manifest `linux/amd64` presente in `workload.yaml` è:

```text
sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8
```

```bash
docker pull --platform linux/amd64 \
  docker.io/library/busybox@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8
```

Anche per BusyBox l'ispezione OCI dettagliata è facoltativa:

```bash
docker buildx imagetools inspect docker.io/library/busybox:1.38.0
docker image inspect \
  --format 'RepoDigests={{json .RepoDigests}}; OS={{.Os}}; Architecture={{.Architecture}}; Size={{.Size}}' \
  docker.io/library/busybox@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8
```

BusyBox fornisce `sh`, `sleep`, `httpd`, `ping`, `wget` e `nslookup`, cioè
gli strumenti minimi del workload. Il manifest comune conserva il digest e
non richiede di riscriverlo durante gli esperimenti.

## 7. Convenzioni e variabili comuni

All'inizio di una nuova shell, oppure prima di iniziare direttamente E01,
E02, E10 o E20, entrare nella root della repository e caricare l'ambiente
comune in una shell Bash:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
```

`lab-env.sh` raccoglie l'immagine K3s bloccata, le variabili e le utility comuni
del laboratorio. Non crea cluster e può essere caricato nuovamente. Gli helper
per Service, catture e NetworkPolicy vengono caricati soltanto negli
esperimenti che li usano.

Ogni esperimento assegna `TESI_CONTEXT` al contesto kubectl del proprio cluster
e `TESI_NODE_PREFIX` al prefisso dei container nodo. IP, PID, veth e altri
identificativi effimeri vengono sempre rilevati dal cluster corrente, mai
copiati dalle evidence storiche.

I cluster del laboratorio usano nomi con prefisso `tesi-` e una porta API
loopback distinta. Nome e porta concreti restano visibili in ogni comando di
creazione.

Prima di creare un cluster, ogni esperimento invoca:

```text
check_experiment_preflight NOME_CLUSTER PORTA_API
```

I valori concreti sono riportati nei punti di ingresso. Il preflight verifica
che nome cluster e porta API siano liberi e che non restino catture precedenti;
non elimina risorse. Se fallisce, risolvere il conflitto prima di proseguire.

### 7.1 Workload e flussi comuni

Il workload colloca `client` e `server-a` su `agent-0`, e `server-b` su
`agent-1`. Ogni esperimento imposta `TESI_CONTEXT` e `TESI_NODE_PREFIX`, poi
invoca:

```bash
deploy_common_workload
```

Il manifest forza `client` e `server-a` su `agent-0` e `server-b` su `agent-1`:
questa disposizione permette di confrontare flussi intra-node e inter-node.
La label comune è `cni-network-baseline`; le evidence storiche possono mostrare
il precedente valore `e01-network-baseline`, che non partecipa ai selector
delle policy.

`http_flow` genera una nuova richiesta HTTP diretta fra due Pod e controlla la
risposta. Per i Service, `verify_service_backends` verifica che entrambi i
backend siano Ready e `service_http_flows N` registra quale backend risponde a
ciascuna delle `N` nuove connessioni, senza imporre una distribuzione.

Gli esperimenti NetworkPolicy attendono la convergenza del data plane prima di
eseguire una sola matrice di traffico nello stato corrente:

```text
run_policy_matrix MODALITA
```

Le modalità `allow-all`, `deny-all` e `selective-allow` sono alternative e
corrispondono rispettivamente a 6/6 connessioni consentite, 6/6 negate e 4/6
consentite. Ogni matrice prova due volte `client → server-a`,
`client → server-b` e `server-a → server-b`. Gli helper di convergenza e
osservazione non generano traffico workload.

## 8. E01 — Flannel VXLAN

E01 mostra come Flannel collega i Pod di un cluster K3s multi-node. Prima
osserveremo la configurazione predisposta sui nodi; poi confronteremo un flusso
locale con uno diretto a un Pod remoto e correleremo il secondo al tunnel
VXLAN. La cattura deve mostrare il pacchetto interno fra Pod e quello esterno
fra gli indirizzi underlay dei nodi, su UDP 8472 e VNI 1.

### 8.1 Obiettivo e creazione del cluster

Creiamo la baseline K3s con Flannel VXLAN, un server e due agent. La porta
API è esposta soltanto su loopback. Questo è il punto di ingresso E01 anche in
una nuova shell. `service.sh` fornisce le prove sui Service; `capture.sh`
fornisce il mapping Pod–veth e l'orchestrazione della cattura controllata.

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
source scripts/cni/common/service.sh
source scripts/cni/common/capture.sh
check_experiment_preflight tesi-flannel-vxlan 6445
```

```bash
k3d cluster create tesi-flannel-vxlan \
  --servers 1 \
  --agents 2 \
  --image "$TESI_K3S_IMAGE" \
  --api-port '127.0.0.1:6445' \
  --k3s-arg '--disable=traefik@server:*' \
  --wait
```

Il comando crea tre nodi K3s come container Docker. Attendere che Kubernetes li
dichiari Ready, quindi osservare nodi, Pod di sistema e PodCIDR assegnati:

```bash
export TESI_CONTEXT='k3d-tesi-flannel-vxlan'
export TESI_NODE_PREFIX='k3d-tesi-flannel-vxlan'

kubectl --context "$TESI_CONTEXT" cluster-info
k3d cluster list
docker ps --filter 'name=k3d-tesi-flannel-vxlan' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=120s
kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get nodes \
  -o custom-columns=NAME:.metadata.name,POD_CIDR:.spec.podCIDR
```

L'output deve mostrare un server e due agent Ready. Ogni nodo riceve un
PodCIDR distinto: questa subnet identifica gli indirizzi Pod locali al nodo.

### 8.2 Networking Flannel sui nodi

Prima del workload distinguiamo i componenti del data plane. `cni0` è il bridge
locale al quale vengono collegati i Pod del nodo; `flannel.1` è l'interfaccia
VXLAN usata per raggiungere i PodCIDR remoti. `10-flannel.conflist` descrive la
catena CNI, mentre `subnet.env` registra la subnet assegnata al nodo e i
parametri Flannel.

```bash
for node in \
  k3d-tesi-flannel-vxlan-server-0 \
  k3d-tesi-flannel-vxlan-agent-0 \
  k3d-tesi-flannel-vxlan-agent-1
do
  docker exec "$node" sh -c \
    'hostname; ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d /run/flannel'
  docker exec "$node" sh -c \
    'hostname; sed -n "1,240p" /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist; sed -n "1,120p" /run/flannel/subnet.env'
  docker exec "$node" ip -details address
  docker exec "$node" ip -details link show flannel.1
  docker exec "$node" sh -c \
    'hostname; ip route; ip neigh show dev flannel.1'
done

kubectl --context "$TESI_CONTEXT" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" | backend="}{.metadata.annotations.flannel\.alpha\.coreos\.com/backend-type}{" | backend-data="}{.metadata.annotations.flannel\.alpha\.coreos\.com/backend-data}{" | public-ip="}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{" | podCIDR="}{.spec.podCIDR}{"\n"}{end}'
```

Per ogni nodo controllare `cni0`, `flannel.1` e la subnet riportata da
`subnet.env`. `ip route` mostra quale percorso sceglie il kernel per un PodCIDR
remoto; la route deve usare `flannel.1`. Le annotazioni Kubernetes devono
indicare il backend `vxlan` e gli indirizzi pubblici correnti dei nodi. Questa
configurazione descrive il tunnel predisposto, ma non dimostra ancora che uno
specifico flusso lo attraversi.

### 8.3 Workload e connettività

`deploy_common_workload` applica il manifest comune e attende che i Pod siano
Ready. Prima dei test individuiamo placement e IP: `client` e `server-a` devono
trovarsi su `agent-0`, mentre `server-b` deve trovarsi su `agent-1`.

```bash
deploy_common_workload
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide

CLIENT_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod client -o jsonpath='{.status.podIP}')"
SERVER_A_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-a -o jsonpath='{.status.podIP}')"
SERVER_B_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-b -o jsonpath='{.status.podIP}')"
SERVICE_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get svc servers -o jsonpath='{.spec.clusterIP}')"

printf 'client=%s server-a=%s server-b=%s service=%s\n' \
  "$CLIENT_IP" "$SERVER_A_IP" "$SERVER_B_IP" "$SERVICE_IP"
```

Le quattro variabili devono mostrare indirizzi IPv4 non vuoti prima di
proseguire.

Il flusso `client → server-a` resta sullo stesso nodo; `client → server-b` deve
raggiungere un PodCIDR remoto. Verificare ICMP verso il Pod locale e HTTP in
entrambi i casi:

```bash
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- sh -c \
  'ping -c 3 -W 2 "$1"; rc=$?; printf "exit_code=%s\n" "$rc"; exit "$rc"' \
  sh "$SERVER_A_IP"
http_flow client server-a
http_flow client server-b
```

I due test HTTP devono restituire il nome del Pod destinazione. Il loro
successo dimostra connettività intra-node e inter-node, ma la cattura successiva
serve per attribuire il secondo percorso a VXLAN.

Verificare prima che entrambi i backend siano Ready, poi generare connessioni
nuove. Le risposte registrano soltanto i backend effettivamente scelti; non è
richiesto che un numero finito di connessioni li selezioni entrambi. L'esito
prova il ClusterIP nei flussi osservati, ma non isola causalmente kube-proxy:

```bash
verify_service_backends
service_http_flows 6
```

Usare il nome assoluto, con il punto finale, per evitare che un search suffix
dell'host alteri la risoluzione:

```bash
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  nslookup servers.net-lab.svc.cluster.local.
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  wget -qO- -T 5 http://servers.net-lab.svc.cluster.local.:8080/
```

Il test conferma risoluzione DNS e raggiungibilità del Service nel caso
provato; non costituisce un'analisi generale del DNS del cluster.

### 8.4 Identificativi runtime, veth e cattura inter-node

Ogni Pod ha un'interfaccia `eth0` collegata tramite una coppia veth al nodo.
`map_pod_veth` individua la sandbox corrente del Pod e associa `eth0` alla
corrispondente veth nel namespace del nodo. Questa associazione permette di
riconoscere quali porte di `cni0` appartengono ai tre Pod.

```bash
map_pod_veth client k3d-tesi-flannel-vxlan-agent-0
map_pod_veth server-a k3d-tesi-flannel-vxlan-agent-0
map_pod_veth server-b k3d-tesi-flannel-vxlan-agent-1
```

Per ogni Pod l'output deve mostrare il Pod IP corrente su `eth0` e una sola veth
corrispondente sul nodo.

Per osservare il flusso inter-node leggiamo dinamicamente il PID del nodo
sorgente e gli indirizzi underlay Docker dei due agent:

```bash
export SOURCE_NODE='k3d-tesi-flannel-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-flannel-vxlan-agent-1'
SOURCE_PID="$(docker inspect -f '{{.State.Pid}}' "$SOURCE_NODE")"
SOURCE_UNDERLAY="$(docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-flannel-vxlan"}}{{.IPAddress}}{{end}}' \
  "$SOURCE_NODE")"
DESTINATION_UNDERLAY="$(docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-flannel-vxlan"}}{{.IPAddress}}{{end}}' \
  "$DESTINATION_NODE")"
CAPTURE_DIR="$(mktemp -d)"

printf 'pid=%s source_underlay=%s destination_underlay=%s capture_dir=%s\n' \
  "$SOURCE_PID" "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" "$CAPTURE_DIR"

sudo /usr/bin/nsenter --target "$SOURCE_PID" --net \
  /usr/sbin/bridge -d link show master cni0
sudo /usr/bin/nsenter --target "$SOURCE_PID" --net /usr/sbin/ip -br link
```

Il PID deve essere un intero positivo e gli underlay devono essere due
indirizzi IPv4 correnti distinti.

La lista del bridge deve mostrare come porte di `cni0` le veth di `client` e
`server-a` appena ricostruite.

La cattura entra nel network namespace del nodo sorgente, dove esistono
`cni0`, `flannel.1`, le veth e l'interfaccia underlay `eth0`. Con `-i any`
osserviamo nello stesso intervallo due viste dello stesso flusso:

- la vista interna, con IP Pod sorgente e destinazione e TCP/8080;
- la vista esterna, incapsulata fra gli IP underlay con UDP/8472.

`run_dual_view_capture` avvia il comando `tcpdump` mostrato di seguito, genera
un solo GET `client → server-b` e conserva separatamente cattura e risposta
HTTP. Il filtro e i punti osservati restano scelti esplicitamente dalla guida:

```bash
sudo -v
TCPDUMP_FILTER="((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 8472))"
run_dual_view_capture \
  E01 \
  "$CAPTURE_DIR/flannel-inter-node.log" \
  "$CAPTURE_DIR/http-client.log" \
  client server-b \
  "$CLIENT_IP" "$SERVER_B_IP" \
  "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 8472 \
  -- sudo /usr/bin/env LC_ALL=C \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/timeout --verbose --foreground --preserve-status \
    --signal=TERM --kill-after=2s 8s \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "$TCPDUMP_FILTER"
```

Se l'helper termina con errore, non proseguire. In caso di successo, leggere i
due output:

```bash
sed -n '1,260p' "$CAPTURE_DIR/flannel-inter-node.log"
cat "$CAPTURE_DIR/http-client.log"
```

La cattura deve mostrare il GET con gli IP dei Pod e i datagrammi VXLAN fra gli
IP underlay. La porta UDP di destinazione deve essere 8472 e il VNI deve essere
1. L'output HTTP separato conferma che il flusso catturato ha raggiunto
`server-b`.

`CAPTURE_DIR` conserva i due output per l'ispezione. Dopo un esito positivo può
essere eliminata con `rm -rf -- "$CAPTURE_DIR"`; in caso di errore conservarla
temporaneamente per la diagnosi.

### 8.5 Rimozione del cluster

Eliminare soltanto il cluster E01 e controllare che non resti il listener API
sulla porta 6445:

```bash
k3d cluster delete tesi-flannel-vxlan
k3d cluster list
ss -ltn 'sport = :6445'
```

## 9. E02 — attribuzione delle NetworkPolicy nello stack K3s

In E01 abbiamo osservato come Flannel configura e trasporta il traffico Pod.
E02 separa una funzione diversa: l'enforcement delle NetworkPolicy. Il
confronto non usa due CNI differenti, ma due cluster con lo stesso networking
Flannel:

- nel caso ON il controller NetworkPolicy integrato in K3s è attivo;
- nel caso OFF lo stesso componente è disabilitato con
  `--disable-network-policy`.

Se gli stessi oggetti NetworkPolicy modificano il traffico soltanto nel caso
ON e producono lì le relative strutture kernel, possiamo attribuire
l'enforcement al controller K3s anziché a Flannel. I due cluster vanno eseguiti
in sequenza per evitare ambiguità.

Questo è il punto di ingresso E02 anche in una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
source scripts/cni/k3s/e02-policy.sh
```

`e02-policy.sh` fornisce il gate di convergenza e gli observer specifici del
policy plane K3s. La matrice autoritativa comprende due nuove connessioni per
ognuno dei flussi `client → server-a`, `client → server-b` e
`server-a → server-b`, per un totale di sei richieste per stato.

La presenza dell'oggetto NetworkPolicy nell'API non basta a dimostrare
l'enforcement. `inspect_k3s_policy_plane` mantiene osservabili, su ciascun
nodo, log del controller, iptables e IPSet attraverso questi comandi:

```text
docker logs "$NODE"
docker exec "$NODE" /bin/aux/iptables --version
docker exec "$NODE" /bin/ipset --version
docker exec "$NODE" /bin/aux/iptables-save -c
docker exec "$NODE" /bin/ipset save
```

I log identificano il controller basato su kube-router. Le chain
`KUBE-NWPLCY-*` rappresentano regole derivate dalle policy; le chain
`KUBE-POD-FW-*` collegano tali regole ai Pod interessati. Gli IPSet con
prefisso `KUBE-` materializzano indirizzi e selector usati dalle regole:

```text
NetworkPolicy API
        ↓
controller K3s
        ↓
chain iptables e IPSet
        ↓
traffico consentito o bloccato
```

Dopo ogni modifica nel caso ON,
`wait_for_k3s_policy_convergence STATO` attende che chain e collegamenti
corrispondano allo stato richiesto. Il gate legge soltanto il data plane, non
genera traffico workload e non sostituisce la matrice autoritativa, che viene
eseguita una sola volta dopo la convergenza.

I blocchi di ogni stato sono sequenziali: eseguire il successivo soltanto se il
precedente termina correttamente. In particolare, non avviare mai una matrice
se la mutazione API o il gate che la precede falliscono.

### 9.1 Controller ON

Il primo cluster usa la configurazione K3s standard: Flannel e controller
NetworkPolicy sono entrambi attivi.

```bash
check_experiment_preflight tesi-e02-flannel-netpol-on 6446
k3d cluster create tesi-e02-flannel-netpol-on \
  --servers 1 --agents 2 \
  --image "$TESI_K3S_IMAGE" \
  --api-port '127.0.0.1:6446' \
  --k3s-arg '--disable=traefik@server:*' \
  --wait

export TESI_CONTEXT='k3d-tesi-e02-flannel-netpol-on'
export TESI_NODE_PREFIX='k3d-tesi-e02-flannel-netpol-on'
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=120s
```

#### Baseline — 6/6 consentite

Applicare il workload e controllare il placement. Senza NetworkPolicy, tutte le
sei connessioni della matrice devono riuscire:

```bash
deploy_common_workload
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
```

Quando i tre Pod sono Ready e collocati sui nodi previsti, eseguire la singola
matrice baseline e osservare il policy plane:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

Questa matrice `6/6` è la baseline autoritativa prima dell'introduzione delle
policy.

#### Default deny — 0/6 consentite

Applicare la policy, mostrarne l'oggetto API, attendere la traduzione nel data
plane e soltanto dopo generare la matrice:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml
kubectl --context "$TESI_CONTEXT" get networkpolicy \
  default-deny-ingress -n net-lab -o yaml
```

La presenza nell'API è soltanto il primo passaggio. Attendere ora la
convergenza delle chain:

```bash
wait_for_k3s_policy_convergence default-deny
```

Soltanto dopo il PASS del gate, eseguire la matrice autoritativa e acquisire gli
observer:

```bash
run_policy_matrix deny-all
inspect_k3s_policy_plane
```

Le sei connessioni devono essere negate, mentre i Pod restano Ready. Le chain
`KUBE-NWPLCY-*`, il linkage da `KUBE-POD-FW-*` e gli IPSet devono mostrare la
traduzione concreta del default deny.

#### Selective allow — 4/6 consentite

Applicare l'allow mirata senza rimuovere il default deny, attendere nuovamente
la convergenza ed eseguire una sola matrice:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml
```

Attendere che il data plane rappresenti entrambe le policy:

```bash
wait_for_k3s_policy_convergence selective-allow
```

Soltanto dopo il PASS del gate, eseguire la matrice e gli observer:

```bash
run_policy_matrix selective-allow
inspect_k3s_policy_plane
```

Devono riuscire quattro richieste dal client e fallire le due da `server-a`.
Chain, linkage e IPSet devono essere coerenti con entrambe le policy presenti.

#### Restore — 6/6 consentite

Rimuovere entrambe le policy, attendere la scomparsa dei relativi collegamenti
dal data plane e verificare il ritorno alla baseline:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
```

Attendere la rimozione delle strutture policy-specifiche:

```bash
wait_for_k3s_policy_convergence restored
```

Soltanto dopo il PASS del gate, verificare il ritorno alla baseline:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

Il controllo ON è completo soltanto se anche il restore torna a `6/6`.
Eliminare quindi esclusivamente il cluster ON:

```bash
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
k3d cluster delete tesi-e02-flannel-netpol-on
```

### 9.2 Controller OFF

Il secondo cluster conserva Flannel e la stessa topologia, ma disabilita il
controller con `--disable-network-policy`. Questa è l'unica differenza causale
pertinente rispetto al caso ON.

```bash
check_experiment_preflight tesi-e02-flannel-netpol-off 6447
k3d cluster create tesi-e02-flannel-netpol-off \
  --servers 1 --agents 2 \
  --image "$TESI_K3S_IMAGE" \
  --api-port '127.0.0.1:6447' \
  --k3s-arg '--disable=traefik@server:*' \
  --k3s-arg '--disable-network-policy@server:*' \
  --wait

export TESI_CONTEXT='k3d-tesi-e02-flannel-netpol-off'
export TESI_NODE_PREFIX='k3d-tesi-e02-flannel-netpol-off'
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=120s
```

#### Baseline — 6/6 consentite

Applicare lo stesso workload. Prima delle policy, la matrice deve nuovamente
consentire tutte le connessioni:

```bash
deploy_common_workload
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
```

Quando i Pod sono Ready, eseguire la matrice baseline e gli observer:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

#### Default deny presente nell'API — ancora 6/6

Applicare lo stesso default deny del caso ON e verificare che l'API Kubernetes
lo conservi. Poiché il controller è disabilitato, non si attende la creazione
di chain di enforcement e la matrice resta `allow-all`:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml
kubectl --context "$TESI_CONTEXT" get networkpolicy \
  default-deny-ingress -n net-lab -o yaml
```

Solo dopo avere osservato l'oggetto nell'API, eseguire la singola matrice e
controllare l'assenza delle strutture di enforcement:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

#### Selective allow presente nell'API — ancora 6/6

Applicare anche l'allow mirata. Entrambi gli oggetti devono essere visibili
nell'API, ma il traffico deve continuare a essere consentito:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml
```

Con entrambi gli oggetti visibili nell'API, eseguire una sola matrice e gli
observer:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

Nei primi tre stati OFF tutte le 18 connessioni devono riuscire. I log dei tre
nodi non devono mostrare l'avvio del controller e non devono comparire le
strutture policy-specifiche osservate nel caso ON. Kubernetes ha accettato gli
oggetti NetworkPolicy, ma manca il componente che li traduce nel data plane.

Per rendere confrontabili gli snapshot dei tre stati, salvare integralmente
gli output dei comandi mostrati e documentare qualunque normalizzazione dei
campi effimeri prima di usare un confronto byte per byte.

#### Restore — ancora 6/6

Rimuovere le policy e verificare un'ultima volta la baseline. Nel caso OFF non
invochiamo il gate del caso ON, perché le strutture che esso attende devono
restare assenti; la matrice viene comunque eseguita una sola volta:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
```

Dopo la rimozione API, eseguire la matrice finale e gli observer:

```bash
run_policy_matrix allow-all
inspect_k3s_policy_plane
```

Eliminare esclusivamente il cluster OFF e controllare che entrambi i cluster
E02 e i relativi listener non siano più presenti:

```bash
k3d cluster delete tesi-e02-flannel-netpol-off
k3d cluster list
ss -ltn 'sport = :6446 or sport = :6447'
```

### 9.3 Sintesi causale

```text
Controller ON:
NetworkPolicy API
→ chain iptables/IPSet
→ traffico 6/6 → 0/6 → 4/6 → 6/6

Controller OFF:
NetworkPolicy API presente
→ strutture di enforcement assenti
→ traffico 6/6 → 6/6 → 6/6 → 6/6
```

Il confronto controllato mostra quindi che, nella configurazione K3s studiata,
Flannel continua a fornire la rete Pod in entrambi i cluster, mentre
l'enforcement delle NetworkPolicy dipende dal controller K3s basato su
kube-router e dalle strutture iptables/IPSet che esso crea.

## 10. E10 — Calico VXLAN con data plane Linux

E10 sostituisce Flannel con Calico 3.32.1 nel profilo VXLAN con data plane
Linux iptables. Osserveremo separatamente networking Pod, forwarding dei
Service e NetworkPolicy: `cali*` collega i workload al nodo,
`vxlan.calico` trasporta il traffico inter-node, kube-proxy gestisce i Service
studiati e Felix traduce lo stato Calico e le policy nel data plane del nodo.

Questo è il punto di ingresso E10 anche in una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
source scripts/cni/calico/e10-policy.sh
source scripts/cni/common/service.sh
source scripts/cni/common/capture.sh
source scripts/cni/calico/e10-service.sh
```

### 10.1 Download e verifica dei chart

I due chart usati erano:

```text
0fa7fa4fc7df7942f6a2472d7ac52a26929b6864c9f3563034e2284c6fcce6f0  crd.projectcalico.org.v1-v3.32.1.tgz
563f75f29bdbb13dde13a1d51244b96f42b4fe0eef5be763fb55fa9756f31c93  tigera-operator-v3.32.1.tgz
```

Per Calico 3.32.1 vengono utilizzati i chart ufficiali
`tigera-operator-v3.32.1.tgz` e
`crd.projectcalico.org.v1-v3.32.1.tgz`. La
[release upstream `v3.32.1`](https://github.com/projectcalico/calico/releases/tag/v3.32.1)
pubblica entrambi gli artefatti e la
[documentazione ufficiale Helm di Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm)
definisce il repository `projectcalico`. I chart vengono scaricati localmente
con `helm pull` e verificati tramite i checksum SHA-256 riportati di seguito:

```bash
export CALICO_CHART_DIR="$(mktemp -d)"
helm repo add projectcalico https://docs.tigera.io/calico/charts
helm repo update projectcalico
helm pull projectcalico/crd.projectcalico.org.v1 \
  --version v3.32.1 \
  --destination "$CALICO_CHART_DIR"
helm pull projectcalico/tigera-operator \
  --version v3.32.1 \
  --destination "$CALICO_CHART_DIR"

export CALICO_CRD_CHART="$CALICO_CHART_DIR/crd.projectcalico.org.v1-v3.32.1.tgz"
export CALICO_OPERATOR_CHART="$CALICO_CHART_DIR/tigera-operator-v3.32.1.tgz"

printf '%s  %s\n' \
  '0fa7fa4fc7df7942f6a2472d7ac52a26929b6864c9f3563034e2284c6fcce6f0' \
  "$CALICO_CRD_CHART" | sha256sum --check -
printf '%s  %s\n' \
  '563f75f29bdbb13dde13a1d51244b96f42b4fe0eef5be763fb55fa9756f31c93' \
  "$CALICO_OPERATOR_CHART" | sha256sum --check -
helm lint "$CALICO_CRD_CHART"
helm lint "$CALICO_OPERATOR_CHART"
bash -n scripts/cni/calico/pin-tigera-operator-image.sh
```

Gli hash devono coincidere esattamente con i checksum attesi. In caso contrario
non installare i chart: una nuova pubblicazione con la stessa versione non può
essere assunta equivalente.

Prima di creare il cluster renderizziamo separatamente CRD e Tigera Operator.
Il secondo comando usa i values pubblici, esclude gli hook e applica il
post-renderer che sostituisce l'immagine tagged dell'operator con il digest
`linux/amd64` bloccato:

```bash
export CALICO_RENDER_DIR="$(mktemp -d)"
export CALICO_OPERATOR_RENDERED="$CALICO_RENDER_DIR/tigera-operator-rendered.yaml"

helm template calico-crds "$CALICO_CRD_CHART" \
  --output-dir "$CALICO_RENDER_DIR"

helm template calico "$CALICO_OPERATOR_CHART" \
  --namespace tigera-operator \
  --values manifests/cni/calico/tigera-operator-values.yaml \
  --no-hooks \
  --post-renderer scripts/cni/calico/pin-tigera-operator-image.sh \
  >"$CALICO_OPERATOR_RENDERED"
```

Elencare i manifest CRD prodotti e le parti principali del rendering operator:

```bash
find "$CALICO_RENDER_DIR" -maxdepth 6 -type f -print
grep -nE '^kind:|^[[:space:]]+name:|^[[:space:]]+image:' \
  "$CALICO_OPERATOR_RENDERED"
grep -nF \
  'quay.io/tigera/operator@sha256:9ca16aacd5676df68535e08e77529f6c1988ffecbff451e0ff5777e1b126dd91' \
  "$CALICO_OPERATOR_RENDERED"
```

Il Deployment operator deve mostrare esattamente il digest bloccato. I
controlli seguenti sono ispezioni negative: l'output deve restare vuoto.

```bash
grep -nE 'quay\.io/tigera/operator:v1\.42\.3|image:.*:latest' \
  "$CALICO_OPERATOR_RENDERED" || true
grep -niE '^[[:space:]]+name:[[:space:]]+.*(goldmane|whisker)' \
  "$CALICO_OPERATOR_RENDERED" || true
```

Non procedere se ricompaiono l'immagine tagged, un tag `latest` oppure workload
Goldmane o Whisker.

### 10.2 Creazione del cluster e installazione

```bash
check_experiment_preflight tesi-e10-calico-vxlan 6448
k3d cluster create tesi-e10-calico-vxlan \
  --image "$TESI_K3S_IMAGE" \
  --servers 1 --agents 2 \
  --api-port 127.0.0.1:6448 \
  --k3s-arg '--disable=traefik@server:*' \
  --k3s-arg '--flannel-backend=none@server:*' \
  --k3s-arg '--disable-network-policy@server:*' \
  --k3s-arg '--cluster-cidr=10.42.0.0/16@server:*' \
  --k3s-arg '--service-cidr=10.43.0.0/16@server:*' \
  --wait --timeout 180s

export TESI_CONTEXT='k3d-tesi-e10-calico-vxlan'
export TESI_NODE_PREFIX='k3d-tesi-e10-calico-vxlan'
```

I quattro file e opzioni hanno ruoli distinti:

- `tigera-operator-values.yaml` impedisce l'installazione automatica della
  configurazione predefinita, abilita l'API server ed esclude Goldmane e
  Whisker;
- il post-renderer fissa al digest scelto l'immagine del Tigera Operator;
- `imageset.yaml` associa le immagini Calico 3.32.1 ai digest controllati;
- `installation.yaml` descrive Calico CNI/IPAM, VXLAN, blocchi `/26`, BGP
  disabilitato, data plane Linux iptables e kube-proxy mantenuto.

`--no-hooks` evita di installare hook del chart estranei a questa sequenza
esplicita. L'ordine è CRD, operator, ImageSet e infine Installation: le CRD
devono esistere prima delle risorse personalizzate e l'ImageSet deve essere
disponibile quando l'operator costruisce i workload Calico.

```bash
helm install calico-crds "$CALICO_CRD_CHART" \
  --kube-context "$TESI_CONTEXT" \
  --namespace tigera-operator --create-namespace

helm install tigera-operator "$CALICO_OPERATOR_CHART" \
  --kube-context "$TESI_CONTEXT" \
  --namespace tigera-operator \
  --values manifests/cni/calico/tigera-operator-values.yaml \
  --no-hooks \
  --post-renderer scripts/cni/calico/pin-tigera-operator-image.sh

kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/calico/imageset.yaml
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/calico/installation.yaml
```

La sequenza applica direttamente la configurazione finale consolidata ed è
stata eseguita nella validation end-to-end al commit
`d392dfb9b54753eb7e998d9620e02b01dbc36a2a`. Se non converge in una replica,
fermarsi e conservare lo stato per la diagnosi.

### 10.3 Verifica di Calico, CNI e IPAM

Prima di generare traffico aspettiamo che Calico abbia completato la
convergenza. I nodi devono essere Ready e i quattro `TigeraStatus` necessari
devono esistere, risultare `Available=True` e `Degraded=False`.

```bash
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=600s

for status in apiserver calico ippools tiers
do
  kubectl --context "$TESI_CONTEXT" wait \
    --for=create "tigerastatus/$status" --timeout=300s
  kubectl --context "$TESI_CONTEXT" wait \
    --for=condition=Available=True "tigerastatus/$status" --timeout=300s
  kubectl --context "$TESI_CONTEXT" wait \
    --for=condition=Degraded=False "tigerastatus/$status" --timeout=300s
done
```

Se una condizione non viene raggiunta entro il timeout, non proseguire. Dopo il
completamento dei wait, ispezionare componenti, configurazione e risorse IPAM:

```bash
kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get tigerastatus
kubectl --context "$TESI_CONTEXT" get \
  installation.operator.tigera.io default -o yaml
kubectl --context "$TESI_CONTEXT" get imageset.operator.tigera.io -o yaml
kubectl --context "$TESI_CONTEXT" get apiserver.operator.tigera.io -o yaml
kubectl --context "$TESI_CONTEXT" api-resources | \
  grep -E 'projectcalico|tigera'
kubectl --context "$TESI_CONTEXT" get \
  ippools.crd.projectcalico.org -o yaml
kubectl --context "$TESI_CONTEXT" get \
  blockaffinities.crd.projectcalico.org -o yaml
kubectl --context "$TESI_CONTEXT" get \
  ipamblocks.crd.projectcalico.org -o yaml
```

Tutti i `TigeraStatus` devono essere disponibili e non degraded. Verificare
IPPool `10.42.0.0/16`, blocchi `/26`, VXLAN sempre attivo, BGP disabilitato e
immagini per digest.

Nel profilo E10 Calico sostituisce il networking Flannel. Invece di `cni0` e
`flannel.1`, i workload sono collegati tramite interfacce host-side `cali*` e
il traffico inter-node usa `vxlan.calico`. Ispezionare direttamente i tre
namespace nodo:

```text
Pod → cali* → route del nodo → vxlan.calico → nodo remoto → cali* → Pod
```

```bash
for node in \
  k3d-tesi-e10-calico-vxlan-server-0 \
  k3d-tesi-e10-calico-vxlan-agent-0 \
  k3d-tesi-e10-calico-vxlan-agent-1
do
  docker exec "$node" ip -br link
  docker exec "$node" ip route
  docker exec "$node" ip -details link show vxlan.calico
  docker exec "$node" sh -c \
    'ls -la /etc/cni/net.d && sed -n "1,240p" /etc/cni/net.d/10-calico.conflist'
done

docker exec k3d-tesi-e10-calico-vxlan-agent-0 \
  test ! -e /sys/class/net/cni0
```

L'ultimo comando deve terminare senza output: conferma che `cni0` non esiste.
Le interfacce dei Pod sono `cali*`; `vxlan.calico` deve riportare VNI 4096 e
usa UDP 4789 nel profilo studiato.

### 10.4 Workload, percorso e cattura

Applicare il workload comune e controllare il placement. `client` e
`server-a` devono trovarsi su `agent-0`, mentre `server-b` deve trovarsi su
`agent-1`:

```bash
deploy_common_workload
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
```

La prima matrice verifica la connettività del workload prima degli esperimenti
Service e NetworkPolicy:

```bash
run_policy_matrix allow-all
```

Rilevare gli indirizzi correnti e osservare link e route sui due agent:

```bash
CLIENT_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod client -o jsonpath='{.status.podIP}')"
SERVER_A_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-a -o jsonpath='{.status.podIP}')"
SERVER_B_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-b -o jsonpath='{.status.podIP}')"
SERVICE_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get svc servers -o jsonpath='{.spec.clusterIP}')"

printf 'client=%s server-a=%s server-b=%s service=%s\n' \
  "$CLIENT_IP" "$SERVER_A_IP" "$SERVER_B_IP" "$SERVICE_IP"

docker exec k3d-tesi-e10-calico-vxlan-agent-0 ip -br link
docker exec k3d-tesi-e10-calico-vxlan-agent-0 ip route
docker exec k3d-tesi-e10-calico-vxlan-agent-1 ip -br link
docker exec k3d-tesi-e10-calico-vxlan-agent-1 ip route
```

Le quattro variabili devono mostrare indirizzi IPv4 non vuoti. Per collegare
ciascun Pod all'interfaccia host-side, chiedere al kernel quale route usa verso
il Pod locale:

```bash
docker exec k3d-tesi-e10-calico-vxlan-agent-0 \
  ip -o route get "$CLIENT_IP"
docker exec k3d-tesi-e10-calico-vxlan-agent-0 \
  ip -o route get "$SERVER_A_IP"
docker exec k3d-tesi-e10-calico-vxlan-agent-1 \
  ip -o route get "$SERVER_B_IP"

docker exec k3d-tesi-e10-calico-vxlan-agent-0 \
  ip -o route get "$SERVER_B_IP"
```

Le prime tre route devono selezionare un'interfaccia `cali*`: è la veth
host-side associata al workload locale. L'ultima query parte da `agent-0` verso
il Pod remoto su `agent-1` e mostra il percorso inter-node attraverso la route
Calico e `vxlan.calico`.

Nel Kubernetes API datastore usato da E10, WorkloadEndpoint resta il modello
logico Calico dell'endpoint, ma non è esposta una CRD WorkloadEndpoint
interrogabile con `kubectl`. La correlazione osservabile usa quindi Pod IP,
nodo, route `cali*`, IPAMBlock e BlockAffinity. Il percorso intra-node è routing
L3 fra veth, senza bridge.

Per la cattura inter-node, rileggere PID e underlay e usare un GET singolo.
Come in E01, entriamo nel namespace del nodo sorgente perché contiene
`cali*`, `vxlan.calico` ed `eth0`; il filtro unisce HTTP interno e VXLAN UDP
4789 esterno.

```bash
export SOURCE_NODE='k3d-tesi-e10-calico-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-e10-calico-vxlan-agent-1'
SOURCE_PID="$(docker inspect -f '{{.State.Pid}}' "$SOURCE_NODE")"
SOURCE_UNDERLAY="$(docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e10-calico-vxlan"}}{{.IPAddress}}{{end}}' \
  "$SOURCE_NODE")"
DESTINATION_UNDERLAY="$(docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e10-calico-vxlan"}}{{.IPAddress}}{{end}}' \
  "$DESTINATION_NODE")"
CAPTURE_DIR="$(mktemp -d)"

printf 'pid=%s source_underlay=%s destination_underlay=%s capture_dir=%s\n' \
  "$SOURCE_PID" "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" "$CAPTURE_DIR"
```

Il PID deve essere positivo e gli underlay devono essere indirizzi IPv4
correnti distinti. La cattura nel namespace del nodo sorgente usa `-i any` per
mostrare due viste dello stesso GET `client → server-b`:

- traffico inner con IP Pod e TCP/8080;
- traffico outer fra gli underlay con UDP/4789.

Il filtro e il comando `tcpdump` restano espliciti; l'helper orchestra un solo
stimolo HTTP e verifica entrambe le viste:

```bash
sudo -v
TCPDUMP_FILTER="((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 4789))"
run_dual_view_capture \
  E10 \
  "$CAPTURE_DIR/calico-inter-node.log" \
  "$CAPTURE_DIR/http-client.log" \
  client server-b \
  "$CLIENT_IP" "$SERVER_B_IP" \
  "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 4789 \
  -- sudo -- /usr/bin/timeout --preserve-status --signal=TERM \
    --kill-after=3s 10s \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "$TCPDUMP_FILTER"
```

Se l'helper termina con errore, non proseguire. In caso di successo, leggere
cattura e risposta HTTP:

```bash
sed -n '1,260p' "$CAPTURE_DIR/calico-inter-node.log"
cat "$CAPTURE_DIR/http-client.log"
```

Correlare gli IP dei Pod nella vista inner e gli IP underlay nella vista outer;
cercare `vxlan.calico`, UDP 4789 e VNI 4096. La risposta separata deve
confermare che il GET ha raggiunto `server-b`. La gestione dei codici di
terminazione e dei processi `tcpdump` resta nell'helper validato.

`CAPTURE_DIR` va conservata in caso di errore. Dopo un esito positivo può
essere rimossa con `rm -rf -- "$CAPTURE_DIR"`.

### 10.5 Attribuzione del Service a kube-proxy

Per attribuire il Service verifichiamo separatamente i due backend Ready, poi
confrontiamo catene e contatori kube-proxy prima e dopo nuove connessioni al
ClusterIP. Il modulo E10 mantiene questa orchestrazione specifica senza
trasformarla in un helper Service generico. Gli observer effettivamente usati
restano riconoscibili nei comandi sottostanti:

```text
kubectl --context "$TESI_CONTEXT" get endpointslice \
  -n net-lab -l kubernetes.io/service-name=servers \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\n"}{end}'

docker exec "$CALICO_AGENT0" /bin/aux/iptables-save -c -t nat
```

Il primo comando alimenta il gate di readiness dei backend; il secondo produce
gli snapshot completi dai quali vengono filtrate le regole
`net-lab/servers:http`. La sequenza causale resta: snapshot `before`, sei nuove
connessioni controllate, snapshot `after`, parsing delle sole osservazioni HTTP
e confronto dei delta lungo
`KUBE-SERVICES → KUBE-SVC-* → KUBE-SEP-* → DNAT`. Il parser non genera traffico
e un delta positivo viene richiesto soltanto per i backend realmente osservati.

```bash
export TESI_CONTEXT='k3d-tesi-e10-calico-vxlan'
export TESI_NODE_PREFIX='k3d-tesi-e10-calico-vxlan'
SERVER_A_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-a -o jsonpath='{.status.podIP}')"
SERVER_B_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get pod server-b -o jsonpath='{.status.podIP}')"
SERVICE_IP="$(kubectl --context "$TESI_CONTEXT" -n net-lab \
  get svc servers -o jsonpath='{.spec.clusterIP}')"
export CALICO_AGENT0="${TESI_NODE_PREFIX}-agent-0"
export SERVICE_DIR="$(mktemp -d)"

printf 'server-a=%s server-b=%s service=%s service_dir=%s\n' \
  "$SERVER_A_IP" "$SERVER_B_IP" "$SERVICE_IP" "$SERVICE_DIR"
run_e10_service_attribution
```

Le tre variabili IP devono essere non vuote. L'helper si arresta se gli
EndpointSlice non espongono esattamente i due backend Ready; esegue poi una
sola batteria di **sei** nuove connessioni HTTP fra gli snapshot `before` e
`after`. Non rilanciare il test per ottenere una distribuzione diversa.

La distribuzione delle risposte fra i backend non è un criterio di successo.
Per i flussi realmente osservati, catene `KUBE-SVC`/`KUBE-SEP`, Destination
Network Address Translation (DNAT) e delta pertinenti dei contatori sostengono
l'attribuzione a kube-proxy iptables. Le evidence originali E10 registrarono
due risposte `server-a`; quel risultato è coerente con la selezione
probabilistica e non indebolisce l'attribuzione basata sui contatori.

### 10.6 NetworkPolicy: risultato applicativo e piano Felix

**Felix** è l'agente nel container `calico-node` che osserva lo stato desiderato
di endpoint e policy e lo traduce negli artefatti del data plane del nodo. In
questo profilo tali artefatti sono IPSet e catene iptables; non è
`calico-kube-controllers` ad applicare direttamente la policy ai pacchetti.

La relazione causale verificata è:

```text
NetworkPolicy API → Felix/calico-node → cali-pi-* e IPSet
                                      → cali-tw-* del workload → traffico
```

Nei log cerchiamo calcolo di policy, selector e IPSet; nel kernel cerchiamo gli
insiemi `cali*`, le catene iptables e i loro contatori. Il gate
`wait_for_calico_policy_convergence` attende nei dump iptables il commento
semantico `KubernetesNetworkPolicy net-lab/<nome> ingress`, ricava i nomi delle
chain e verifica il linkage fino al Pod interessato senza codificare hash.

La definizione è fornita da `scripts/cni/calico/e10-policy.sh`. Il modulo
mantiene separati l'inventario descrittivo e il gate di linkage; gli
observer restano espliciti:

```text
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
kubectl --context "$TESI_CONTEXT" logs -n calico-system \
  daemonset/calico-node -c calico-node --tail=300
docker exec "$NODE" ip -o route get "$POD_IP"
docker exec "$NODE" ip -br link
docker exec "$NODE" /bin/aux/iptables-save -c
docker exec "$NODE" /bin/ipset save
```

Per ciascun Pod il gate legge nodo e IP dall'API, risolve con
`ip route get <Pod IP>` l'interfaccia host `cali*`, seleziona la chain
esatta `cali-tw-<interfaccia>` e ne verifica il jump alla `cali-pi-*`
identificata dal commento semantico della policy. Nessun hash o nome storico
di chain viene assunto. Il gate è read-only e non genera traffico workload.

Eseguire i quattro stati in ordine e una sola volta.

#### Baseline: 6/6 connessioni consentite

```bash
run_policy_matrix allow-all
inspect_calico_policy_plane
```

#### Default deny: 0/6 connessioni consentite

Applicare la policy e attendere che il linkage Felix sia osservabile:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml
wait_for_calico_policy_convergence default-deny
```

Se il gate fallisce, fermarsi prima della matrice. Dopo il successo:

```bash
run_policy_matrix deny-all
inspect_calico_policy_plane
```

#### Allow selettiva: 4/6 connessioni consentite

La nuova policy ammette soltanto il client previsto verso i server HTTP:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml
wait_for_calico_policy_convergence selective-allow
```

Se il gate fallisce, non eseguire traffico. Dopo il successo:

```bash
run_policy_matrix selective-allow
inspect_calico_policy_plane
```

Selector, IPSet, catene e contatori devono essere coerenti con la progressione
qualitativa da baseline a deny e allow selettiva. Il gate legge gli artefatti
Felix senza generare traffico; gli esiti applicativi autorevoli restano 6/6
consentiti, 6/6 negati e quindi 4/6 consentiti nella singola esecuzione della
matrice per stato. L'enforcement osservato è attribuito al calculation graph e
a Felix.

#### Baseline ripristinata: 6/6 connessioni consentite

Rimuovere entrambe le policy e attendere che il gate read-only non trovi più i
linkage di policy:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
wait_for_calico_policy_convergence restored
```

Se il gate fallisce, fermarsi. Dopo il successo:

```bash
run_policy_matrix allow-all
inspect_calico_policy_plane
```

L'attribuzione causale è valida soltanto se la matrice torna a 6/6 consentiti.

### 10.7 Interpretazione complessiva

Le tre osservazioni non vanno confuse: route, `cali*` e `vxlan.calico`
dimostrano il networking Pod; le catene `KUBE-*` e i loro delta attribuiscono
il Service a kube-proxy; marker semantici, linkage `cali-tw-* → cali-pi-*` e
matrici applicative attribuiscono l'enforcement delle NetworkPolicy a
Calico/Felix. Ogni conclusione combina quindi stato Kubernetes, artefatto del
data plane e risultato del traffico pertinente.

### 10.8 Rimozione del cluster

```bash
kubectl --context "$TESI_CONTEXT" get tigerastatus
kubectl --context "$TESI_CONTEXT" get pods -A
k3d cluster delete tesi-e10-calico-vxlan
k3d cluster list
ss -ltn 'sport = :6448'
```

Le directory `CALICO_CHART_DIR`, `CALICO_RENDER_DIR`, `CAPTURE_DIR` e
`SERVICE_DIR` servono soltanto a E10. Dopo un esito positivo possono essere
eliminate esplicitamente; se un controllo fallisce, conservarle finché chart,
rendering, cattura e delta non sono stati diagnosticati.

## 11. E20 — Cilium VXLAN con data plane eBPF

Questo è il punto di ingresso E20 anche in una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
source scripts/cni/common/service.sh
source scripts/cni/common/capture.sh
source scripts/cni/cilium/service.sh
```

### 11.1 Download e controllo statico del chart

Scaricare esattamente il chart usato e verificarne l'integrità:

```bash
export E20_DIR="$(mktemp -d)"
curl -fsSL https://helm.cilium.io/cilium-1.19.6.tgz \
  -o "$E20_DIR/cilium-1.19.6.tgz"
printf '%s  %s\n' \
  '21c43cf53841f9ab0375047d95aa4c64051ea52bbd2c679416e6408f5f1c9179' \
  "$E20_DIR/cilium-1.19.6.tgz" | sha256sum --check -
```

Lo SHA-256 del chart deve essere:

```text
21c43cf53841f9ab0375047d95aa4c64051ea52bbd2c679416e6408f5f1c9179
```

Eseguire lint e rendering con il file valori pubblico:

```bash
if helm lint "$E20_DIR/cilium-1.19.6.tgz" \
    --values manifests/cni/cilium/values.yaml && \
    helm template cilium "$E20_DIR/cilium-1.19.6.tgz" \
      --namespace kube-system \
      --values manifests/cni/cilium/values.yaml \
      --kube-version 1.34.9 \
      --output-dir "$E20_DIR/rendered"
then
  RENDER_FILTER_FAILED=0
  if grep -R -n -E 'kind: (DaemonSet|Deployment)|image:|latest' \
      "$E20_DIR/rendered"
  then
    RENDER_FILTER_RC=0
  else
    RENDER_FILTER_RC=$?
  fi
  case "$RENDER_FILTER_RC" in
    0) ;;
    1) printf 'INFO: nessun marker del filtro trovato nel rendering Cilium.\n' ;;
    *) printf 'ERROR: filtro rendering Cilium fallito (grep rc=%s).\n' \
         "$RENDER_FILTER_RC" >&2; RENDER_FILTER_FAILED=1 ;;
  esac
  unset RENDER_FILTER_RC
  if [[ "$RENDER_FILTER_FAILED" -ne 0 ]]
  then
    unset RENDER_FILTER_FAILED
    false
  else
    unset RENDER_FILTER_FAILED
  fi
else
  printf 'ERROR: lint o rendering statico Cilium fallito.\n' >&2
  false
fi
```

Controllare un DaemonSet `cilium`, un Deployment `cilium-operator`, immagini
bloccate e assenza di Relay, interfaccia grafica Hubble, Envoy separato e
altri workload esclusi dalla configurazione.

### 11.2 Creazione e installazione

Il file `manifests/cni/cilium/values.yaml` configura Cilium come CNI primario,
Cluster Pool IPAM con blocchi `/24`, VXLAN, data path veth/eBPF,
`kubeProxyReplacement=false` e Hubble locale; esclude le funzioni non studiate
come Relay, livello 7, cifratura e Cluster Mesh. Helm renderizza e applica
questa configurazione al cluster privo di Flannel.

```bash
check_experiment_preflight tesi-e20-cilium-vxlan 6449
k3d cluster create tesi-e20-cilium-vxlan \
  --image "$TESI_K3S_IMAGE" \
  --servers 1 --agents 2 \
  --api-port 127.0.0.1:6449 \
  --k3s-arg '--disable=traefik@server:*' \
  --k3s-arg '--flannel-backend=none@server:*' \
  --k3s-arg '--disable-network-policy@server:*' \
  --k3s-arg '--cluster-cidr=10.42.0.0/16@server:*' \
  --k3s-arg '--service-cidr=10.43.0.0/16@server:*' \
  --wait --timeout 180s

export TESI_CONTEXT='k3d-tesi-e20-cilium-vxlan'
export TESI_NODE_PREFIX='k3d-tesi-e20-cilium-vxlan'

helm install cilium "$E20_DIR/cilium-1.19.6.tgz" \
  --kube-context "$TESI_CONTEXT" \
  --namespace kube-system \
  --values manifests/cni/cilium/values.yaml \
  --wait --timeout 10m
```

### 11.3 Verifica di Cilium ed eBPF

Prima del workload verifichiamo convergenza, CNI esclusivo, Cluster Pool
IPAM, tunnel e strumenti locali. Le **mappe eBPF** sono strutture del kernel
usate da Cilium per conservare endpoint, policy, load balancing e conntrack.
**Hubble** legge la telemetria Cilium e permette di correlare identità,
verdetti e connessioni senza introdurre un Relay nel laboratorio.
Il rollout del DaemonSet dispone di 600 secondi per coprire anche bootstrap e
pull iniziali su host con cache immagini fredda.

```bash
wait_for_cilium_daemonset_ready() {
  local DAEMONSET_STATUS
  local DESIRED
  local CURRENT
  local READY
  local AVAILABLE
  local EXTRA

  if ! kubectl --context "$TESI_CONTEXT" \
      rollout status daemonset/cilium \
      -n kube-system \
      --timeout=600s
  then
    printf 'ERROR: rollout del DaemonSet Cilium non completato entro il timeout.\n' >&2
    return 1
  fi

  if ! DAEMONSET_STATUS="$(kubectl --context "$TESI_CONTEXT" get \
      daemonset -n kube-system cilium \
      -o jsonpath='{.status.desiredNumberScheduled}{"|"}{.status.currentNumberScheduled}{"|"}{.status.numberReady}{"|"}{.status.numberAvailable}')"
  then
    printf 'ERROR: lettura strutturata dello stato DaemonSet Cilium fallita.\n' >&2
    return 2
  fi

  IFS='|' read -r DESIRED CURRENT READY AVAILABLE EXTRA \
    <<< "$DAEMONSET_STATUS"
  if [[ ! "$DESIRED" =~ ^[0-9]+$ || ! "$CURRENT" =~ ^[0-9]+$ ||
        ! "$READY" =~ ^[0-9]+$ || ! "$AVAILABLE" =~ ^[0-9]+$ ||
        -n "$EXTRA" ]]
  then
    printf 'ERROR: stato DaemonSet Cilium mancante o malformato: %q.\n' \
      "$DAEMONSET_STATUS" >&2
    return 2
  fi
  if [[ "$DESIRED" -ne 3 || "$CURRENT" -ne 3 ||
        "$READY" -ne 3 || "$AVAILABLE" -ne 3 ]]
  then
    printf 'FAIL: DaemonSet Cilium non convergente: desired=%s current=%s ready=%s available=%s.\n' \
      "$DESIRED" "$CURRENT" "$READY" "$AVAILABLE" >&2
    return 1
  fi

  printf 'PASS: DaemonSet Cilium convergente: desired=3 current=3 ready=3 available=3.\n'
}

kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=300s
wait_for_cilium_daemonset_ready && {
kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get daemonset -n kube-system cilium
kubectl --context "$TESI_CONTEXT" get deployment -n kube-system cilium-operator
kubectl --context "$TESI_CONTEXT" get ciliumnodes -o yaml

_tesi_export_runtime CILIUM_AGENT0 pod-name kubectl \
  --context "$TESI_CONTEXT" get pods \
  -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName=k3d-tesi-e20-cilium-vxlan-agent-0 \
  -o jsonpath='{.items[0].metadata.name}' &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg status --verbose &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg endpoint list &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- hubble status \
  --server unix:///var/run/cilium/hubble.sock
}
```

Ispezionare CNI, route, VXLAN e attach eBPF in ogni nodo:

```bash
NODE_INVENTORY_FAILED=0
for NODE in \
  k3d-tesi-e20-cilium-vxlan-server-0 \
  k3d-tesi-e20-cilium-vxlan-agent-0 \
  k3d-tesi-e20-cilium-vxlan-agent-1
do
  docker exec "$NODE" sh -c \
    'test -d /etc/cni/net.d && ls -la /etc/cni/net.d && test -r /etc/cni/net.d/05-cilium.conflist && sed -n "1,240p" /etc/cni/net.d/05-cilium.conflist' || \
    NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip -br link || NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip route || NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip -details link show cilium_vxlan || \
    NODE_INVENTORY_FAILED=1
done

if [[ "$NODE_INVENTORY_FAILED" -ne 0 ]]
then
  printf 'ERROR: inventario data plane E20 incompleto.\n' >&2
  unset NODE_INVENTORY_FAILED
  false
else
  unset NODE_INVENTORY_FAILED
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- bpftool net
fi
```

Controllare tre nodi `Ready`, Cilium `3/3`, un Operator disponibile, blocchi
IPAM `/24`, `05-cilium.conflist`, bpffs, `cilium_vxlan`, route remote e hook
TCX. Flannel e il controller policy K3s devono essere assenti; kube-proxy deve
restare presente. Lo stato deve riportare `KubeProxyReplacement: False` e
Hubble soltanto locale.

### 11.4 Workload e percorso intra-node

Applicare il workload comune e rileggere endpoint, identità e indirizzi. La
singola matrice baseline autorevole viene eseguita nella sezione 11.7, dove la
sua finestra temporale viene congelata e osservata da Hubble:

```bash
deploy_common_workload &&
_tesi_export_runtime CLIENT_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod client -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVER_A_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod server-a -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVER_B_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod server-b -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVICE_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get svc servers -o jsonpath='{.spec.clusterIP}' &&
kubectl --context "$TESI_CONTEXT" get ciliumendpoint \
  -n net-lab client server-a server-b -o wide &&

_tesi_export_runtime CLIENT_ENDPOINT_ID positive-integer kubectl \
  --context "$TESI_CONTEXT" get ciliumendpoint -n net-lab client \
  -o jsonpath='{.status.id}' &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg endpoint get "$CLIENT_ENDPOINT_ID" &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- ip route get "$SERVER_A_IP" &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- bpftool net
```

Per il flusso locale verificare veth `lxc*`, route tramite `cilium_host` e
programma `cil_from_container`; il tunnel non deve intervenire fra `client` e
`server-a`.

### 11.5 Cattura inter-node

Il percorso atteso è veth `lxc*` → `cilium_vxlan` → `eth0`. Entriamo nel
namespace del nodo sorgente e usiamo `-i any` per correlare il pacchetto HTTP
fra Pod con il datagramma VXLAN UDP 8472 fra gli indirizzi underlay.

```bash
export SOURCE_NODE='k3d-tesi-e20-cilium-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-e20-cilium-vxlan-agent-1'
_tesi_export_runtime SOURCE_PID positive-integer docker inspect \
  -f '{{.State.Pid}}' "$SOURCE_NODE" &&
_tesi_export_runtime SOURCE_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
  "$SOURCE_NODE" &&
_tesi_export_runtime DESTINATION_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
  "$DESTINATION_NODE" &&
export CAPTURE_DIR="$(mktemp -d)" &&

sudo /usr/bin/nsenter --target "$SOURCE_PID" --net \
  /usr/sbin/ip -details link show cilium_vxlan &&

sudo -v &&
TCPDUMP_FILTER="((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 8472))" &&
if run_dual_view_capture \
  E20 \
  "$CAPTURE_DIR/cilium-inter-node.log" \
  "$CAPTURE_DIR/http-client.log" \
  client server-b \
  "$CLIENT_IP" "$SERVER_B_IP" \
  "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 8472 \
  -- sudo /usr/bin/env LC_ALL=C \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/timeout --verbose --foreground --preserve-status \
    --signal=TERM --kill-after=2s 8s \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "$TCPDUMP_FILTER"
then
  sed -n '1,360p' "$CAPTURE_DIR/cilium-inter-node.log" &&
    cat "$CAPTURE_DIR/http-client.log"
else
  false
fi
```

Correlare il flusso su veth `lxc*`, `cilium_vxlan` ed `eth0`, con IP dei Pod
all'interno e UDP 8472 fra gli underlay. In questa modalità il decoder
`tcpdump` può mostrare il campo VXLAN come `OTV instance`: non interpretarlo
come assenza del VNI. Nelle
[evidenze E20 pubblicate](../experiments/cni/e20-cilium-vxlan/evidence/) i
valori osservati sono 21766 e 16090 e coincidono con le security identity delle
rispettive sorgenti; in una nuova replica possono cambiare.

Per la cattura sono accettati exit code `0`, `124` o `143`; gli altri indicano
un errore da diagnosticare.

`CAPTURE_DIR` va conservata in caso di errore. Dopo un esito positivo può
essere rimossa con `rm -rf -- "$CAPTURE_DIR"`.

### 11.6 Attribuzione del Service

La configurazione mantiene kube-proxy, quindi la sola presenza delle sue
regole o delle mappe Cilium non attribuisce un flusso. Confrontiamo tre fonti
nella stessa finestra: contatori iptables kube-proxy, stato load balancer e
conntrack eBPF, e flussi Hubble. Solo la combinazione dei delta permette una
conclusione circoscritta alle connessioni generate.

Verificare prima la disponibilità dei due backend, poi acquisire stato
kube-proxy ed eBPF prima di nuove connessioni.

Il modulo specifico [`scripts/cni/cilium/service.sh`](../scripts/cni/cilium/service.sh)
mantiene separati producer, snapshot e parser. Gli observer eseguiti dal runner
restano espliciti e riconoscibili:

```text
docker exec "$CILIUM_NODE" /bin/aux/iptables-save -c -t nat
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --frontends
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --backends
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --revnat
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg bpf ct list global
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- hubble observe \
  --server unix:///var/run/cilium/hubble.sock \
  --since "$START_UTC" --until "$END_UTC" \
  --from-pod net-lab/client --port 8080 -o jsonpb
```

`capture_service_iptables_snapshot` salva prima e dopo sia il dump NAT
completo sia le sole regole pertinenti a `net-lab/servers:http`. Le mappe BPF
registrano il frontend `$SERVICE_IP:8080`, i backend e la mappa RevNAT;
conntrack viene acquisito prima e dopo le connessioni. Il runner congela
`START_UTC` immediatamente prima ed `END_UTC` immediatamente dopo
`service_http_flows 6`: soltanto quelle sei nuove connessioni appartengono
alla finestra. Il polling Hubble rilegge la stessa finestra senza rigenerare
traffico e promuove il file temporaneo soltanto dopo la correlazione completa.

La correlazione preservata dal modulo è:

```text
HTTP responses
    ↓
new CT TCP SVC entries
    ↓
BPF backend IDs
    ↓
backend IP
    ↓
RevNAT / Service ID
    ↓
Hubble frozen window
```

Il parser considera esclusivamente le nuove entry `TCP SVC`, le collega alle
relative entry `TCP OUT`, quindi verifica backend ID, IP osservato, RevNAT e
Service ID nelle mappe BPF. La distribuzione fra `server-a` e `server-b` non è
predeterminata. I parser non producono traffico e distinguono un fallimento
causale (RC 1) da un errore operativo o di formato (RC 2).

Eseguire l'attribuzione completa con:

```bash
export CILIUM_NODE='k3d-tesi-e20-cilium-vxlan-agent-0'
export SERVICE_DIR="$(mktemp -d)"
export CILIUM_SERVICE_HUBBLE_TIMEOUT=20

run_e20_service_attribution
```

La distribuzione delle risposte fra i backend non è un criterio di successo.
La conclusione E20 richiede congiuntamente, per le connessioni realmente
osservate: nuove entry conntrack `TCP SVC` con backend e reverse Network
Address Translation (NAT) coerenti con le risposte, correlazione Hubble e
nessun delta nei contatori kube-proxy pertinenti. Vale soltanto per quei flussi
e non dimostra che kube-proxy sia inattivo in ogni percorso. Le evidence
originali selezionarono entrambi i backend in due connessioni, ma la nuova
procedura non assume che ciò debba ripetersi.

### 11.7 Matrice NetworkPolicy

Il protocollo mantiene separati quattro passaggi: mutazione della NetworkPolicy,
convergenza del policy plane Cilium, una sola matrice HTTP autorevole e
osservazione del dataplane. La relazione verificata per ogni stato è:

```text
NetworkPolicy API
      ↓
Cilium policy revision
      ↓
endpoint realization
      ↓
BPF policy maps sugli agent pertinenti
      ↓
matrice HTTP controllata
      ↓
Hubble multi-agent nella finestra della matrice
      ↓
interpretazione
```

La machinery di polling, parsing, file temporanei e raccolta multi-agent è nei
due moduli Cilium. Il primo contiene gli observer Hubble/BPF; il secondo
gestisce discovery, revisioni, endpoint e orchestrazione dello stato. Entrambi
sono librerie da caricare dopo i moduli comuni già caricati all'inizio di E20:

```bash
source scripts/cni/cilium/policy-observers.sh
source scripts/cni/cilium/network-policy.sh

export POLICY_DIR="$(mktemp -d)"
export CILIUM_POLICY_TIMEOUT=120
export CILIUM_HUBBLE_TIMEOUT=20
declare -a CILIUM_POLICY_NODES=()
declare -a CILIUM_POLICY_AGENTS=()
declare -a CILIUM_POLICY_REVISIONS=()
declare -a CILIUM_POLICY_PODS=()
```

`snapshot_cilium_policy_revisions` ricava nuovamente i nodi di `client`,
`server-a` e `server-b`, individua su ciascun nodo l'unico agent Cilium
`Running` e registra revisione e Pod pertinenti. Nessun nome agent, endpoint ID
o BPF map ID deriva dalle evidence storiche.

Dopo una mutazione, `wait_for_cilium_policy_convergence` usa un unico timeout
bounded di 120 secondi. Per ogni agent richiede che la revisione sia avanzata,
che il documento importato contenga esattamente le policy previste dallo stato,
che `cilium-dbg policy wait` raggiunga la revisione e che tutti gli endpoint
workload locali siano `ready`, con revisione richiesta e realizzata coincidenti
e non inferiori al target. Il gate non genera traffico e non richiama la
matrice HTTP.

Gli helper mantengono visibili e usano, per gli agent e gli intervalli scoperti
a runtime, queste interfacce di osservazione già validate:

```text
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml
kubectl --context "$TESI_CONTEXT" get ciliumendpoint \
  -n net-lab client server-a server-b -o yaml

kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  cilium-dbg policy get -o jsonpath='{.revision}'
kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  cilium-dbg policy get -o jsonpath='{.policy}'
kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  cilium-dbg policy wait "$TARGET_REVISION" \
  --max-wait-time "$REMAINING" --fail-wait-time "$REMAINING" --sleep-time 1
kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  cilium-dbg endpoint list \
  -o jsonpath='{range [*]}{@.status.external-identifiers.pod-name}{"|"}{@.status.state}{"|"}{@.status.policy.spec.policy-revision}{"|"}{@.status.policy.realized.policy-revision}{"\n"}{end}'
kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  cilium-dbg bpf policy get --all
kubectl --context "$TESI_CONTEXT" exec -n kube-system "$AGENT" -- \
  hubble observe --server unix:///var/run/cilium/hubble.sock \
  --since "$POLICY_SINCE" --until "$POLICY_UNTIL" \
  --namespace net-lab --port 8080 -o jsonpb
```

Per ciascuno stato, `capture_cilium_policy_state` congela `POLICY_SINCE`,
esegue una sola `run_policy_matrix`, congela `POLICY_UNTIL` e solo dopo
interroga Hubble sulla stessa finestra assoluta RFC3339Nano. Il collector può
ripetere, per non più di 20 secondi, soltanto le query della finestra già
chiusa: parsing e polling non rigenerano traffico workload.

La raccolta Hubble interroga separatamente tutti gli agent pertinenti, registra
su stderr l'agent interrogato, conserva durante ogni polling un raw file
temporaneo distinto per agent e concatena gli output solo dopo le acquisizioni.
Il parser verifica JSONPB, finestra e verdetti semanticamente richiesti. I raw
temporanei vengono eliminati dopo la promozione atomica dell'aggregato finale;
la baseline non applica deduplicazione e Hubble Relay resta disabilitato.

Le policy map eBPF sono node-local. Per ogni agent distinto viene conservato
`<stato>-bpf-policy-<agent>.log`; solo dopo i raw dump vengono aggregati in
`<stato>-bpf-policy.log`, con intestazioni che mantengono `agent` e
`raw-file`. Un agent pertinente mancante, un nome non valido o un dump vuoto
fanno fallire l'acquisizione.

#### Baseline, default deny e selective allow

Eseguire i tre stati nello stesso ordine della baseline. Ogni blocco mantiene
la sequenza mutazione API → convergence gate → singola matrice → observer:

La chiamata `capture_cilium_policy_state baseline allow-all` seguente produce
l'unica matrice baseline E20. I flussi ClusterIP della sezione Service non la
sostituiscono: non osservano la stessa matrice diretta fra Pod IP.

```bash
snapshot_cilium_policy_revisions &&
capture_cilium_policy_state baseline allow-all &&

snapshot_cilium_policy_revisions &&
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml &&
wait_for_cilium_policy_convergence default-deny &&
capture_cilium_policy_state default-deny deny-all &&

snapshot_cilium_policy_revisions &&
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml &&
wait_for_cilium_policy_convergence selective-allow &&
capture_cilium_policy_state selective-allow selective-allow &&

ls -la "$POLICY_DIR"
```

Gli expected result restano:

- `baseline`: nessuna policy pertinente e 6/6 flussi consentiti;
- `default-deny`: default deny presente e 6/6 flussi negati;
- `selective-allow`: default deny più allow selettiva e 4/6 flussi consentiti.

Per ogni stato vengono prodotti:

- `<stato>-networkpolicy.yaml`, oggetti API osservati;
- `<stato>-endpoints.yaml`, stato degli endpoint Cilium;
- `<stato>-bpf-policy-<agent>.log`, raw BPF con provenienza per-agent;
- `<stato>-bpf-policy.log`, indice BPF aggregato con intestazioni;
- `<stato>-hubble.json`, aggregato Hubble della sola finestra controllata.

Controllare revisioni crescenti dopo ogni mutazione, policy map pertinenti e
verdetti Hubble `FORWARDED` o `DROPPED` con
`drop_reason_desc=POLICY_DENIED`. Questi artefatti, insieme alla matrice,
attribuiscono l'enforcement a Cilium/eBPF e non al controller NetworkPolicy K3s
disabilitato.

#### Stato restored

Rimuovere entrambe le policy e attendere nuovamente revisione, stato semantico
senza le due policy ed endpoint realization. Solo dopo il gate acquisire
un'unica matrice finale `allow-all` e gli stessi observer multi-agent:

```bash
snapshot_cilium_policy_revisions &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found &&
wait_for_cilium_policy_convergence restored &&
capture_cilium_policy_state restored allow-all
```

Il PASS richiede il ritorno a 6/6 flussi consentiti, policy importate senza
residui delle due NetworkPolicy pertinenti, endpoint realizzati e artefatti
BPF/Hubble coerenti con lo stato ripristinato.

### 11.8 Troubleshooting circoscritto al riavvio Docker

Questo controllo non è parte del percorso normale. Usarlo soltanto se, dopo
un riavvio Docker, i flussi intra-node funzionano ma quelli inter-node verso
`agent-1` falliscono.

```bash
export AGENT1_NODE='k3d-tesi-e20-cilium-vxlan-agent-1'
_tesi_export_runtime AGENT1_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
  "$AGENT1_NODE" &&
_tesi_export_runtime CILIUM_AGENT1 pod-name kubectl \
  --context "$TESI_CONTEXT" get pods \
  -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName=k3d-tesi-e20-cilium-vxlan-agent-1 \
  -o jsonpath='{.items[0].metadata.name}' &&

printf 'docker_underlay=%s\n' "$AGENT1_UNDERLAY" &&
kubectl --context "$TESI_CONTEXT" get ciliumnode \
  k3d-tesi-e20-cilium-vxlan-agent-1 -o yaml &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg node list &&
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg bpf ipcache list
```

Se e solo se le tre viste conservano un tunnel endpoint diverso dall'underlay
Docker corrente, la procedura di ripristino consiste nel ricreare il solo Pod
Cilium di `agent-1`:

```bash
kubectl --context "$TESI_CONTEXT" delete pod -n kube-system "$CILIUM_AGENT1"
kubectl --context "$TESI_CONTEXT" rollout status \
  daemonset/cilium -n kube-system --timeout=180s
```

Rileggere Pod Cilium, `CiliumNode`, node list e IP cache, poi ripetere ICMP e
HTTP inter-node. Nelle evidenze E20 questo riallineamento ha ripristinato i
flussi; la causa della mancata riconciliazione automatica non è stata
determinata e il comportamento non costituisce una proprietà generale di
Cilium.

### 11.9 Rimozione del cluster

```bash
kubectl --context "$TESI_CONTEXT" get nodes
kubectl --context "$TESI_CONTEXT" get pods -A
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg status --verbose
k3d cluster delete tesi-e20-cilium-vxlan
k3d cluster list
ss -ltn 'sport = :6449'
```

Le directory `E20_DIR`, `CAPTURE_DIR`, `SERVICE_DIR` e `POLICY_DIR` servono
soltanto a E20. Dopo un esito positivo possono essere eliminate esplicitamente;
in caso di errore conservarle finché chart, cattura, output Service e stato
policy non sono stati diagnosticati.

La rimozione deve riguardare solo E20. Non eliminare manualmente programmi o
mappe eBPF, route, regole netfilter o reti Docker senza avere prima dimostrato
un residuo specifico.

## 12. Controllo finale e dati da conservare

### 12.1 Controllo conclusivo dell'host

Dopo avere eliminato l'ultimo cluster, verificare che non restino i cluster,
i container nodo o i listener API creati dalla guida. Il source idempotente del
modulo di cattura rende disponibile anche il controllo dei processi `tcpdump`:

```bash
source scripts/cni/common/lab-env.sh
source scripts/cni/common/capture.sh

run_final_host_check() {
  local cluster_list
  local container_list
  local listener_list
  local parser_rc

  if ! cluster_list="$(k3d cluster list)"
  then
    printf 'ERROR: inventario finale k3d non leggibile.\n' >&2
    return 1
  fi
  printf '%s\n' "$cluster_list"
  if awk '$1 ~ /^tesi-/ { found=1 } END { exit !found }' \
      <<<"$cluster_list"
  then
    parser_rc=0
  else
    parser_rc=$?
  fi
  case "$parser_rc" in
    0)
      printf 'FAIL: sono ancora presenti cluster tesi.\n' >&2
      return 1
      ;;
    1) ;;
    *)
      printf 'ERROR: parser inventario cluster fallito (awk rc=%s).\n' \
        "$parser_rc" >&2
      return 1
      ;;
  esac

  if ! container_list="$(docker ps -a --filter 'name=k3d-tesi-' \
      --format '{{.Names}}\t{{.Image}}\t{{.Status}}')"
  then
    printf 'ERROR: inventario finale dei container non leggibile.\n' >&2
    return 1
  fi
  printf '%s\n' "$container_list"
  if [[ -n "$container_list" ]]
  then
    printf 'FAIL: sono ancora presenti container nodo tesi.\n' >&2
    return 1
  fi

  kubectl config get-contexts || return 1
  if ! listener_list="$(ss -H -ltn \
      'sport = :6445 or sport = :6446 or sport = :6447 or sport = :6448 or sport = :6449')"
  then
    printf 'ERROR: inventario finale dei listener API non leggibile.\n' >&2
    return 1
  fi
  if [[ -n "$listener_list" ]]
  then
    printf 'FAIL: sono ancora presenti listener API del laboratorio:\n%s\n' \
      "$listener_list" >&2
    return 1
  fi

  verify_no_tcpdump_processes || return 1
  printf 'PASS: nessun cluster, container nodo, listener API o tcpdump residuo.\n'
}

run_final_host_check
```

L'elenco non deve contenere i cluster E01, E02, E10 o E20. Non rimuovere
risorse estranee al laboratorio soltanto perché compaiono negli inventari.

### 12.2 Troubleshooting essenziale

#### Docker socket non accessibile

**Sintomo:** `docker info` restituisce `permission denied` su
`/run/docker.sock` dopo `usermod`.

**Possibile contesto:** la shell corrente conserva i gruppi acquisiti al
login.

**Controllo:** `id -nG` deve contenere `docker`; `stat -c '%a %U:%G %n'
/run/docker.sock` deve mostrare `root:docker` e modo `660`.

**Ripristino verificato:** logout/login; per un controllo temporaneo usare
`sg docker -c 'docker version'`.

#### Nodi NotReady durante il bootstrap di Calico o Cilium

**Sintomo:** subito dopo `k3d cluster create`, i nodi senza Flannel sono
`NotReady`.

**Possibile contesto:** con `--flannel-backend=none` la rete primaria non è
ancora installata.

**Controllo:** verificare che il cluster API risponda e che l'assenza del CNI
sia la causa riportata dai Pod o dagli eventi.

**Soluzione:** completare l'installazione prevista del CNI e attendere il
timeout indicato. Non aggiungere Flannel né un secondo plugin per rendere
prematuramente `Ready` i nodi.

#### Identificativi cambiati dopo un riavvio

**Sintomo:** `nsenter`, una route o un filtro di cattura usa un PID, un IP o
una veth non più esistente.

**Possibile contesto:** Docker ha riavviato o ricreato nodi e sandbox.

**Controllo:** ripetere `docker inspect`, `kubectl get pods -o wide`,
`crictl pods`, `CiliumEndpoint` o la funzione Pod–veth pertinente.

**Soluzione:** rigenerare tutte le variabili runtime; non correggere
manualmente route o stato CNI sulla base dei valori storici.

#### DNS influenzato da un search suffix

**Sintomo:** il nome `servers.net-lab.svc.cluster.local` viene risolto verso
un indirizzo estraneo al cluster.

**Possibile contesto:** il resolver aggiunge un suffisso dell'ambiente host.

**Controllo:** confrontare `nslookup` sul nome con e senza punto finale.

**Soluzione verificata:** usare il nome assoluto
`servers.net-lab.svc.cluster.local.` per la prova E01.

#### Terminazione di tcpdump impedita dal profilo di sicurezza

**Sintomo:** `timeout` non termina la cattura o restano processi diagnostici.

**Possibile contesto:** un profilo AppArmor del terminale impedisce a
`tcpdump` di ricevere il segnale.

**Controllo:** leggere `cat /proc/$$/attr/current`, controllare i processi con
`pgrep` e consultare gli eventuali dinieghi del kernel.

**Soluzione:** usare un terminale non confinato compatibile con le policy
dell'host oppure configurare una regola locale strettamente limitata ai
segnali necessari. Non disabilitare AppArmor. Una regola AppArmor locale non
è un prerequisito generale.

L'incoerenza underlay osservata una volta in E20 è trattata separatamente
nella sezione 11.8, perché diagnosi e ripristino riguardano soltanto quel
sintomo.

### 12.3 Dati da conservare

Per rendere verificabile una nuova esecuzione, conservare separatamente:

- ambiente, versioni, hash di chart e immagini effettive;
- comando di creazione e configurazione del cluster;
- stato di nodi, componenti, workload e allocazioni IPAM;
- route, interfacce, CNI, identificativi runtime e singola cattura pertinente;
- richieste applicative distinte dagli output delle catture;
- snapshot prima/dopo per Service e per ciascuno stato NetworkPolicy;
- log del componente al quale viene attribuito il comportamento;
- stato finale, rimozione del cluster e controllo post-delete.

Non includere kubeconfig, token o altri segreti. I README degli esperimenti
collegano una selezione degli output originali pubblicati e il relativo indice
SHA-256. Una nuova replica deve usare una directory di raccolta propria: non è
atteso che IP, PID, timestamp, veth, porte o identity coincidano byte per byte,
ma che siano riprodotti i comportamenti e le proprietà osservate pertinenti.
