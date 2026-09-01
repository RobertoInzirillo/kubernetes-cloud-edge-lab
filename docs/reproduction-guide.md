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

La procedura è stata verificata end-to-end. Per ogni nuova riproduzione, registrare il tag o commit utilizzato e il valore restituito da git rev-parse HEAD.

### 1.2 Percorso della guida

Il manuale accompagna il lettore dalla preparazione di un host Linux alla
riproduzione di E01, E02, E10 ed E20. Preparazione e toolchain vanno eseguite
nell'ordine indicato; dopo le sezioni comuni ciascun esperimento può iniziare
dal proprio punto di ingresso. Salvo diversa indicazione, i comandi si
eseguono dalla radice della repository clonata. Ogni esperimento usa un
cluster distinto; eliminarlo al termine evita che interfacce, route o regole
residue influenzino il caso successivo.

La guida presenta la procedura corrente per riprodurre configurazioni,
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

Le evidence pubblicate appartengono alle sessioni sperimentali descritte nei
rispettivi README; una nuova riproduzione produce output propri.

## 2. Ambiente di riferimento

L'ambiente di riferimento è Zorin OS 18.1, basato su Ubuntu 24.04 Noble,
architettura `amd64`, control group v2 (cgroup v2) e Berkeley Packet Filter
filesystem (bpffs). La procedura parte da un sistema Zorin OS o Ubuntu
compatibile pulito. Le evidence storiche E20 registrano il kernel
`7.0.0-28-generic`; una nuova riproduzione deve registrare la propria release
senza assumere che coincida.

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
Noble e installa le versioni della baseline corrente.

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
| Docker della baseline corrente | `29.7.2` |
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| kubectl | `v1.34.9` |
| Helm | `v3.21.3` |
| BusyBox | `1.38.0` |
| Calico | `v3.32.1` |
| Cilium | `1.19.6` |

Le versioni Docker associate alle evidence storiche erano `29.6.2` in
E01/E02, `29.7.1` in E10 e `29.7.2` in E20. La procedura corrente usa `29.7.2`
per tutti gli esperimenti, senza uniformare retroattivamente i runtime delle
evidence originali.

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

`e02-policy.sh` fornisce il controllo di convergenza e i comandi di
osservazione del policy plane K3s. La matrice di riferimento comprende due
nuove connessioni per ognuno dei flussi `client → server-a`,
`client → server-b` e `server-a → server-b`, per un totale di sei richieste
per stato.

Le evidence storiche E02 conservano i tre stati sperimentali principali, cioè
18 connessioni per cluster. La procedura corrente aggiunge il restore come
verifica del ritorno alla baseline: esegue quindi quattro matrici, per un totale
di 24 connessioni per cluster, senza trattare il restore come una quarta
configurazione scientifica.

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
corrispondano allo stato richiesto. Il controllo legge soltanto il data plane,
non genera traffico workload e non sostituisce la matrice di traffico, che
viene eseguita una sola volta dopo la convergenza.

I blocchi di ogni stato sono sequenziali: eseguire il successivo soltanto se il
precedente termina correttamente. In particolare, non avviare mai una matrice
se la mutazione API o il controllo di convergenza che la precede falliscono.

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

Questa matrice `6/6` è la baseline di riferimento prima dell'introduzione delle
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

Soltanto dopo che il controllo di convergenza termina correttamente, eseguire
la matrice di traffico e acquisire le osservazioni:

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

Soltanto dopo che il controllo di convergenza termina correttamente, eseguire
la matrice e acquisire le osservazioni:

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

Soltanto dopo che il controllo di convergenza termina correttamente, verificare
il ritorno alla baseline:

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

Quando i Pod sono Ready, eseguire la matrice baseline e i comandi di
osservazione:

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

Con entrambi gli oggetti visibili nell'API, eseguire una sola matrice e i
comandi di osservazione:

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
invochiamo il controllo del caso ON, perché le strutture che esso attende devono
restare assenti; la matrice viene comunque eseguita una sola volta:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
```

Dopo la rimozione API, eseguire la matrice finale e i comandi di osservazione:

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

La sequenza applica direttamente la configurazione corrente. Se Calico non
raggiunge lo stato atteso, fermarsi e conservare lo stato per la diagnosi.

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
terminazione e dei processi `tcpdump` resta nell'helper.

`CAPTURE_DIR` va conservata in caso di errore. Dopo un esito positivo può
essere rimossa con `rm -rf -- "$CAPTURE_DIR"`.

### 10.5 Attribuzione del Service a kube-proxy

Per attribuire il Service verifichiamo separatamente i due backend Ready, poi
confrontiamo catene e contatori kube-proxy prima e dopo nuove connessioni al
ClusterIP. Il modulo E10 mantiene questa orchestrazione specifica senza
trasformarla in un helper Service generico. I comandi di osservazione usati
restano visibili qui sotto:

```text
kubectl --context "$TESI_CONTEXT" get endpointslice \
  -n net-lab -l kubernetes.io/service-name=servers \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\n"}{end}'

docker exec "$CALICO_AGENT0" /bin/aux/iptables-save -c -t nat
```

Il primo comando verifica la readiness dei backend; il secondo produce
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
insiemi `cali*`, le catene iptables e i loro contatori. La funzione
`wait_for_calico_policy_convergence` attende nei dump iptables il commento
semantico `KubernetesNetworkPolicy net-lab/<nome> ingress`, ricava i nomi delle
chain e verifica il linkage fino al Pod interessato senza codificare hash.

La definizione è fornita da `scripts/cni/calico/e10-policy.sh`. Il modulo
mantiene separati l'inventario descrittivo e la verifica del linkage; i comandi
di osservazione restano espliciti:

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

Per ciascun Pod la funzione legge nodo e IP dall'API, risolve con
`ip route get <Pod IP>` l'interfaccia host `cali*`, seleziona la chain
esatta `cali-tw-<interfaccia>` e ne verifica il jump alla `cali-pi-*`
identificata dal commento semantico della policy. Nessun hash o nome storico
di chain viene assunto. Il controllo è in sola lettura e non genera traffico
workload.

Eseguire i quattro stati in ordine e una sola volta. Le evidence storiche E10
conservano baseline, default deny e allow selettiva; il restore è una verifica
aggiuntiva della procedura corrente e non modifica i tre stati usati nel
confronto scientifico.

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

Se il controllo di convergenza fallisce, fermarsi prima della matrice. Quando
termina correttamente:

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

Se il controllo di convergenza fallisce, non eseguire traffico. Quando termina
correttamente:

```bash
run_policy_matrix selective-allow
inspect_calico_policy_plane
```

Selector, IPSet, catene e contatori devono essere coerenti con la progressione
qualitativa da baseline a deny e allow selettiva. Il controllo legge gli
artefatti Felix senza generare traffico; gli esiti applicativi usati per il
risultato restano 6/6 consentiti, 6/6 negati e quindi 4/6 consentiti nella
singola esecuzione della matrice per stato. L'enforcement osservato è attribuito
al calculation graph e a Felix.

#### Baseline ripristinata: 6/6 connessioni consentite

Rimuovere entrambe le policy e attendere che il controllo in sola lettura non
trovi più i linkage di policy:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
wait_for_calico_policy_convergence restored
```

Se il controllo di convergenza fallisce, fermarsi. Quando termina
correttamente:

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

E01 ha mostrato bridge e VXLAN di Flannel; E10 ha aggiunto routing per
workload e policy Calico. E20 mantiene un tunnel VXLAN, ma introduce eBPF nel
data plane e Hubble come osservatore dei flussi. L'obiettivo è seguire
concretamente endpoint, hook, route, Service e policy per capire dove eBPF
entra nel percorso, senza dedurlo dalla sola configurazione.

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

Eseguire direttamente lint e rendering con il file valori pubblico:

```bash
sed -n '1,260p' manifests/cni/cilium/values.yaml

helm lint "$E20_DIR/cilium-1.19.6.tgz" \
  --values manifests/cni/cilium/values.yaml

helm template cilium "$E20_DIR/cilium-1.19.6.tgz" \
  --namespace kube-system \
  --values manifests/cni/cilium/values.yaml \
  --kube-version 1.34.9 \
  --output-dir "$E20_DIR/rendered"
```

Nel file cercare immagini con digest, CNI esclusivo, Cluster Pool IPAM `/24`,
`routingMode: tunnel`, `tunnelProtocol: vxlan`, data path veth, root bpffs,
`kubeProxyReplacement: "false"`, Hubble locale abilitato e Relay disabilitato.

Elencare i manifest prodotti e le immagini dei workload principali:

```bash
find "$E20_DIR/rendered" -type f -print
grep -R -nE \
  '^kind: (DaemonSet|Deployment)|^[[:space:]]+name:|^[[:space:]]+image:' \
  "$E20_DIR/rendered"
grep -R -nE '^[[:space:]]+image:.*:latest' \
  "$E20_DIR/rendered" || true
```

Controllare un DaemonSet `cilium`, un Deployment `cilium-operator` e immagini
bloccate; l'ultima ispezione deve restare vuota. Relay, interfaccia grafica
Hubble, Envoy separato e altri workload esclusi dai values non devono
comparire. Il rendering usa lo stesso namespace e lo stesso file `values.yaml`
che verranno passati all'installazione.

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

Prima di generare traffico verifichiamo che tutti gli agent Cilium siano
operativi e che il data plane non sia degradato. Il rollout del DaemonSet
dispone degli stessi 600 secondi validati, sufficienti anche per bootstrap e
pull iniziali con cache fredda; i nodi conservano il timeout di 300 secondi.

```bash
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=300s
kubectl --context "$TESI_CONTEXT" rollout status \
  daemonset/cilium -n kube-system --timeout=600s

kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get daemonset -n kube-system cilium
kubectl --context "$TESI_CONTEXT" get deployment -n kube-system cilium-operator
kubectl --context "$TESI_CONTEXT" get ciliumnodes -o yaml
```

Non proseguire se un wait fallisce. Il DaemonSet deve mostrare
`DESIRED=3`, `CURRENT=3`, `READY=3` e `AVAILABLE=3`; l'Operator deve essere
disponibile. Individuare quindi l'agent di `agent-0` e interrogare direttamente
stato Cilium, endpoint correnti e socket Hubble locale:

```bash
export CILIUM_AGENT0="$(
  kubectl --context "$TESI_CONTEXT" get pods \
    -n kube-system -l k8s-app=cilium \
    --field-selector spec.nodeName=k3d-tesi-e20-cilium-vxlan-agent-0 \
    -o jsonpath='{.items[0].metadata.name}'
)"
printf 'CILIUM_AGENT0=%s\n' "$CILIUM_AGENT0"
```

Se il nome è vuoto o non identifica un singolo Pod Cilium, fermarsi. Usare
quindi l'agent scoperto per i comandi di osservazione:

```bash
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg status --verbose
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg endpoint list
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- hubble status \
  --server unix:///var/run/cilium/hubble.sock
```

`cilium-dbg status --verbose` deve riportare agent e controller sani,
`KubeProxyReplacement: False` e Hubble locale disponibile. Le **mappe eBPF**
sono strutture del kernel usate da Cilium per endpoint, policy, load balancing
e conntrack; Hubble legge la telemetria prodotta dal data plane senza un Relay.

Ispezionare ora CNI, interfacce, route e tunnel in ogni namespace nodo:

```bash
for node in \
  k3d-tesi-e20-cilium-vxlan-server-0 \
  k3d-tesi-e20-cilium-vxlan-agent-0 \
  k3d-tesi-e20-cilium-vxlan-agent-1
do
  docker exec "$node" sh -c \
    'test -d /etc/cni/net.d && ls -la /etc/cni/net.d && test -r /etc/cni/net.d/05-cilium.conflist && sed -n "1,240p" /etc/cni/net.d/05-cilium.conflist'
  docker exec "$node" ip -br link
  docker exec "$node" ip route
  docker exec "$node" ip -details link show cilium_vxlan
done

kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- bpftool net
```

Fermarsi se un comando di inventario fallisce. Cercare blocchi IPAM `/24`,
`05-cilium.conflist`, bpffs, `cilium_vxlan`, route remote e attach TCX/eBPF
nell'output di `bpftool net`. Flannel e il controller policy K3s devono essere
assenti; kube-proxy deve restare presente.

### 11.4 Workload e percorso intra-node

Applicare il workload comune senza eseguire una matrice preliminare. La sola
baseline NetworkPolicy di riferimento verrà generata nella sezione 11.7 come
traffico diretto Pod-to-Pod, dentro una finestra Hubble congelata:

```bash
deploy_common_workload

export CLIENT_IP="$(
  kubectl --context "$TESI_CONTEXT" -n net-lab get pod client \
    -o jsonpath='{.status.podIP}'
)"
export SERVER_A_IP="$(
  kubectl --context "$TESI_CONTEXT" -n net-lab get pod server-a \
    -o jsonpath='{.status.podIP}'
)"
export SERVER_B_IP="$(
  kubectl --context "$TESI_CONTEXT" -n net-lab get pod server-b \
    -o jsonpath='{.status.podIP}'
)"
export SERVICE_IP="$(
  kubectl --context "$TESI_CONTEXT" -n net-lab get svc servers \
    -o jsonpath='{.spec.clusterIP}'
)"

printf 'CLIENT_IP=%s SERVER_A_IP=%s SERVER_B_IP=%s SERVICE_IP=%s\n' \
  "$CLIENT_IP" "$SERVER_A_IP" "$SERVER_B_IP" "$SERVICE_IP"
```

I quattro valori devono essere indirizzi IPv4 non vuoti. In caso contrario,
fermarsi prima dei comandi di osservazione e degli esperimenti di traffico.

```bash
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
kubectl --context "$TESI_CONTEXT" get ciliumendpoint \
  -n net-lab client server-a server-b -o wide
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg endpoint list
```

Per Cilium ogni workload Kubernetes è rappresentato anche come endpoint del
data plane, con identity, stato e revisione policy. Correlare nome e IP del Pod
con il `CiliumEndpoint`; quindi leggere l'endpoint `client`, la route locale e
gli attach eBPF:

```bash
export CLIENT_ENDPOINT_ID="$(
  kubectl --context "$TESI_CONTEXT" get ciliumendpoint -n net-lab client \
    -o jsonpath='{.status.id}'
)"
printf 'CLIENT_ENDPOINT_ID=%s\n' "$CLIENT_ENDPOINT_ID"
```

L'endpoint ID deve essere un intero positivo. Se è vuoto o non valido,
fermarsi prima di interrogare il data plane.

```bash
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg endpoint get "$CLIENT_ENDPOINT_ID"
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- ip route get "$SERVER_A_IP"
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- ip route get "$SERVER_B_IP"
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- bpftool net
```

Il percorso da riconoscere è:

```text
Pod → veth lxc* → hook TCX/eBPF → data plane Cilium
```

Nell'endpoint cercare l'interfaccia `lxc*` e l'identity; in
`bpftool net` cercare l'attach TCX e il programma `cil_from_container` sulla
stessa interfaccia. Per il flusso locale la route passa nel data plane Cilium
senza usare il tunnel fra `client` e `server-a`; la seconda query mostra invece
la route scelta verso il Pod remoto `server-b`, che verrà correlata alla
cattura VXLAN successiva.

### 11.5 Cattura inter-node

Come in E01 ed E10 distinguiamo percorso locale e inter-node; in E20, però,
anche la decisione e l'osservazione del traffico attraversano il data plane
eBPF. Il percorso remoto atteso è
`lxc* → hook eBPF → cilium_vxlan → eth0`. Entriamo nel namespace del nodo
sorgente per correlare la vista inner fra Pod con la vista outer VXLAN fra gli
underlay.

```bash
export SOURCE_NODE='k3d-tesi-e20-cilium-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-e20-cilium-vxlan-agent-1'
export SOURCE_PID="$(
  docker inspect -f '{{.State.Pid}}' "$SOURCE_NODE"
)"
export SOURCE_UNDERLAY="$(
  docker inspect \
    -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
    "$SOURCE_NODE"
)"
export DESTINATION_UNDERLAY="$(
  docker inspect \
    -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
    "$DESTINATION_NODE"
)"
export CAPTURE_DIR="$(mktemp -d)"

printf 'SOURCE_PID=%s SOURCE_UNDERLAY=%s DESTINATION_UNDERLAY=%s\n' \
  "$SOURCE_PID" "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY"
```

Il PID deve essere positivo e gli underlay devono essere indirizzi IPv4
correnti e distinti. Se un valore è vuoto o non valido, fermarsi. Ispezionare
quindi il tunnel nel namespace sorgente:

```bash
sudo /usr/bin/nsenter --target "$SOURCE_PID" --net \
  /usr/sbin/ip -details link show cilium_vxlan
```

La cattura `-i any` mostra due viste dello stesso stimolo HTTP `client →
server-b`:

- inner: IP dei Pod e TCP/8080;
- outer: IP underlay e UDP 8472 su `cilium_vxlan`.

Il filtro completo e il singolo stimolo restano visibili; l'helper gestisce
timeout, sincronizzazione e terminazione di `tcpdump`:

```bash
sudo -v
TCPDUMP_FILTER="((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 8472))"
run_dual_view_capture \
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
```

Se l'helper fallisce, non proseguire. Dopo il successo leggere cattura e
risposta separata:

```bash
sed -n '1,360p' "$CAPTURE_DIR/cilium-inter-node.log"
cat "$CAPTURE_DIR/http-client.log"
```

Correlare `lxc*`, `cilium_vxlan` ed `eth0`, gli IP Pod nella vista inner e UDP
8472 fra gli underlay nella vista outer. In questa configurazione il VNI non è
un valore fisso da hardcodare: coincide con la security identity della
sorgente osservata a runtime. `tcpdump` può mostrarlo come `OTV instance`, che
non significa assenza del VNI. Nelle
[evidenze E20 pubblicate](../experiments/cni/e20-cilium-vxlan/evidence/) i
valori osservati coincidono con le security identity delle rispettive
sorgenti; in una nuova replica devono essere rilevati nuovamente.

Per la cattura sono accettati exit code `0`, `124` o `143`; gli altri indicano
un errore da diagnosticare.

`CAPTURE_DIR` va conservata in caso di errore. Dopo un esito positivo può
essere rimossa con `rm -rf -- "$CAPTURE_DIR"`.

### 11.6 Service B02: attribuzione eBPF controllata

Nel profilo Cilium 1.19.6 studiato, `kubeProxyReplacement=false` mantiene
kube-proxy ma non dimostra che Cilium sia assente dal percorso Service. B02
confronta nella stessa esecuzione mappe load balancer e conntrack eBPF, flussi
Hubble e contatori iptables kube-proxy. La sola presenza di uno di questi
artefatti non basta per attribuire le sei connessioni generate.

Le evidence originali E20 appartengono a una sessione precedente che applicava
lo stesso metodo a due connessioni. B02 è stato successivamente rafforzato con
sei connessioni nella procedura corrente; gli output storici non sono stati
riscritti e non vanno interpretati come se contenessero i sei flussi correnti.

Il runner [`scripts/cni/cilium/service.sh`](../scripts/cni/cilium/service.sh)
mantiene l'ordine della misurazione e usa i comandi seguenti, riportati per
rendere esplicito cosa viene osservato:

```text
kubectl --context "$TESI_CONTEXT" get endpointslice \
  -n net-lab -l kubernetes.io/service-name=servers
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

La sequenza di misurazione è:

```text
EndpointSlice Ready
    ↓
kube-proxy BEFORE + BPF LB frontend/backend/RevNAT + CT BEFORE
    ↓
START_UTC → esattamente 6 connessioni → END_UTC
    ↓
CT AFTER + kube-proxy AFTER + Hubble nella finestra congelata
    ↓
backend osservato e verifica dell'invarianza kube-proxy
```

Le mappe LB devono contenere frontend `$SERVICE_IP:8080`, backend e RevNAT.
Il confronto CT considera soltanto le nuove entry `TCP SVC` e le correla alle
entry `TCP OUT`, alle risposte HTTP e ai backend ID. Hubble rilegge la finestra
assoluta `START_UTC`/`END_UTC` senza produrre altro traffico.

La relazione causale attesa è:

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

Eseguire l'attribuzione una sola volta; non rilanciarla per ottenere una
distribuzione diversa fra i backend:

```bash
export CILIUM_NODE='k3d-tesi-e20-cilium-vxlan-agent-0'
export SERVICE_DIR="$(mktemp -d)"
export CILIUM_SERVICE_HUBBLE_TIMEOUT=20

run_e20_service_attribution
```

Il runner mostra risposte, correlazione CT/LB e diff informative. Ispezionare
anche l'osservazione Hubble conservata, che include finestra, sorgente,
destinazione, protocollo e verdict; l'agent di origine è
`$CILIUM_AGENT0`, come mostra il comando:

```bash
ls -la "$SERVICE_DIR"
sed -n '1,160p' "$SERVICE_DIR/hubble-service.json"
```

Il risultato è positivo se compaiono nuove entry CT coerenti con backend e
reverse Network Address Translation (RevNAT), correlazione Hubble e nessun
delta nei contatori kube-proxy pertinenti. La distribuzione dei backend non è
un criterio. La conclusione vale soltanto per questi sei flussi e non implica
che kube-proxy sia globalmente inattivo.

Il confronto con B01 è quindi circoscritto ai profili testati:

```text
E10 / Calico: Service → kube-proxy → KUBE-SVC/KUBE-SEP → DNAT
E20 / Cilium 1.19.6: Service → BPF LB/CT + RevNAT → Hubble
                      mentre i contatori kube-proxy osservati restano invariati
```

### 11.7 Matrice NetworkPolicy

Il protocollo mantiene separati quattro passaggi: mutazione della NetworkPolicy,
convergenza del policy plane Cilium, una sola matrice HTTP usata per il
risultato e osservazione del data plane. La relazione verificata per ogni stato
è:

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

I due moduli Cilium gestiscono polling, finestre temporali e raccolta
multi-agent. Caricarli dopo i moduli comuni già importati all'inizio di E20:

```bash
source scripts/cni/cilium/policy-observers.sh
source scripts/cni/cilium/network-policy.sh

export POLICY_DIR="$(mktemp -d)"
export CILIUM_POLICY_TIMEOUT=120
export CILIUM_HUBBLE_TIMEOUT=20
```

Le evidence storiche E20 conservano i tre stati baseline, default deny e allow
selettiva. Il quarto passaggio `restored` verifica nella procedura corrente il
ritorno effettivo alla baseline e non costituisce una configurazione
sperimentale aggiuntiva.

`snapshot_cilium_policy_revisions` scopre placement, agent `Running`, Pod e
revisioni correnti. Nessun nome agent, endpoint ID, identity o BPF map ID
deriva dalle evidence storiche.

Dopo una mutazione, `wait_for_cilium_policy_convergence` usa un unico timeout
di 120 secondi. Per ogni agent richiede che la revisione sia avanzata,
che il documento importato contenga esattamente le policy previste dallo stato,
che `cilium-dbg policy wait` raggiunga la revisione e che tutti gli endpoint
workload locali siano `ready`, con revisione richiesta e realizzata coincidenti
e non inferiori al target. Il controllo non genera traffico e non richiama la
matrice HTTP.

Gli helper usano, per gli agent e gli intervalli scoperti a runtime, i comandi
di osservazione seguenti:

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
esegue una sola `run_policy_matrix`, congela `POLICY_UNTIL` e interroga Hubble
sulla stessa finestra assoluta RFC3339Nano. L'eventuale polling ripete soltanto
la lettura della finestra chiusa e non genera traffico workload.

Hubble deve interrogare separatamente tutti gli agent pertinenti perché i
workload non sono tutti sullo stesso nodo. L'aggregato conserva l'origine
dell'agent, evitando di attribuire un flusso al nodo sbagliato. Anche le BPF
policy map sono node-local: `capture_cilium_bpf_policy_maps` esegue
`cilium-dbg bpf policy get --all` per agent e mantiene il mapping con endpoint
e identity nei file per-agent e nell'indice aggregato.

#### Baseline: 6/6 connessioni consentite

La baseline parte senza NetworkPolicy. Acquisire lo snapshot di agent e
revisioni, quindi produrre l'unica matrice baseline E20:

```bash
snapshot_cilium_policy_revisions
capture_cilium_policy_state baseline allow-all
```

La seconda chiamata congela `POLICY_SINCE`, genera una sola matrice diretta fra
Pod IP, congela `POLICY_UNTIL` e raccoglie Hubble, API endpoint e BPF policy map
nella stessa finestra. B02 usa invece il ClusterIP e non viene riutilizzato
come baseline NetworkPolicy.

#### Default deny: 0/6 connessioni consentite

Registrare le revisioni precedenti, applicare la policy e attendere che agent
ed endpoint abbiano realizzato la nuova revisione:

```bash
snapshot_cilium_policy_revisions
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml
wait_for_cilium_policy_convergence default-deny
```

Se il controllo di convergenza fallisce, fermarsi senza generare traffico.
Quando termina correttamente:

```bash
capture_cilium_policy_state default-deny deny-all
```

#### Allow selettiva: 4/6 connessioni consentite

Ripetere snapshot, mutazione e controllo di convergenza prima dell'unica
matrice dello stato:

```bash
snapshot_cilium_policy_revisions
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml
wait_for_cilium_policy_convergence selective-allow
```

Se il controllo di convergenza fallisce, non proseguire. Quando termina
correttamente:

```bash
capture_cilium_policy_state selective-allow selective-allow
```

#### Stato ripristinato: 6/6 connessioni consentite

Rimuovere entrambe le policy e attendere revisione, stato semantico senza le
policy ed endpoint realization:

```bash
snapshot_cilium_policy_revisions
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found
wait_for_cilium_policy_convergence restored
```

Se il controllo di convergenza fallisce, fermarsi. Quando termina
correttamente, acquisire l'unica matrice finale e le stesse osservazioni
multi-agent:

```bash
capture_cilium_policy_state restored allow-all
ls -la "$POLICY_DIR"
```

Per ogni stato controllare:

- `<stato>-networkpolicy.yaml`, oggetti API;
- `<stato>-endpoints.yaml`, stato, identity e revisioni requested/realized;
- `<stato>-bpf-policy-<agent>.log`, policy map con origine per agent;
- `<stato>-bpf-policy.log`, indice multi-agent;
- `<stato>-hubble.json`, sorgente, destinazione, protocollo, verdict e agent
  nella finestra congelata.

La policy non è pronta solo perché l'oggetto API esiste: il controllo richiede
che la revisione globale/agent sia avanzata e che ogni endpoint abbia revisioni
requested e realized coincidenti e almeno pari al target. I verdict attesi
sono `FORWARDED` oppure `DROPPED` con
`drop_reason_desc=POLICY_DENIED`. Matrice, endpoint, BPF policy map e Hubble
attribuiscono insieme l'enforcement a Cilium/eBPF.

### 11.8 Interpretazione E20

L'inventario endpoint e `bpftool net` collega i Pod agli hook eBPF; route e
cattura collegano il percorso remoto a `cilium_vxlan`; B02 attribuisce i sei
flussi Service a LB/CT/RevNAT e Hubble, con contatori kube-proxy invariati; le
quattro matrici policy collegano invece API, revisioni realizzate, BPF policy
map e verdict Hubble. Le conclusioni restano circoscritte alla configurazione
Cilium 1.19.6 studiata.

### 11.9 Troubleshooting facoltativo: riavvio Docker

Questo controllo non è parte del percorso normale. Usarlo soltanto se, dopo
un riavvio Docker, i flussi intra-node funzionano ma quelli inter-node verso
`agent-1` falliscono.

```bash
export AGENT1_NODE='k3d-tesi-e20-cilium-vxlan-agent-1'
export AGENT1_UNDERLAY="$(
  docker inspect \
    -f '{{with index .NetworkSettings.Networks "k3d-tesi-e20-cilium-vxlan"}}{{.IPAddress}}{{end}}' \
    "$AGENT1_NODE"
)"
export CILIUM_AGENT1="$(
  kubectl --context "$TESI_CONTEXT" get pods \
    -n kube-system -l k8s-app=cilium \
    --field-selector spec.nodeName=k3d-tesi-e20-cilium-vxlan-agent-1 \
    -o jsonpath='{.items[0].metadata.name}'
)"

printf 'AGENT1_UNDERLAY=%s CILIUM_AGENT1=%s\n' \
  "$AGENT1_UNDERLAY" "$CILIUM_AGENT1"
```

Se l'underlay non è un IPv4 valido o il nome dell'agent è vuoto, fermarsi
prima del confronto facoltativo.

```bash
kubectl --context "$TESI_CONTEXT" get ciliumnode \
  k3d-tesi-e20-cilium-vxlan-agent-1 -o yaml
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg node list
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

### 11.10 Rimozione del cluster

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

Le query Hubble sono sincrone e non lasciano un Relay o un processo dedicato;
la terminazione di `tcpdump` è verificata da `run_dual_view_capture`. Se la
shell viene interrotta durante la cattura, diagnosticare l'eventuale processo
nel namespace del nodo prima di eliminare i file temporanei.

La rimozione deve riguardare solo E20. Non eliminare manualmente programmi o
mappe eBPF, route, regole netfilter o reti Docker senza avere prima dimostrato
un residuo specifico.

## 12. Chiusura del laboratorio e dati da conservare

### 12.1 Controllo conclusivo dell'host

Dopo avere eliminato E20, ispezionare direttamente le risorse che la guida può
avere lasciato sull'host:

```bash
k3d cluster list

docker ps -a \
  --filter 'name=k3d-tesi-' \
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}'

kubectl config get-contexts

ss -H -ltn \
  'sport = :6445 or sport = :6446 or sport = :6447 or sport = :6448 or sport = :6449'

pgrep -af tcpdump || true
pgrep -af hubble || true
pgrep -af kubectl || true
```

Al termine non devono rimanere cluster `tesi-*`, container `k3d-tesi-*`,
listener API sulle porte 6445–6449 o processi di cattura avviati dagli
esperimenti. `k3d cluster list` può mostrare la propria intestazione; gli
output filtrati di `docker ps` e `ss` devono essere vuoti. In
`kubectl config get-contexts` non devono restare contesti `k3d-tesi-*`.

Le query Hubble della guida sono sincrone. Se `pgrep` mostra `tcpdump`, Hubble
o `kubectl`, verificare la riga di comando e terminare soltanto processi
riconducibili a questo laboratorio. Non rimuovere cluster, container, contesti
o processi estranei soltanto perché compaiono negli inventari.

### 12.2 Directory temporanee

Le directory seguenti sono create con `mktemp -d`: contengono chart e
rendering Calico/Cilium, catture, snapshot Service e osservazioni policy. Prima
di cancellarle, copiarne gli output scelti come documentazione della replica.
Visualizzare i path ancora disponibili nella shell:

```bash
printf 'CALICO_CHART_DIR=%s\n' "${CALICO_CHART_DIR:-<non impostata>}"
printf 'CALICO_RENDER_DIR=%s\n' "${CALICO_RENDER_DIR:-<non impostata>}"
printf 'E20_DIR=%s\n' "${E20_DIR:-<non impostata>}"
printf 'CAPTURE_DIR=%s\n' "${CAPTURE_DIR:-<non impostata>}"
printf 'SERVICE_DIR=%s\n' "${SERVICE_DIR:-<non impostata>}"
printf 'POLICY_DIR=%s\n' "${POLICY_DIR:-<non impostata>}"
```

Verificare che ogni valore non vuoto sia il path `mktemp` creato nella sezione
pertinente. Rimuovere soltanto quelle directory esplicite ancora referenziate:

In ciascuna riga `test -z ... || rm -rf ...` esegue la rimozione solo quando la
variabile contiene un path non vuoto; un valore vuoto lascia quindi intatto il
filesystem.

```bash
test -z "${CALICO_CHART_DIR:-}" || rm -rf -- "$CALICO_CHART_DIR"
test -z "${CALICO_RENDER_DIR:-}" || rm -rf -- "$CALICO_RENDER_DIR"
test -z "${E20_DIR:-}" || rm -rf -- "$E20_DIR"
test -z "${CAPTURE_DIR:-}" || rm -rf -- "$CAPTURE_DIR"
test -z "${SERVICE_DIR:-}" || rm -rf -- "$SERVICE_DIR"
test -z "${POLICY_DIR:-}" || rm -rf -- "$POLICY_DIR"
```

Non usare wildcard su `/tmp` e non eliminare directory non mostrate dalla
shell. Se gli esperimenti sono stati eseguiti in shell diverse, i relativi
temporanei devono essere rimossi al termine della loro sezione usando il path
stampato in quella sessione.

### 12.3 Troubleshooting essenziale

Questa sezione è facoltativa: usarla soltanto quando il percorso normale ha
prodotto uno dei sintomi descritti.

#### Cluster, container o porta API ancora presenti

**Sintomo:** il controllo finale mostra un cluster `tesi-*`, un container
`k3d-tesi-*` o un listener su una porta 6445–6449.

**Cosa controllare:** correlare nome del cluster, container e porta senza
agire sulle altre risorse dell'host.

**Comandi:**

```bash
k3d cluster list
docker ps -a --filter 'name=k3d-tesi-' \
  --format '{{.Names}}\t{{.Status}}'
ss -H -ltnp \
  'sport = :6445 or sport = :6446 or sport = :6447 or sport = :6448 or sport = :6449'
```

**Cosa dovrebbe risultare:** dopo avere ripetuto il comando di delete della
sezione sperimentale interessata, i tre inventari non devono più mostrare la
risorsa. Non usare `docker rm` o `kill` su target non identificati.

#### Docker socket non accessibile

**Sintomo:** `docker info` restituisce `permission denied` su
`/run/docker.sock` dopo `usermod`.

**Cosa controllare:** gruppo della shell e proprietà del socket.

**Comandi:**

```bash
id -nG
stat -c '%a %U:%G %n' /run/docker.sock
docker info
```

**Cosa dovrebbe risultare:** i gruppi includono `docker`; il socket è
`root:docker` con modo `660`. Se la shell conserva i gruppi precedenti, fare
logout/login; per il solo controllo temporaneo usare
`sg docker -c 'docker version'`.

#### Nodi o CNI non convergenti

**Sintomo:** i nodi restano `NotReady` oppure Calico/Cilium non completano la
readiness entro il timeout documentato.

**Cosa controllare:** stato dei nodi, Pod ed eventi; per il CNI installato,
usare anche il relativo comando di osservazione già impiegato in E10 o E20.

**Comandi:**

```bash
kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get events -A \
  --sort-by=.lastTimestamp
```

Per Calico:

```bash
kubectl --context "$TESI_CONTEXT" get tigerastatus
```

Per Cilium, dopo avere rilevato nuovamente `CILIUM_AGENT0` come nella sezione
11.3:

```bash
kubectl --context "$TESI_CONTEXT" exec -n kube-system \
  "$CILIUM_AGENT0" -- cilium-dbg status --verbose
```

**Cosa dovrebbe risultare:** con `--flannel-backend=none`, `NotReady` prima
dell'installazione del CNI è transitorio. Dopo la convergenza tutti i nodi e i
componenti pertinenti devono essere disponibili. Eseguire soltanto il comando
di osservazione del CNI in uso; non aggiungere Flannel o un secondo plugin.

#### Identificativi cambiati dopo un riavvio

**Sintomo:** `nsenter`, una route o un filtro di cattura usa un PID, un IP o
un'interfaccia non più esistente.

**Cosa controllare:** rileggere placement, indirizzi e PID con gli stessi
comandi di acquisizione runtime della sezione interessata.

**Comandi:**

```bash
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
docker inspect -f '{{.State.Pid}}' "$SOURCE_NODE"
docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
  "$SOURCE_NODE"
```

**Cosa dovrebbe risultare:** i nuovi valori devono riferirsi ai container e
Pod correnti. Rigenerare tutte le variabili runtime; non correggere route o
stato CNI usando identificativi storici.

#### DNS influenzato da un search suffix

**Sintomo:** `servers.net-lab.svc.cluster.local` viene risolto verso un
indirizzo estraneo al cluster.

**Cosa controllare:** confrontare la risoluzione con e senza il punto finale.

**Comandi:**

```bash
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  nslookup servers.net-lab.svc.cluster.local
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  nslookup servers.net-lab.svc.cluster.local.
```

**Cosa dovrebbe risultare:** per la prova E01 usare il nome assoluto
`servers.net-lab.svc.cluster.local.` quando il resolver host introduce il
suffix inatteso.

#### Processo di cattura non terminato

**Sintomo:** `timeout` non termina la cattura oppure il controllo finale mostra
un processo diagnostico.

**Cosa controllare:** riga di comando, profilo di sicurezza della shell ed
eventuali dinieghi AppArmor.

**Comandi:**

```bash
pgrep -af tcpdump || true
pgrep -af hubble || true
pgrep -af kubectl || true
cat /proc/$$/attr/current
journalctl -k --grep='apparmor' --since='30 minutes ago'
```

**Cosa dovrebbe risultare:** dopo la cattura non devono restare processi
avviati dal laboratorio. Terminare soltanto il PID verificato. Se AppArmor
impedisce il segnale, usare un terminale non confinato compatibile oppure una
regola locale limitata ai segnali necessari; non disabilitare AppArmor.

#### Cilium dopo un riavvio Docker

**Sintomo:** in E20 i flussi intra-node funzionano ma quelli inter-node verso
`agent-1` falliscono dopo il riavvio di Docker.

**Cosa controllare:** underlay corrente, `CiliumNode`, node list e BPF IP
cache, usando gli identificativi rilevati nuovamente.

**Comandi:** eseguire esclusivamente il blocco diagnostico della sezione 11.9.

**Cosa dovrebbe risultare:** il tunnel endpoint deve coincidere con l'underlay
corrente. L'eventuale riallineamento documentato in 11.9 è facoltativo e vale
solo per questo sintomo; non fa parte della procedura normale e non dimostra
una proprietà generale di Cilium.

### 12.4 Dati da conservare

Per rendere riproducibile la configurazione, conservare:

- commit o tag della repository;
- versioni, chart, checksum e digest delle immagini;
- manifest e file values effettivamente utilizzati;
- comandi di creazione e configurazione dei cluster.

Per documentare una specifica esecuzione, conservare una selezione piccola ma
sufficiente a sostenere il risultato:

- stato di nodi, componenti, workload e allocazioni IPAM;
- route, interfacce, endpoint e output dei comandi di osservazione del data
  plane;
- catture pertinenti e risposte applicative tenute separate;
- snapshot BEFORE/AFTER dei Service e dei quattro stati NetworkPolicy;
- finestre Hubble, log di attribuzione ed esiti del cleanup;
- checksum dei file scelti come evidence della replica.

IP, PID, timestamp, veth, porte sorgenti, endpoint ID e identity sono dati
runtime temporanei: servono a correlare la singola esecuzione, ma possono
essere eliminati insieme alle directory `mktemp` dopo avere copiato le evidence
necessarie. Non devono coincidere byte per byte con le evidence storiche.

Non conservare kubeconfig, token, Secret o altre credenziali. I README degli
esperimenti collegano la selezione degli output originali pubblicati e i
relativi indici SHA-256; una nuova replica deve usare una directory di raccolta
propria senza modificare quelle evidence.
