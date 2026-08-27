# Manuale di riproduzione degli esperimenti CNI

## 1. Come usare questa guida

### 1.1 Ottenere la repository

La procedura richiede un account con `sudo` e accesso a Internet. Da una nuova
installazione Ubuntu 24.04 Noble o dal sistema compatibile di riferimento,
verificare `sudo` e installare Git se non è già disponibile:

```bash
sudo -v
if ! command -v git >/dev/null 2>&1
then
  sudo apt-get update
  sudo apt-get install -y git
fi
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

Per la validation immediata si può usare il branch corrente. Una riproduzione
destinata a essere archiviata o citata deve invece registrare un tag di
baseline o il commit restituito da `git rev-parse`; quando verrà pubblicato un
tag stabile, questo è il punto nel quale selezionarlo prima di proseguire.

### 1.2 Percorso della guida

Il manuale accompagna il lettore dalla preparazione di un host Linux alla
riproduzione di E01, E02, E10 ed E20. Preparazione e toolchain vanno eseguite
nell'ordine indicato; dopo le sezioni comuni ciascun esperimento può iniziare
dal proprio punto di ingresso. Salvo diversa indicazione, i comandi si
eseguono dalla radice della repository clonata. Ogni esperimento usa un
cluster distinto; eliminarlo al termine evita che interfacce, route o regole
residue influenzino il caso successivo.

La guida presenta la procedura consolidata necessaria a riprodurre
configurazioni, esperimenti, osservazioni e attribuzioni. Non ricostruisce la
cronologia delle sessioni di sviluppo o dei tentativi intermedi che non
influiscono sul risultato sperimentale.

Percorso di lavoro:

1. verificare la piattaforma e i comandi di sistema;
2. installare Docker Engine, kubectl, Helm e k3d;
3. controllare versioni, immagini e file bloccati;
4. definire le variabili e le funzioni comuni;
5. eseguire uno o più esperimenti dal relativo punto di ingresso;
6. controllare la rimozione dei cluster creati.

La configurazione sperimentale descritta è quella validata nel laboratorio.
La procedura pubblica è stata controllata staticamente, ma non è ancora stata
validata end-to-end su un secondo sistema pulito. Gli output indicati come
risultati appartengono agli esperimenti pubblicati e non vanno assunti come
esito di una nuova replica.

## 2. Ambiente di riferimento

La piattaforma validata era Zorin OS 18.1, basato su Ubuntu 24.04 Noble,
architettura `amd64`, kernel `7.0.0-28-generic`, control group v2 (cgroup v2)
e Berkeley Packet Filter filesystem (bpffs). La procedura Advanced Package
Tool (APT) seguente è scritta per Ubuntu Noble `amd64` e per il sistema
compatibile usato nel laboratorio. Altre distribuzioni Linux possono essere
compatibili, ma i loro comandi di installazione non sono stati verificati.

La macchina deve avere accesso a Internet per repository APT, registry delle
immagini, release binarie e chart Helm. Le catture richiedono `sudo` perché
entrano nel network namespace dei container nodo e aprono interfacce di rete.

## 3. Concetti pratici usati nel laboratorio

### Immagine container, tag e digest OCI

Un'immagine container contiene filesystem, metadati e configurazione necessari
per avviare un container. Docker la scarica da un registry; k3d usa immagini
K3s per creare i nodi e Kubernetes usa l'immagine BusyBox per i Pod del test.

Un **tag**, per esempio `rancher/k3s:v1.34.9-k3s1`, è un nome pubblicato nel
registry. Identifica una versione logica, ma il proprietario del repository
può associarlo in seguito a contenuto diverso. Un **digest Open Container
Initiative (OCI)**, per esempio `rancher/k3s@sha256:...`, identifica invece
uno specifico manifest pubblicato. Gli esperimenti usano il digest del
manifest `linux/amd64` per ridurre l'ambiguità.

Anche il checksum di un file può usare SHA-256, ma risponde a una domanda
diversa. Il digest OCI identifica un manifest o un'immagine nel registry;
`sha256sum file.tgz` verifica i byte di un file già scaricato. In questa guida
si usano entrambi e non sono intercambiabili.

### Helm, chart, values e post-renderer

Helm gestisce pacchetti di risorse Kubernetes. Un **chart Helm** contiene
template, metadati e valori predefiniti; un file `values.yaml` personalizza il
rendering. `helm template` genera localmente i manifest senza installarli e
permette quindi di ispezionare cosa verrebbe inviato al cluster.

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

Pod IP, ClusterIP dei Service, indirizzi underlay Docker, process identifier
(PID) dei nodi, sandbox, veth, porte TCP sorgenti e security identity possono
cambiare dopo una ricreazione o un riavvio. Non copiarli dagli output
pubblicati.
Le sezioni operative mostrano come rileggerli prima di ogni controllo.

## 4. Preparazione dell'host

Su Ubuntu 24.04 Noble o sul sistema compatibile di riferimento, installare i
pacchetti che forniscono le utility richieste:

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl git gpg file coreutils diffutils tar gzip grep sed mawk \
  tcpdump util-linux iproute2 iptables nftables procps kmod
```

Questo passaggio prepara utility di download e verifica, strumenti per
namespace e rete, diagnostica dei processi e ispezione del kernel. È un
prerequisito operativo della guida pubblica, non una variabile scientifica.
Il blocco APT fa parte della procedura da sottoporre alla validation
end-to-end.

Verificare sistema operativo, architettura, risorse e caratteristiche di base:

```bash
cat /etc/os-release
uname -srmo
dpkg --print-architecture
getconf LONG_BIT
test "$(dpkg --print-architecture)" = amd64 && printf 'PASS: architettura amd64\n'
test "$(getconf LONG_BIT)" -eq 64 && printf 'PASS: sistema a 64 bit\n'
nproc
free -h
df -h /
lsmod | grep -E '(^| )(br_netfilter|vxlan|overlay)( |$)' || true
sysctl net.ipv4.ip_forward
findmnt -T /sys/fs/cgroup
findmnt -T /sys/fs/bpf || true
stat -fc '%T %n' /sys/fs/cgroup
test "$(stat -fc '%T' /sys/fs/cgroup)" = cgroup2fs && \
  printf 'PASS: cgroup v2\n'
if test -r /sys/kernel/btf/vmlinux
then
  printf 'PASS: BTF disponibile\n'
else
  printf 'ATTENZIONE: BTF non rilevato; fermarsi prima di E20\n' >&2
fi
```

Il risultato deve indicare Ubuntu Noble o il sistema compatibile di
riferimento, `amd64`, 64 bit e `cgroup2fs` per `/sys/fs/cgroup`; fermarsi se
architettura o cgroup non corrispondono. L'assenza di un modulo da `lsmod` non
prova da sola un'incompatibilità: può essere integrato nel kernel o caricato al
primo uso. Il forwarding può essere ancora `0` prima dell'avvio di Docker, ma
deve risultare `1` nel controllo finale della toolchain; in caso contrario
fermarsi prima di creare cluster. Per E20 verificare inoltre BTF e, dopo
l'installazione di Cilium, il mount bpffs e i prerequisiti eBPF dentro i nodi.

Per questo laboratorio a tre nodi sono raccomandati operativamente almeno 4
thread CPU, 8 GiB di RAM e 20 GiB liberi. Non sono minimi ufficiali di
Kubernetes o Cilium: se la macchina offre meno risorse, ridurre il carico
estraneo o prevedere timeout e possibili mancate convergenze durante la
validation.

Controllare quindi tutte le utility richieste:

```bash
command -v gpg file sha256sum diff tar gzip grep sed awk
command -v tcpdump nsenter timeout ip bridge ss
command -v iptables nft pgrep lsmod sysctl
iptables --version
nft --version
```

Ogni chiamata a `command -v` deve produrre un percorso. Le sezioni successive
usano anche i percorsi assoluti previsti dai pacchetti Ubuntu Noble.

## 5. Installazione della toolchain

### 5.1 Docker Engine

La procedura usa il repository APT ufficiale Docker per Ubuntu Noble e rende
esplicite le versioni della baseline consolidata. Prima di configurarlo,
controllare senza rimuovere nulla se sono installati pacchetti che la
documentazione Docker considera confliggenti:

```bash
DPKG_PREFLIGHT_RC=0
if DPKG_INVENTORY="$(dpkg-query -W \
    -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>&1)"
then
  if DPKG_CONFLICTS="$(awk '
    $1 ~ /^(docker\.io|docker-compose|docker-compose-v2|docker-doc|docker-buildx|podman-docker|containerd|runc)(:[^[:space:]]+)?$/ &&
    $2 ~ /^ii/ { print; found=1 }
    END { exit !found }
  ' <<<"$DPKG_INVENTORY")"
  then
    DPKG_FILTER_RC=0
  else
    DPKG_FILTER_RC=$?
  fi
  case "$DPKG_FILTER_RC" in
    0)
      printf '%s\n' "$DPKG_CONFLICTS"
      printf 'STOP: pacchetti Docker confliggenti installati.\n' >&2
      DPKG_PREFLIGHT_RC=1
      ;;
    1)
      printf 'PASS: nessun pacchetto Docker confliggente installato.\n'
      ;;
    *)
      printf 'ERROR: filtro inventario dpkg fallito (awk rc=%s).\n' \
        "$DPKG_FILTER_RC" >&2
      DPKG_PREFLIGHT_RC=1
      ;;
  esac
else
  DPKG_RC=$?
  printf 'ERROR: interrogazione dpkg fallita (rc=%s):\n%s\n' \
    "$DPKG_RC" "$DPKG_INVENTORY" >&2
  DPKG_PREFLIGHT_RC=1
fi
unset DPKG_INVENTORY DPKG_CONFLICTS DPKG_FILTER_RC DPKG_RC
if [[ "$DPKG_PREFLIGHT_RC" -ne 0 ]]
then
  unset DPKG_PREFLIGHT_RC
  false
else
  unset DPKG_PREFLIGHT_RC
fi
```

L'esito atteso è `PASS: nessun pacchetto Docker confliggente installato` con
codice zero. Un inventario non leggibile produce `ERROR`; la presenza di uno
o più pacchetti elencati produce `STOP` e codice non-zero. In entrambi i casi
fermarsi prima dell'installazione: valutarne consapevolmente rimozione e dati
associati seguendo la documentazione Docker, senza cancellarli come effetto
automatico di questa guida.

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

Controllare origine e disponibilità dei pacchetti, poi simulare
l'installazione senza modificare l'host:

```bash
apt-cache policy \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin

apt-get --simulate install \
  docker-ce=5:29.6.2-1~ubuntu.24.04~noble \
  docker-ce-cli=5:29.6.2-1~ubuntu.24.04~noble \
  containerd.io=2.2.6-1~ubuntu.24.04~noble \
  docker-buildx-plugin=0.35.0-1~ubuntu.24.04~noble
```

I candidati devono provenire da `download.docker.com`, suite Noble, canale
stable, architettura `amd64`. Se una versione esatta non è più disponibile,
fermarsi e registrare la differenza: le versioni correnti del repository non
sostituiscono automaticamente quelle validate.

Installare i pacchetti esatti:

```bash
sudo apt-get install -y \
  docker-ce=5:29.6.2-1~ubuntu.24.04~noble \
  docker-ce-cli=5:29.6.2-1~ubuntu.24.04~noble \
  containerd.io=2.2.6-1~ubuntu.24.04~noble \
  docker-buildx-plugin=0.35.0-1~ubuntu.24.04~noble
```

Il laboratorio usa il daemon Docker di sistema e `docker buildx imagetools`.
Non usa Docker Compose né la modalità rootless; i relativi plugin non fanno
quindi parte della baseline consolidata.

Verificare pacchetti, servizi e socket:

```bash
dpkg-query -W \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin
systemctl is-active docker docker.socket containerd
systemctl is-enabled docker docker.socket containerd
stat -c '%a %U:%G %n' /run/docker.sock
docker --version
containerd --version
runc --version
docker buildx version
```

I servizi `docker` e `containerd` e il socket Docker devono essere attivi; il
socket deve appartenere a
`root:docker`. Dopo avere ottenuto l'accesso utente nella sezione successiva,
`docker info` dovrà riportare storage driver `overlayfs`, cgroup v2 e cgroup
driver `systemd`.

### 5.2 Accesso al daemon Docker

k3d deve raggiungere il daemon senza eseguire tutta la toolchain tramite
`sudo`. Aggiungere l'utente corrente al gruppo Docker:

```bash
sudo usermod -aG docker "$USER"
```

L'appartenenza al gruppo `docker` consente di avviare container privilegiati
e concede di fatto privilegi elevati sull'host. A questo punto effettuare
logout e login e **non proseguire nella vecchia shell**. Dopo il nuovo login,
tornare esplicitamente nella repository e verificare il nuovo gruppo:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
git status --short --branch
id -nG
docker version
docker info --format \
  'Server={{.ServerVersion}}; Driver={{.Driver}}; Cgroup={{.CgroupDriver}}; CgroupVersion={{.CgroupVersion}}'
```

Se il socket continua a restituire `permission denied`, non usare `sudo
docker` come soluzione permanente: controllare `id -nG`, chiudere la sessione
e accedere nuovamente.

Creare soltanto ora la directory temporanea usata per kubectl, Helm e k3d:

```bash
export TOOLCHAIN_DIR="$(mktemp -d)"
printf 'toolchain_dir=%s\n' "$TOOLCHAIN_DIR"
```

La directory appartiene a questa nuova sessione e non richiede di recuperare
variabili definite prima del logout.

### 5.3 kubectl

kubectl `v1.34.9` usa la stessa minor di Kubernetes/K3s del laboratorio. Si
scaricano binario e checksum pubblicato, poi si confrontano con il checksum
atteso:

```bash
export KUBECTL_FILE="$TOOLCHAIN_DIR/kubectl-v1.34.9-linux-amd64"
export KUBECTL_SHA256='73bb6f5063caadae1e73a39de018d8ad21755984bea35358484db817859e7634'

curl --fail --location --retry 3 \
  --output "$KUBECTL_FILE" \
  https://dl.k8s.io/release/v1.34.9/bin/linux/amd64/kubectl
curl --fail --location --retry 3 \
  --output "$TOOLCHAIN_DIR/kubectl.sha256" \
  https://dl.k8s.io/release/v1.34.9/bin/linux/amd64/kubectl.sha256

test "$(tr -d '[:space:]' < "$TOOLCHAIN_DIR/kubectl.sha256")" = \
  "$KUBECTL_SHA256"
printf '%s  %s\n' "$KUBECTL_SHA256" "$KUBECTL_FILE" | sha256sum --check -
file "$KUBECTL_FILE"
chmod 0755 "$KUBECTL_FILE"
"$KUBECTL_FILE" version --client -o yaml
```

Installare soltanto dopo il confronto positivo:

```bash
sudo install -o root -g root -m 0755 \
  "$KUBECTL_FILE" /usr/local/bin/kubectl
command -v kubectl
kubectl version --client -o yaml
sha256sum /usr/local/bin/kubectl
```

Il comando deve risolvere `/usr/local/bin/kubectl`, riportare `v1.34.9` e
conservare lo SHA-256 atteso.

### 5.4 Helm

Helm verrà usato per scaricare, renderizzare e installare i chart Calico e
Cilium. Scaricare e verificare la release `v3.21.3`:

```bash
export HELM_ARCHIVE="$TOOLCHAIN_DIR/helm-v3.21.3-linux-amd64.tar.gz"
export HELM_EXTRACT_DIR="$TOOLCHAIN_DIR/helm-v3.21.3-extract"
export HELM_ARCHIVE_SHA256='15e041a93a590dce8100f39385cd98c84a765c9e36aeeb9e2dc6ff9e4769e2e0'

curl --fail --location --retry 3 \
  --output "$HELM_ARCHIVE" \
  https://get.helm.sh/helm-v3.21.3-linux-amd64.tar.gz
printf '%s  %s\n' "$HELM_ARCHIVE_SHA256" "$HELM_ARCHIVE" | \
  sha256sum --check -
mkdir -p "$HELM_EXTRACT_DIR"
tar -xzf "$HELM_ARCHIVE" -C "$HELM_EXTRACT_DIR"
file "$HELM_EXTRACT_DIR/linux-amd64/helm"
"$HELM_EXTRACT_DIR/linux-amd64/helm" version --short
```

Installare e confrontare il binario sorgente con quello copiato:

```bash
sudo install -o root -g root -m 0755 \
  "$HELM_EXTRACT_DIR/linux-amd64/helm" /usr/local/bin/helm
command -v helm
helm version --short
sha256sum "$HELM_EXTRACT_DIR/linux-amd64/helm" /usr/local/bin/helm
```

Helm deve riportare `v3.21.3+g1ad6e68`; entrambi i binari devono avere
SHA-256 `46870487d8cbd7f304b93dc38bb6d91e4813d5c9bfab061538f474d775006f42`.

### 5.5 k3d

k3d crea cluster K3s i cui nodi sono container Docker. Il suo default K3s
incorporato non determina la versione degli esperimenti, perché ogni comando
di creazione passa esplicitamente l'immagine K3s bloccata.

```bash
export K3D_FILE="$TOOLCHAIN_DIR/k3d-v5.9.0-linux-amd64"
export K3D_SHA256='06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0'

curl --fail --location --retry 3 \
  --output "$K3D_FILE" \
  https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64
chmod 0755 "$K3D_FILE"
printf '%s  %s\n' "$K3D_SHA256" "$K3D_FILE" | sha256sum --check -
file "$K3D_FILE"
"$K3D_FILE" version

sudo install -o root -g root -m 0755 \
  "$K3D_FILE" /usr/local/bin/k3d
command -v k3d
k3d version
sha256sum "$K3D_FILE" /usr/local/bin/k3d
```

Il risultato deve indicare k3d `v5.9.0`; il default incorporato
`v1.35.5-k3s1` non verrà usato. Il binario installato deve conservare lo
SHA-256 atteso.

### 5.6 Verifica finale della toolchain

Al termine delle installazioni, eseguire il controllo complessivo:

```bash
id
id -nG
getent group docker
docker --version
docker info --format \
  'Server={{.ServerVersion}}; Driver={{.Driver}}; Cgroup={{.CgroupDriver}}; CgroupVersion={{.CgroupVersion}}'
kubectl version --client -o yaml
helm version --short
k3d version
lsmod | grep -E '(^| )(br_netfilter|vxlan|overlay)( |$)' || true
sysctl net.ipv4.ip_forward
test "$(sysctl -n net.ipv4.ip_forward)" -eq 1 && \
  printf 'PASS: forwarding IPv4 abilitato\n'
mount | grep -E 'cgroup2|bpf' || true
```

Verificare che l'utente appartenga al gruppo `docker`, che il daemon risponda
senza `sudo`, che usi `overlayfs`, cgroup v2 e driver `systemd`, e che le tre
Command Line Interface (CLI) riportino le versioni previste. Non devono
comparire errori evidenti del daemon e `net.ipv4.ip_forward` deve valere `1`;
se vale ancora `0`, fermarsi prima di creare cluster.

`TOOLCHAIN_DIR` serve soltanto durante la sezione 5. Dopo un esito positivo si
può eliminarla con il comando seguente; in caso di errore conservarla finché
non sono stati ispezionati file e checksum:

```bash
rm -rf -- "$TOOLCHAIN_DIR"
unset TOOLCHAIN_DIR KUBECTL_FILE KUBECTL_SHA256 \
  HELM_ARCHIVE HELM_EXTRACT_DIR HELM_ARCHIVE_SHA256 \
  K3D_FILE K3D_SHA256
```

## 6. Versioni, immagini e artefatti bloccati

| Componente | Versione o riferimento |
|---|---|
| Docker della baseline consolidata | `29.6.2` |
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.34.9+k3s1` |
| kubectl | `v1.34.9` |
| Helm | `v3.21.3` |
| BusyBox | `1.38.0` |
| Calico | `v3.32.1` |
| Cilium | `1.19.6` |

Docker era `29.6.2` in E01/E02, `29.7.1` in E10 e `29.7.2` in E20. La guida
propone `29.6.2` come baseline consolidata per la nuova riproduzione, senza
ricreare la cronologia degli aggiornamenti intermedi. La variazione delle
evidence originali resta una limitazione ambientale; l'equivalenza pratica
della baseline sarà valutata dalla futura validation end-to-end e non è qui
presentata come già confermata.

### 6.1 Immagine K3s

Il tag scelto era `docker.io/rancher/k3s:v1.34.9-k3s1`. L'indice OCI
multiarch osservato aveva digest
`sha256:9c162556657a38e394d1f944081388ae7c0b85ec29134c509583083e287f804e`;
il manifest `linux/amd64` usato dai nodi era:

```text
sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d
```

Ispezionare tag e manifest, quindi scaricare il digest effettivamente usato:

```bash
docker buildx imagetools inspect \
  docker.io/rancher/k3s:v1.34.9-k3s1
docker pull --platform linux/amd64 \
  docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d
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
docker buildx imagetools inspect docker.io/library/busybox:1.38.0
docker pull --platform linux/amd64 \
  docker.io/library/busybox@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8
docker image inspect \
  --format 'RepoDigests={{json .RepoDigests}}; OS={{.Os}}; Architecture={{.Architecture}}; Size={{.Size}}' \
  docker.io/library/busybox@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8
```

BusyBox fornisce `sh`, `sleep`, `httpd`, `ping`, `wget` e `nslookup`, cioè
gli strumenti minimi del workload. Il manifest comune conserva il digest e
non richiede di riscriverlo durante gli esperimenti.

Verificare infine file e script pubblici:

```bash
test -f manifests/cni/common/workload.yaml
test -f manifests/cni/common/default-deny-ingress.yaml
test -f manifests/cni/common/allow-client-to-http-servers.yaml
test -f manifests/cni/calico/tigera-operator-values.yaml
test -f manifests/cni/calico/imageset.yaml
test -f manifests/cni/calico/installation.yaml
test -f manifests/cni/cilium/values.yaml
test -f scripts/cni/common/lab-env.sh
test -x scripts/cni/calico/pin-tigera-operator-image.sh
```

## 7. Convenzioni e variabili comuni

All'inizio di una nuova shell, oppure prima di iniziare direttamente E01,
E02, E10 o E20, entrare nella root della repository e caricare l'ambiente
comune in una shell Bash:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
```

Lo script rileva e verifica la root, definisce l'immagine K3s bloccata e gli
helper comuni. Può essere caricato più volte: non crea cluster, non modifica il
sistema e non avvia test. Gli helper specifici di E02, E10 ed E20 restano nelle
relative sezioni e vengono definiti prima dell'uso.

Prima di creare un cluster, ogni esperimento invoca:

```text
check_experiment_preflight NOME_CLUSTER PORTA_API
```

I valori concreti sono già riportati nei punti di ingresso degli esperimenti,
quindi questa forma descrittiva non deve essere copiata. Il controllo si ferma
se trova lo stesso cluster, la porta occupata o un processo `tcpdump` residuo;
non elimina nulla. In quel caso scegliere se conservare e analizzare lo stato
esistente oppure eseguire consapevolmente la rimozione documentata per
l'esperimento precedente.

### 7.1 Workload e flussi comuni

Il workload colloca `client` e `server-a` su `agent-0`, e `server-b` su
`agent-1`. Ogni esperimento imposta `TESI_CONTEXT` e `TESI_NODE_PREFIX`, poi
invoca:

```bash
deploy_common_workload
```

Il manifest comune usa ora la label neutra `cni-network-baseline`. Le evidence
storiche restano byte-identiche e possono quindi mostrare il precedente valore
`e01-network-baseline`; la label non partecipa ai selector delle policy provate.

La funzione rifiuta di procedere se contesto o prefisso non sono definiti. Per
il Service, `verify_service_backends` controlla separatamente che `server-a` e
`server-b` siano entrambi Ready negli EndpointSlice; `service_http_flows N`
genera invece `N` nuove connessioni e registra il backend realmente osservato,
senza imporre una distribuzione probabilistica.

Per le connessioni dirette fra Pod, `http_flow` distingue gli errori locali e
di `kubectl exec` dall'esito di `wget`, e verifica che un flusso consentito
restituisca il nome del Pod destinazione. Le matrici usano `expect_allow` ed
`expect_deny`: un deny atteso viene registrato come `PASS` soltanto quando il
probe remoto è completo, `wget` restituisce il fallimento applicativo previsto
e un probe locale nel Pod destinazione conferma che il server HTTP è sano.
Scegliere una sola modalità per lo stato di policy corrente:

```text
run_policy_matrix MODALITA
```

Sostituire `MODALITA` con `allow-all`, `deny-all` oppure `selective-allow` in
base allo stato esplicitamente indicato nella sezione dell'esperimento. Le tre
modalità sono alternative e non vanno eseguite consecutivamente sullo stesso
stato.

Ogni matrice esegue due volte `client → server-a`, `client → server-b` e
`server-a → server-b`, poi stampa sei esiti e un riepilogo. Le forme
`allow-all`, `deny-all` e `selective-allow` corrispondono rispettivamente a
6/6 consentite, 6/6 negate e quattro consentite più due negate.

## 8. E01 — Flannel VXLAN

### 8.1 Creazione e controllo iniziale

Creiamo la baseline K3s con Flannel VXLAN, un server e due agent. La porta
API è esposta soltanto su loopback. Questo è il punto di ingresso E01 anche in
una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
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

Ispezionare contesto, readiness, CIDR dei nodi e componenti di sistema:

```bash
export TESI_CONTEXT='k3d-tesi-flannel-vxlan'
export TESI_NODE_PREFIX='k3d-tesi-flannel-vxlan'

kubectl config current-context
kubectl --context "$TESI_CONTEXT" cluster-info
kubectl --context "$TESI_CONTEXT" version -o yaml
k3d cluster list
docker ps --filter 'name=k3d-tesi-flannel-vxlan' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
docker port k3d-tesi-flannel-vxlan-serverlb
ss -ltn 'sport = :6445'
kubectl --context "$TESI_CONTEXT" get --raw='/readyz?verbose'
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=120s
kubectl --context "$TESI_CONTEXT" get nodes -o wide
kubectl --context "$TESI_CONTEXT" get pods -A -o wide
kubectl --context "$TESI_CONTEXT" get nodes \
  -o custom-columns=NAME:.metadata.name,POD_CIDR:.spec.podCIDR
```

### 8.2 CNI, subnet e data plane

Prima del workload distinguiamo configurazione CNI, subnet per nodo, bridge e
tunnel. Questi dati descrivono il data plane predisposto, ma non dimostrano
ancora il percorso di uno specifico pacchetto.

```bash
NODE_INVENTORY_FAILED=0
for NODE in \
  k3d-tesi-flannel-vxlan-server-0 \
  k3d-tesi-flannel-vxlan-agent-0 \
  k3d-tesi-flannel-vxlan-agent-1
do
  docker exec "$NODE" sh -c \
    'hostname; ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d /run/flannel' || \
    NODE_INVENTORY_FAILED=1
  docker exec "$NODE" sh -c \
    'hostname; sed -n "1,240p" /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist; sed -n "1,120p" /run/flannel/subnet.env' || \
    NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip -details address || NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip -details link show flannel.1 || \
    NODE_INVENTORY_FAILED=1
  docker exec "$NODE" sh -c \
    'hostname; ip route; ip neigh show dev flannel.1' || \
    NODE_INVENTORY_FAILED=1
done

kubectl --context "$TESI_CONTEXT" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" | backend="}{.metadata.annotations.flannel\.alpha\.coreos\.com/backend-type}{" | backend-data="}{.metadata.annotations.flannel\.alpha\.coreos\.com/backend-data}{" | public-ip="}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{" | podCIDR="}{.spec.podCIDR}{"\n"}{end}' || \
  NODE_INVENTORY_FAILED=1
if [[ "$NODE_INVENTORY_FAILED" -ne 0 ]]
then
  printf 'ERROR: inventario data plane E01 incompleto.\n' >&2
  unset NODE_INVENTORY_FAILED
  false
else
  unset NODE_INVENTORY_FAILED
fi
```

Controllare `cni0`, `flannel.1`, route verso le subnet remote e backend
`vxlan`. La configurazione presente non basta ancora a dimostrare che uno
specifico flusso usi il tunnel.

### 8.3 Workload e test

Con i valori già impostati, applicare il workload comune e rileggere gli
indirizzi:

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
printf 'client=%s server-a=%s server-b=%s service=%s\n' \
  "$CLIENT_IP" "$SERVER_A_IP" "$SERVER_B_IP" "$SERVICE_IP"
```

Verificare Internet Control Message Protocol (ICMP), HTTP intra-node e HTTP
inter-node:

```bash
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- sh -c \
  'ping -c 3 -W 2 "$1"; rc=$?; printf "exit_code=%s\n" "$rc"; exit "$rc"' \
  sh "$SERVER_A_IP" &&
http_flow client server-a &&
http_flow client server-b
```

Verificare prima che entrambi i backend siano Ready, poi generare connessioni
nuove. Le risposte registrano soltanto i backend effettivamente scelti; non è
richiesto che un numero finito di connessioni li selezioni entrambi. L'esito
prova il ClusterIP nei flussi osservati, ma non isola causalmente kube-proxy:

```bash
verify_service_backends &&
service_http_flows 6
```

Usare il nome assoluto, con il punto finale, per evitare che un search suffix
dell'host alteri la risoluzione:

```bash
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  nslookup servers.net-lab.svc.cluster.local. &&
kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
  wget -qO- -T 5 http://servers.net-lab.svc.cluster.local.:8080/
```

Il test conferma risoluzione DNS e raggiungibilità del Service nel caso
provato; non costituisce un'analisi generale del DNS del cluster.

### 8.4 Identificativi runtime, veth e cattura inter-node

Prima della cattura ricostruiamo l'associazione Pod–veth. La procedura individua
la sandbox tramite Container Runtime Interface (CRI) ed estrae il PID runtime
dalla chiave JSON esatta `pid`, così da non confonderlo con altri valori
numerici. Entra quindi nel namespace e usa l'ifindex peer di `eth0` per trovare
la veth nel nodo.

```bash
map_pod_veth() {
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: map_pod_veth POD NODO.\n' >&2
    return 2
  fi

  local POD_NAME="$1"
  local NODE_NAME="$2"
  local SANDBOX_IDS
  local SANDBOX_COUNT
  local SANDBOX_ID
  local SANDBOX_PID
  local POD_IP
  local POD_ETH0_LINK
  local PEER_IFINDEX
  local POD_LINK
  local POD_LINK_IP_RC
  local NODE_LINKS
  local VETH_MATCHES
  local VETH_COUNT

  SANDBOX_IDS="$(docker exec "$NODE_NAME" crictl pods \
    --name "^${POD_NAME}$" -q)" || return 1
  SANDBOX_COUNT="$(awk 'NF { count++ } END { print count + 0 }' \
    <<<"$SANDBOX_IDS")" || return 1
  if [[ "$SANDBOX_COUNT" -ne 1 ]]; then
    printf 'ERROR: attesa una sandbox per %s, trovate %s.\n' \
      "$POD_NAME" "$SANDBOX_COUNT" >&2
    return 1
  fi
  SANDBOX_ID="$(sed -n '/[^[:space:]]/p' <<<"$SANDBOX_IDS")" || return 1
  if [[ -z "$SANDBOX_ID" || "$SANDBOX_ID" == *$'\n'* || \
        ! "$SANDBOX_ID" =~ ^[[:alnum:]_.-]+$ ]]; then
    printf 'ERROR: sandbox ID non valido per %s.\n' "$POD_NAME" >&2
    return 1
  fi

  SANDBOX_PID="$(docker exec "$NODE_NAME" crictl inspectp \
    -o go-template --template '{{.info.pid}}' "$SANDBOX_ID")" || return 1
  if [[ ! "$SANDBOX_PID" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: PID sandbox non valido per %s: %q.\n' \
      "$POD_NAME" "$SANDBOX_PID" >&2
    return 1
  fi

  POD_IP="$(kubectl --context "$TESI_CONTEXT" get pod \
    -n net-lab "$POD_NAME" -o jsonpath='{.status.podIP}')" || return 1
  if ! _tesi_is_ipv4 "$POD_IP"; then
    printf 'ERROR: Pod IP non valido per %s: %q.\n' "$POD_NAME" "$POD_IP" >&2
    return 1
  fi
  POD_ETH0_LINK="$(docker exec "$NODE_NAME" nsenter \
    -t "$SANDBOX_PID" -n ip -o link show dev eth0)" || {
    printf 'ERROR: impossibile leggere eth0 nel namespace del Pod %s.\n' \
      "$POD_NAME" >&2
    return 1
  }
  if [[ -z "$POD_ETH0_LINK" || "$POD_ETH0_LINK" == *$'\n'* ]]; then
    printf 'ERROR: output eth0 vuoto o ambiguo per il Pod %s: %q.\n' \
      "$POD_NAME" "$POD_ETH0_LINK" >&2
    return 1
  fi
  if [[ "$POD_ETH0_LINK" =~ ^[[:space:]]*[1-9][0-9]*:[[:space:]]+eth0@if([1-9][0-9]*): ]]; then
    PEER_IFINDEX="${BASH_REMATCH[1]}"
  else
    printf 'ERROR: peer ifindex non estraibile da eth0 del Pod %s: %q.\n' \
      "$POD_NAME" "$POD_ETH0_LINK" >&2
    return 1
  fi
  if [[ ! "$PEER_IFINDEX" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: ifindex peer non valido per %s: %q.\n' \
      "$POD_NAME" "$PEER_IFINDEX" >&2
    return 1
  fi

  POD_LINK="$(docker exec "$NODE_NAME" nsenter -t "$SANDBOX_PID" -n \
    ip -br address show eth0)" || return 1
  if awk -v expected="$POD_IP" '
      {
        for (field=1; field<=NF; field++) {
          split($field, address, "/")
          if (address[1] == expected) { found=1 }
        }
      }
      END { exit !found }
    ' <<<"$POD_LINK"
  then
    POD_LINK_IP_RC=0
  else
    POD_LINK_IP_RC=$?
  fi
  case "$POD_LINK_IP_RC" in
    0) ;;
    1)
      printf 'ERROR: eth0 di %s non contiene il Pod IP %s.\n' \
        "$POD_NAME" "$POD_IP" >&2
      return 1
      ;;
    *)
      printf 'ERROR: parser indirizzi eth0 fallito per %s (awk rc=%s).\n' \
        "$POD_NAME" "$POD_LINK_IP_RC" >&2
      return 1
      ;;
  esac
  NODE_LINKS="$(docker exec "$NODE_NAME" ip -o link show)" || return 1
  VETH_MATCHES="$(awk -F': ' -v peer="$PEER_IFINDEX" \
    '$1 + 0 == peer { print }' <<<"$NODE_LINKS")" || return 1
  VETH_COUNT="$(awk 'NF { count++ } END { print count + 0 }' \
    <<<"$VETH_MATCHES")" || return 1
  if [[ "$VETH_COUNT" -ne 1 || \
        ! "$VETH_MATCHES" =~ ^[[:space:]]*[0-9]+:[[:space:]]+veth ]]; then
    printf 'ERROR: attesa una veth per %s/ifindex %s, trovate %s.\n' \
      "$POD_NAME" "$PEER_IFINDEX" "$VETH_COUNT" >&2
    return 1
  fi

  printf 'pod=%s node=%s pod_ip=%s sandbox=%s sandbox_pid=%s peer_ifindex=%s\n' \
    "$POD_NAME" "$NODE_NAME" "$POD_IP" "$SANDBOX_ID" \
    "$SANDBOX_PID" "$PEER_IFINDEX"
  printf '%s\n%s\n' "$POD_LINK" "$VETH_MATCHES"
}

map_pod_veth client k3d-tesi-flannel-vxlan-agent-0 &&
map_pod_veth server-a k3d-tesi-flannel-vxlan-agent-0 &&
map_pod_veth server-b k3d-tesi-flannel-vxlan-agent-1
```

Per ogni Pod controllare che `eth0` mostri il Pod IP corrente e che l'ultima
riga individui una sola veth del nodo. Questo controllo fa parte della
procedura da sottoporre alla validation end-to-end.

Per correlare il GET inter-node al traffico VXLAN UDP 8472, leggiamo poi PID
host dei nodi e indirizzi underlay correnti:

```bash
export SOURCE_NODE='k3d-tesi-flannel-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-flannel-vxlan-agent-1'
_tesi_export_runtime SOURCE_PID positive-integer docker inspect \
  -f '{{.State.Pid}}' "$SOURCE_NODE" &&
_tesi_export_runtime SOURCE_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-flannel-vxlan"}}{{.IPAddress}}{{end}}' \
  "$SOURCE_NODE" &&
_tesi_export_runtime DESTINATION_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-flannel-vxlan"}}{{.IPAddress}}{{end}}' \
  "$DESTINATION_NODE" &&
export CAPTURE_DIR="$(mktemp -d)" &&
printf 'pid=%s source_underlay=%s destination_underlay=%s capture_dir=%s\n' \
  "$SOURCE_PID" "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" "$CAPTURE_DIR" &&

sudo /usr/bin/nsenter --target "$SOURCE_PID" --net \
  /usr/sbin/bridge -d link show master cni0 &&
sudo /usr/bin/nsenter --target "$SOURCE_PID" --net /usr/sbin/ip -br link
```

La lista del bridge deve mostrare come porte di `cni0` le veth di `client` e
`server-a` appena ricostruite.

La cattura entra nel network namespace del nodo perché è lì che esistono
`cni0`, `flannel.1` ed `eth0`. `sudo` autorizza `nsenter` e l'apertura delle
interfacce; `-i any` mostra nello stesso intervallo le copie del pacchetto sui
diversi punti. Il filtro comprende sia HTTP fra i Pod sia VXLAN fra gli
indirizzi underlay. Avviare un solo GET ritardato e mantenere la cattura
limitata in primo piano:

```bash
sudo -v
(
  sleep 2
  http_flow client server-b
) >"$CAPTURE_DIR/http-client.log" 2>&1 &
export HTTP_JOB=$!

if sudo /usr/bin/env LC_ALL=C \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/timeout --verbose --foreground --preserve-status \
    --signal=TERM --kill-after=2s 8s \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 8472))" \
    >"$CAPTURE_DIR/flannel-inter-node.log" 2>&1
then
  export CAPTURE_RC=0
else
  export CAPTURE_RC=$?
fi
printf 'capture_exit=%s\n' "$CAPTURE_RC"
if wait "$HTTP_JOB"
then
  export HTTP_RC=0
else
  export HTTP_RC=$?
fi
printf 'http_exit=%s\n' "$HTTP_RC"

export CAPTURE_FAILED=0
case "$CAPTURE_RC" in
  0|124|143) ;;
  *) printf 'FAIL: terminazione inattesa della cattura\n' >&2; CAPTURE_FAILED=1 ;;
esac
if [[ "$HTTP_RC" -ne 0 ]]
then
  printf 'FAIL: richiesta HTTP della cattura fallita\n' >&2
  CAPTURE_FAILED=1
fi
if ! verify_no_tcpdump_processes
then
  CAPTURE_FAILED=1
fi
if ! verify_dual_view_capture \
    "$CAPTURE_DIR/flannel-inter-node.log" \
    "$CLIENT_IP" "$SERVER_B_IP" \
    "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 8472
then
  CAPTURE_FAILED=1
fi

if [[ "$CAPTURE_FAILED" -ne 0 ]]
then
  printf 'STOP: cattura E01 non valida; nessuna analisi successiva eseguita.\n' >&2
  false
else
  sed -n '1,260p' "$CAPTURE_DIR/flannel-inter-node.log" &&
    cat "$CAPTURE_DIR/http-client.log"
fi
```

Ispezionare il GET con IP dei Pod e i datagrammi VXLAN fra gli IP underlay;
la porta di destinazione deve essere 8472 e il VNI 1. L'eventuale codice di
terminazione di `timeout` non descrive l'esito HTTP: i due output restano
separati. `0` indica chiusura gestita da `tcpdump`; `124` o `143` indicano la
terminazione temporizzata accettata. Ogni altro codice arresta il blocco.

`CAPTURE_DIR` conserva i due output per l'ispezione. Dopo un esito positivo può
essere eliminata con `rm -rf -- "$CAPTURE_DIR"`; in caso di errore conservarla
temporaneamente per la diagnosi.

### 8.5 Rimozione del cluster

```bash
k3d cluster delete tesi-flannel-vxlan
k3d cluster list
ss -ltn 'sport = :6445'
```

## 9. E02 — attribuzione delle NetworkPolicy nello stack K3s

E02 confronta due cluster equivalenti: controller NetworkPolicy K3s attivo
(ON) e disabilitato (OFF). La domanda è se il comportamento NetworkPolicy
osservato dipenda da Flannel oppure da un componente separato dello stack
K3s. Eseguire i cluster in sequenza per evitare ambiguità.

Questo è il punto di ingresso E02 anche in una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
```

La matrice comprende `client → server-a`, `client → server-b` e
`server-a → server-b`, con due nuove connessioni per ogni flusso. La funzione
`run_policy_matrix` della sezione 7.1 esegue esplicitamente le sei richieste e
verifica il risultato atteso.

Per capire se una policy è stata tradotta nel data plane, leggiamo i log del
controller e cerchiamo catene iptables e insiemi IPSet con prefisso `KUBE-`.
La funzione usa il prefisso nodo del cluster corrente:

```bash
inspect_k3s_policy_plane() {
  local FAILED=0
  local FILTER_RC
  local IPSET_OUTPUT
  local IPTABLES_OUTPUT
  local LOG_OUTPUT

  for NODE in \
    "${TESI_NODE_PREFIX}-server-0" \
    "${TESI_NODE_PREFIX}-agent-0" \
    "${TESI_NODE_PREFIX}-agent-1"
  do
    if LOG_OUTPUT="$(docker logs "$NODE" 2>&1)"
    then
      if /usr/bin/grep -E \
          'Starting network policy controller|network_policy_controller' \
          <<<"$LOG_OUTPUT"
      then
        FILTER_RC=0
      else
        FILTER_RC=$?
      fi
      case "$FILTER_RC" in
        0) ;;
        1) printf 'INFO: marker controller policy assente su %s.\n' "$NODE" ;;
        *) printf 'ERROR: filtro log policy fallito su %s (grep rc=%s).\n' \
             "$NODE" "$FILTER_RC" >&2; FAILED=1 ;;
      esac
    else
      printf 'ERROR: acquisizione log policy fallita su %s.\n' "$NODE" >&2
      FAILED=1
    fi

    docker exec "$NODE" /bin/aux/iptables --version || FAILED=1
    docker exec "$NODE" /bin/ipset --version || FAILED=1

    if IPTABLES_OUTPUT="$(docker exec "$NODE" \
        /bin/aux/iptables-save -c)"
    then
      if /usr/bin/grep -E 'KUBE-(NWPLCY|POD-FW|ROUTER)' \
          <<<"$IPTABLES_OUTPUT"
      then
        FILTER_RC=0
      else
        FILTER_RC=$?
      fi
      case "$FILTER_RC" in
        0) ;;
        1) printf 'INFO: catene policy KUBE assenti su %s.\n' "$NODE" ;;
        *) printf 'ERROR: filtro iptables fallito su %s (grep rc=%s).\n' \
             "$NODE" "$FILTER_RC" >&2; FAILED=1 ;;
      esac
    else
      printf 'ERROR: acquisizione iptables fallita su %s.\n' "$NODE" >&2
      FAILED=1
    fi

    if IPSET_OUTPUT="$(docker exec "$NODE" /bin/ipset save)"
    then
      if /usr/bin/grep -E 'KUBE-' <<<"$IPSET_OUTPUT"
      then
        FILTER_RC=0
      else
        FILTER_RC=$?
      fi
      case "$FILTER_RC" in
        0) ;;
        1) printf 'INFO: IPSet policy KUBE assenti su %s.\n' "$NODE" ;;
        *) printf 'ERROR: filtro IPSet fallito su %s (grep rc=%s).\n' \
             "$NODE" "$FILTER_RC" >&2; FAILED=1 ;;
      esac
    else
      printf 'ERROR: acquisizione IPSet fallita su %s.\n' "$NODE" >&2
      FAILED=1
    fi
  done

  [[ "$FAILED" -eq 0 ]]
}
```

### 9.1 Controllo ON

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

Applicare il workload con il blocco della sezione 7.1. La baseline, senza
NetworkPolicy, deve consentire tutte le sei connessioni:

```bash
deploy_common_workload &&
run_policy_matrix allow-all &&
inspect_k3s_policy_plane
```

Applicare il default deny, controllare l'oggetto API ed eseguire di nuovo la
matrice:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml &&
kubectl --context "$TESI_CONTEXT" get networkpolicy \
  default-deny-ingress -n net-lab -o yaml &&
run_policy_matrix deny-all &&
inspect_k3s_policy_plane
```

Le sei connessioni devono fallire, mentre i Pod restano `Ready`. Catene,
IPSet e contatori devono mostrare la traduzione del deny.

Applicare quindi l'allow mirata e ripetere la matrice:

```bash
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml &&
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml &&
run_policy_matrix selective-allow &&
inspect_k3s_policy_plane
```

Devono riuscire quattro richieste dal client e fallire le due da `server-a`.
Gli artefatti kernel devono essere coerenti con l'allow selettiva. Rimuovere
quindi entrambe le policy e richiedere il ripristino della matrice baseline:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found &&
run_policy_matrix allow-all &&
inspect_k3s_policy_plane
```

Il controllo ON è causalmente valido soltanto se anche questo ripristino
riesce. Terminare quindi il cluster:

```bash
kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
k3d cluster delete tesi-e02-flannel-netpol-on
```

### 9.2 Controllo OFF

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

Applicare il workload con la sezione 7.1. Poiché il controller è disabilitato,
in tutti e tre gli stati l'esito atteso resta `allow-all`:

```bash
deploy_common_workload &&

# Baseline senza policy
run_policy_matrix allow-all &&
inspect_k3s_policy_plane &&

# Default deny dichiarato nell'API
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml &&
kubectl --context "$TESI_CONTEXT" get networkpolicy \
  default-deny-ingress -n net-lab -o yaml &&
run_policy_matrix allow-all &&
inspect_k3s_policy_plane &&

# Default deny più allow selettiva
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml &&
kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml &&
run_policy_matrix allow-all &&
inspect_k3s_policy_plane
```

Nel caso OFF gli oggetti API devono essere presenti, ma tutte le 18
connessioni devono riuscire. I dump policy-specifici devono rimanere invariati
e i log dei tre nodi non devono mostrare l'avvio del controller. Questo
controllo separa l'API dichiarativa dall'enforcement e attribuisce il
comportamento del caso ON al controller K3s basato su kube-router, non a
Flannel.

Per rendere confrontabili gli snapshot dei tre stati, salvare integralmente
gli output dei comandi mostrati e documentare qualunque normalizzazione dei
campi effimeri prima di usare un confronto byte per byte. Prima del cleanup,
rimuovere le due NetworkPolicy e verificare nuovamente `allow-all`:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found &&
run_policy_matrix allow-all &&
inspect_k3s_policy_plane
```

La rimozione successiva elimina il cluster dedicato.

```bash
k3d cluster delete tesi-e02-flannel-netpol-off
k3d cluster list
ss -ltn 'sport = :6446 or sport = :6447'
```

## 10. E10 — Calico VXLAN con data plane Linux

Questo è il punto di ingresso E10 anche in una nuova shell:

```bash
cd "$HOME/kubernetes-cloud-edge-lab"
source scripts/cni/common/lab-env.sh
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

Gli hash devono coincidere esattamente con i checksum attesi.
In caso contrario non installare i chart: una nuova pubblicazione con la
stessa versione non può essere assunta equivalente. Prima di creare il
cluster controlliamo inoltre rendering, valori finali e pin dell'immagine
operator.

```bash
export CALICO_RENDER_DIR="$(mktemp -d)"
export CALICO_OPERATOR_RENDERED="$CALICO_RENDER_DIR/tigera-operator-rendered.yaml"

render_calico_static() {
  local AWK_RC
  local FILTER_RC
  local PINNED_IMAGE_COUNT
  local PINNED_OPERATOR_IMAGE='quay.io/tigera/operator@sha256:9ca16aacd5676df68535e08e77529f6c1988ffecbff451e0ff5777e1b126dd91'
  local TAGGED_OPERATOR_IMAGE='quay.io/tigera/operator:v1.42.3'

  if ! helm template calico-crds "$CALICO_CRD_CHART" \
      --output-dir "$CALICO_RENDER_DIR"
  then
    printf 'ERROR: rendering statico delle CRD Calico fallito.\n' >&2
    return 1
  fi

  if ! helm template calico "$CALICO_OPERATOR_CHART" \
      --namespace tigera-operator \
      --values manifests/cni/calico/tigera-operator-values.yaml \
      --no-hooks \
      --post-renderer scripts/cni/calico/pin-tigera-operator-image.sh \
      >"$CALICO_OPERATOR_RENDERED"
  then
    printf 'ERROR: rendering statico Calico fallito.\n' >&2
    return 1
  fi
  if [[ ! -s "$CALICO_OPERATOR_RENDERED" ]]
  then
    printf 'FAIL: rendering Tigera Operator vuoto: %s.\n' \
      "$CALICO_OPERATOR_RENDERED" >&2
    return 1
  fi

  if PINNED_IMAGE_COUNT="$(awk -v expected="$PINNED_OPERATOR_IMAGE" '
      $1 == "image:" && $2 == expected { count++ }
      END { print count + 0 }
    ' "$CALICO_OPERATOR_RENDERED")"
  then
    AWK_RC=0
  else
    AWK_RC=$?
  fi
  if [[ "$AWK_RC" -ne 0 ]]
  then
    printf 'ERROR: parser immagine operator fallito (awk rc=%s).\n' \
      "$AWK_RC" >&2
    return 1
  fi
  if [[ "$PINNED_IMAGE_COUNT" -ne 1 ]]
  then
    printf 'FAIL: attesa una immagine Tigera Operator pinned, trovate %s.\n' \
      "$PINNED_IMAGE_COUNT" >&2
    return 1
  fi

  if grep -F -n "$TAGGED_OPERATOR_IMAGE" "$CALICO_OPERATOR_RENDERED"
  then
    printf 'FAIL: immagine Tigera Operator tagged ancora presente.\n' >&2
    return 1
  else
    FILTER_RC=$?
  fi
  if [[ "$FILTER_RC" -gt 1 ]]
  then
    printf 'ERROR: filtro immagine operator tagged fallito (grep rc=%s).\n' \
      "$FILTER_RC" >&2
    return 1
  fi

  if grep -n -E 'latest|goldmane|whisker' "$CALICO_OPERATOR_RENDERED"
  then
    printf 'FAIL: marker latest/Goldmane/Whisker inatteso nel rendering Calico.\n' >&2
    return 1
  else
    FILTER_RC=$?
  fi
  if [[ "$FILTER_RC" -gt 1 ]]
  then
    printf 'ERROR: filtro rendering Calico fallito (grep rc=%s).\n' \
      "$FILTER_RC" >&2
    return 1
  fi

  printf 'PASS: rendering Tigera Operator pinned e componenti esclusi assenti.\n'
}

render_calico_static
```

Non devono esserci tag `latest` né workload Goldmane o Whisker. Il
Deployment operator deve usare il digest bloccato dal post-renderer.

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

La sequenza applica direttamente la configurazione finale consolidata. È stata
controllata staticamente, ma non è ancora stata validata end-to-end in questa
forma su un sistema pulito. Se non converge, fermarsi e conservare lo stato per
la diagnosi.

### 10.3 Verifica di Calico, CNI e IPAM

```bash
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=300s
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

Ispezionare i tre namespace nodo:

```bash
NODE_INVENTORY_FAILED=0
for NODE in \
  k3d-tesi-e10-calico-vxlan-server-0 \
  k3d-tesi-e10-calico-vxlan-agent-0 \
  k3d-tesi-e10-calico-vxlan-agent-1
do
  docker exec "$NODE" ip -br link || NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip route || NODE_INVENTORY_FAILED=1
  docker exec "$NODE" ip -details link show vxlan.calico || \
    NODE_INVENTORY_FAILED=1
  docker exec "$NODE" sh -c \
    'ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d; sed -n "1,240p" /var/lib/rancher/k3s/agent/etc/cni/net.d/*calico*.conflist' || \
    NODE_INVENTORY_FAILED=1
done

if [[ "$NODE_INVENTORY_FAILED" -ne 0 ]]
then
  printf 'ERROR: inventario data plane E10 incompleto.\n' >&2
  unset NODE_INVENTORY_FAILED
  false
elif ! docker exec k3d-tesi-e10-calico-vxlan-agent-0 true
then
  unset NODE_INVENTORY_FAILED
  printf 'ERROR: nodo E10 non accessibile; impossibile verificare cni0.\n' >&2
  false
else
  unset NODE_INVENTORY_FAILED
  if docker exec k3d-tesi-e10-calico-vxlan-agent-0 \
      test -e /sys/class/net/cni0
  then
    printf 'FAIL: cni0 non atteso in E10\n' >&2
    false
  else
    CNI0_RC=$?
    if [[ "$CNI0_RC" -eq 1 ]]
    then
      unset CNI0_RC
      printf 'PASS: cni0 assente come atteso\n'
    else
      printf 'ERROR: verifica cni0 fallita (docker exec rc=%s).\n' \
        "$CNI0_RC" >&2
      unset CNI0_RC
      false
    fi
  fi
fi
```

Il controllo deve registrare `PASS` perché `cni0` non esiste. Le interfacce dei
Pod sono `cali*`, il tunnel è `vxlan.calico`, con UDP 4789 e VNI 4096.

### 10.4 Workload, percorso e cattura

Applicare il workload comune, eseguire la matrice baseline e rileggere gli
indirizzi:

```bash
deploy_common_workload &&
run_policy_matrix allow-all &&
_tesi_export_runtime CLIENT_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod client -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVER_A_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod server-a -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVER_B_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get pod server-b -o jsonpath='{.status.podIP}' &&
_tesi_export_runtime SERVICE_IP ipv4 kubectl --context "$TESI_CONTEXT" \
  -n net-lab get svc servers -o jsonpath='{.spec.clusterIP}' &&
kubectl --context "$TESI_CONTEXT" get \
  workloadendpoints.projectcalico.org -A -o wide &&
docker exec k3d-tesi-e10-calico-vxlan-agent-0 ip -br link &&
docker exec k3d-tesi-e10-calico-vxlan-agent-0 ip route &&
docker exec k3d-tesi-e10-calico-vxlan-agent-1 ip -br link &&
docker exec k3d-tesi-e10-calico-vxlan-agent-1 ip route
```

Ispezionare nuovamente route e interfacce `cali*`; il percorso intra-node è
routing L3 fra veth, senza bridge.

Per la cattura inter-node, rileggere PID e underlay e usare un GET singolo.
Come in E01, entriamo nel namespace del nodo sorgente perché contiene
`cali*`, `vxlan.calico` ed `eth0`; il filtro unisce HTTP interno e VXLAN UDP
4789 esterno.

```bash
export SOURCE_NODE='k3d-tesi-e10-calico-vxlan-agent-0'
export DESTINATION_NODE='k3d-tesi-e10-calico-vxlan-agent-1'
_tesi_export_runtime SOURCE_PID positive-integer docker inspect \
  -f '{{.State.Pid}}' "$SOURCE_NODE" &&
_tesi_export_runtime SOURCE_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e10-calico-vxlan"}}{{.IPAddress}}{{end}}' \
  "$SOURCE_NODE" &&
_tesi_export_runtime DESTINATION_UNDERLAY ipv4 docker inspect \
  -f '{{with index .NetworkSettings.Networks "k3d-tesi-e10-calico-vxlan"}}{{.IPAddress}}{{end}}' \
  "$DESTINATION_NODE" &&
export CAPTURE_DIR="$(mktemp -d)" &&
sudo -v && {
(
  sleep 2
  http_flow client server-b
) >"$CAPTURE_DIR/http-client.log" 2>&1 &
export HTTP_JOB=$!

if sudo -- /usr/bin/timeout --preserve-status --signal=TERM \
    --kill-after=3s 10s \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 4789))" \
    >"$CAPTURE_DIR/calico-inter-node.log" 2>&1
then
  export CAPTURE_RC=0
else
  export CAPTURE_RC=$?
fi
printf 'capture_exit=%s\n' "$CAPTURE_RC"
if wait "$HTTP_JOB"
then
  export HTTP_RC=0
else
  export HTTP_RC=$?
fi
printf 'http_exit=%s\n' "$HTTP_RC"

export CAPTURE_FAILED=0
case "$CAPTURE_RC" in
  0|124|143) ;;
  *) printf 'FAIL: terminazione inattesa della cattura\n' >&2; CAPTURE_FAILED=1 ;;
esac
if [[ "$HTTP_RC" -ne 0 ]]
then
  printf 'FAIL: richiesta HTTP della cattura fallita\n' >&2
  CAPTURE_FAILED=1
fi
if ! verify_no_tcpdump_processes
then
  CAPTURE_FAILED=1
fi
if ! verify_dual_view_capture \
    "$CAPTURE_DIR/calico-inter-node.log" \
    "$CLIENT_IP" "$SERVER_B_IP" \
    "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 4789
then
  CAPTURE_FAILED=1
fi

if [[ "$CAPTURE_FAILED" -ne 0 ]]
then
  printf 'STOP: cattura E10 non valida; nessuna analisi successiva eseguita.\n' >&2
  false
else
  sed -n '1,260p' "$CAPTURE_DIR/calico-inter-node.log" &&
    cat "$CAPTURE_DIR/http-client.log"
fi
}
```

Correlare gli IP dei Pod all'interno e gli IP underlay all'esterno; cercare
UDP 4789, `vxlan.calico` e VNI 4096. Per la cattura sono accettati exit code
`0`, `124` o `143`; gli altri indicano un errore da diagnosticare.

`CAPTURE_DIR` va conservata in caso di errore. Dopo un esito positivo può
essere rimossa con `rm -rf -- "$CAPTURE_DIR"`.

### 10.5 Service e NetworkPolicy

Per attribuire il Service verifichiamo separatamente i due backend Ready, poi
confrontiamo catene e contatori kube-proxy prima e dopo nuove connessioni al
ClusterIP.

```bash
export CALICO_AGENT0='k3d-tesi-e10-calico-vxlan-agent-0'
export SERVICE_DIR="$(mktemp -d)"

run_e10_service_attribution() {
  local GREP_RC

  verify_service_backends || return 1

  if ! docker logs "$CALICO_AGENT0" \
      >"$SERVICE_DIR/kube-proxy-full.log" 2>&1
  then
    printf 'ERROR: acquisizione log kube-proxy fallita.\n' >&2
    return 1
  fi
  if grep -E 'kube-proxy|Using iptables Proxier' \
      "$SERVICE_DIR/kube-proxy-full.log" \
      >"$SERVICE_DIR/kube-proxy.log"
  then
    :
  else
    GREP_RC=$?
    if [[ "$GREP_RC" -gt 1 ]]
    then
      printf 'ERROR: filtro log kube-proxy fallito (grep rc=%s).\n' \
        "$GREP_RC" >&2
      return 1
    fi
    printf 'INFO: nessuna riga kube-proxy trovata nel log; il file non viene usato come gate.\n'
  fi

  capture_service_iptables_snapshot "$CALICO_AGENT0" \
    "$SERVICE_DIR/iptables-before-full.log" \
    "$SERVICE_DIR/iptables-before.log" || return 1

  if ! service_http_flows 6 >"$SERVICE_DIR/http-flows.log"
  then
    printf 'ERROR: almeno un flusso Service E10 è fallito; snapshot successivo non acquisito.\n' >&2
    return 1
  fi

  capture_service_iptables_snapshot "$CALICO_AGENT0" \
    "$SERVICE_DIR/iptables-after-full.log" \
    "$SERVICE_DIR/iptables-after.log" || return 1

  cat "$SERVICE_DIR/http-flows.log" || return 1
  show_informative_diff "$SERVICE_DIR/iptables-before.log" \
    "$SERVICE_DIR/iptables-after.log" || return 1
}

run_e10_service_attribution
```

La distribuzione delle risposte fra i backend non è un criterio di successo.
Per i flussi realmente osservati, catene `KUBE-SVC`/`KUBE-SEP`, Destination
Network Address Translation (DNAT) e delta pertinenti dei contatori sostengono
l'attribuzione a kube-proxy iptables. Le evidence originali E10 registrarono
due risposte `server-a`; quel risultato è coerente con la selezione
probabilistica e non indebolisce l'attribuzione basata sui contatori.

Per le policy vogliamo correlare il risultato applicativo con il lavoro di
Felix. Nei log cerchiamo calcolo di policy, selector e IPSet; nel kernel
cerchiamo gli insiemi `cali*`, le catene iptables e i loro contatori. Definire
il controllo una volta:

```bash
inspect_calico_policy_plane() {
  local FAILED=0
  local FILTER_RC
  local IPSET_OUTPUT
  local IPTABLES_OUTPUT
  local LOG_OUTPUT
  local POLICY_OUTPUT
  local WEP_OUTPUT

  if POLICY_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get \
      networkpolicy -n net-lab -o yaml)"
  then
    printf '%s\n' "$POLICY_OUTPUT"
  else
    printf 'ERROR: acquisizione NetworkPolicy Calico fallita.\n' >&2
    FAILED=1
  fi
  if WEP_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get \
      workloadendpoints.projectcalico.org -A -o yaml)"
  then
    printf '%s\n' "$WEP_OUTPUT"
  else
    printf 'ERROR: acquisizione WorkloadEndpoint Calico fallita.\n' >&2
    FAILED=1
  fi
  if LOG_OUTPUT="$(kubectl --context "$TESI_CONTEXT" logs -n calico-system \
      daemonset/calico-node -c calico-node --tail=300)"
  then
    if grep -E 'Policy|selector|IPSet|iptables' <<<"$LOG_OUTPUT"
    then
      FILTER_RC=0
    else
      FILTER_RC=$?
    fi
    case "$FILTER_RC" in
      0) ;;
      1) printf 'INFO: marker policy assenti nei log Calico.\n' ;;
      *) printf 'ERROR: filtro log Calico fallito (grep rc=%s).\n' \
           "$FILTER_RC" >&2; FAILED=1 ;;
    esac
  else
    printf 'ERROR: acquisizione log Calico fallita.\n' >&2
    FAILED=1
  fi

  for NODE in \
    k3d-tesi-e10-calico-vxlan-agent-0 \
    k3d-tesi-e10-calico-vxlan-agent-1
  do
    if IPTABLES_OUTPUT="$(docker exec "$NODE" \
        /bin/aux/iptables-save -c)"
    then
      if grep -E 'cali-|KubernetesNetworkPolicy' <<<"$IPTABLES_OUTPUT"
      then
        FILTER_RC=0
      else
        FILTER_RC=$?
      fi
      case "$FILTER_RC" in
        0) ;;
        1) printf 'INFO: catene policy Calico assenti su %s.\n' "$NODE" ;;
        *) printf 'ERROR: filtro iptables Calico fallito su %s (grep rc=%s).\n' \
             "$NODE" "$FILTER_RC" >&2; FAILED=1 ;;
      esac
    else
      printf 'ERROR: acquisizione iptables Calico fallita su %s.\n' \
        "$NODE" >&2
      FAILED=1
    fi

    if IPSET_OUTPUT="$(docker exec "$NODE" /bin/ipset save)"
    then
      if grep -E 'cali' <<<"$IPSET_OUTPUT"
      then
        FILTER_RC=0
      else
        FILTER_RC=$?
      fi
      case "$FILTER_RC" in
        0) ;;
        1) printf 'INFO: IPSet Calico assenti su %s.\n' "$NODE" ;;
        *) printf 'ERROR: filtro IPSet Calico fallito su %s (grep rc=%s).\n' \
             "$NODE" "$FILTER_RC" >&2; FAILED=1 ;;
      esac
    else
      printf 'ERROR: acquisizione IPSet Calico fallita su %s.\n' \
        "$NODE" >&2
      FAILED=1
    fi
  done

  [[ "$FAILED" -eq 0 ]]
}
```

Eseguire poi i tre stati in ordine:

```bash
# Baseline: sei connessioni consentite
run_policy_matrix allow-all &&
inspect_calico_policy_plane &&

# Default deny: sei connessioni negate
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml &&
run_policy_matrix deny-all &&
inspect_calico_policy_plane &&

# Allow selettiva: quattro consentite, due negate
kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml &&
run_policy_matrix selective-allow &&
inspect_calico_policy_plane
```

Selector, IPSet, catene e contatori devono essere coerenti con 6/6 consentiti,
6/6 negati, quindi 4/6 consentiti. L'enforcement osservato è attribuito al
calculation graph e a Felix; `calico-kube-controllers` non va descritto come
policy controller in questa configurazione Kubernetes Datastore.

Rimuovere infine entrambe le policy e richiedere il ripristino della baseline:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found &&
run_policy_matrix allow-all &&
inspect_calico_policy_plane
```

L'attribuzione causale è valida soltanto se la matrice torna a 6/6 consentiti.

### 10.6 Rimozione del cluster

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

```bash
kubectl --context "$TESI_CONTEXT" wait \
  --for=condition=Ready node --all --timeout=300s
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
    'ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d; sed -n "1,240p" /var/lib/rancher/k3s/agent/etc/cni/net.d/05-cilium.conflist' || \
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

Applicare il workload comune, eseguire la matrice baseline e rileggere
endpoint, identità e indirizzi:

```bash
deploy_common_workload &&
run_policy_matrix allow-all &&
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

sudo -v && {
(
  sleep 2
  http_flow client server-b
) >"$CAPTURE_DIR/http-client.log" 2>&1 &
export HTTP_JOB=$!

if sudo /usr/bin/env LC_ALL=C \
    /usr/bin/nsenter --target "$SOURCE_PID" --net \
    /usr/bin/timeout --verbose --foreground --preserve-status \
    --signal=TERM --kill-after=2s 8s \
    /usr/bin/tcpdump -i any -tttt -nn -e -vv -A -s 0 -l \
    "((host $CLIENT_IP and host $SERVER_B_IP and tcp port 8080) or (host $SOURCE_UNDERLAY and host $DESTINATION_UNDERLAY and udp port 8472))" \
    >"$CAPTURE_DIR/cilium-inter-node.log" 2>&1
then
  export CAPTURE_RC=0
else
  export CAPTURE_RC=$?
fi
printf 'capture_exit=%s\n' "$CAPTURE_RC"
if wait "$HTTP_JOB"
then
  export HTTP_RC=0
else
  export HTTP_RC=$?
fi
printf 'http_exit=%s\n' "$HTTP_RC"

export CAPTURE_FAILED=0
case "$CAPTURE_RC" in
  0|124|143) ;;
  *) printf 'FAIL: terminazione inattesa della cattura\n' >&2; CAPTURE_FAILED=1 ;;
esac
if [[ "$HTTP_RC" -ne 0 ]]
then
  printf 'FAIL: richiesta HTTP della cattura fallita\n' >&2
  CAPTURE_FAILED=1
fi
if ! verify_no_tcpdump_processes
then
  CAPTURE_FAILED=1
fi
if ! verify_dual_view_capture \
    "$CAPTURE_DIR/cilium-inter-node.log" \
    "$CLIENT_IP" "$SERVER_B_IP" \
    "$SOURCE_UNDERLAY" "$DESTINATION_UNDERLAY" 8472
then
  CAPTURE_FAILED=1
fi

if [[ "$CAPTURE_FAILED" -ne 0 ]]
then
  printf 'STOP: cattura E20 non valida; nessuna analisi successiva eseguita.\n' >&2
  false
else
  sed -n '1,360p' "$CAPTURE_DIR/cilium-inter-node.log" &&
    cat "$CAPTURE_DIR/http-client.log"
fi
}
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
kube-proxy ed eBPF prima di nuove connessioni:

```bash
export CILIUM_NODE='k3d-tesi-e20-cilium-vxlan-agent-0'
export SERVICE_DIR="$(mktemp -d)"

run_e20_service_attribution() {
  local START_UTC
  local END_UTC
  local required_file

  verify_service_backends || return 1
  START_UTC="$(date -u --iso-8601=seconds)" || return 1

  capture_service_iptables_snapshot "$CILIUM_NODE" \
    "$SERVICE_DIR/kube-proxy-before-full.log" \
    "$SERVICE_DIR/kube-proxy-before.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --frontends \
    >"$SERVICE_DIR/lb-frontends-before.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --backends \
    >"$SERVICE_DIR/lb-backends-before.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --revnat \
    >"$SERVICE_DIR/lb-revnat-before.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf ct list global \
    >"$SERVICE_DIR/ct-before.log" || return 1

  for required_file in \
    "$SERVICE_DIR/lb-frontends-before.log" \
    "$SERVICE_DIR/lb-backends-before.log" \
    "$SERVICE_DIR/lb-revnat-before.log" \
    "$SERVICE_DIR/ct-before.log"
  do
    if [[ ! -s "$required_file" ]]
    then
      printf 'ERROR: output Cilium richiesto vuoto: %s\n' \
        "$required_file" >&2
      return 1
    fi
  done

  if ! service_http_flows 6 >"$SERVICE_DIR/http-flows.log"
  then
    printf 'ERROR: almeno un flusso Service E20 è fallito; snapshot successivi non acquisiti.\n' >&2
    return 1
  fi
  END_UTC="$(date -u --iso-8601=seconds)" || return 1

  capture_service_iptables_snapshot "$CILIUM_NODE" \
    "$SERVICE_DIR/kube-proxy-after-full.log" \
    "$SERVICE_DIR/kube-proxy-after.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf ct list global \
    >"$SERVICE_DIR/ct-after.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- hubble observe \
    --server unix:///var/run/cilium/hubble.sock \
    --since "$START_UTC" --until "$END_UTC" \
    --from-pod net-lab/client --port 8080 -o jsonpb \
    >"$SERVICE_DIR/hubble-service.json" || return 1

  for required_file in \
    "$SERVICE_DIR/http-flows.log" \
    "$SERVICE_DIR/ct-after.log" \
    "$SERVICE_DIR/hubble-service.json"
  do
    if [[ ! -s "$required_file" ]]
    then
      printf 'ERROR: output Service E20 richiesto vuoto: %s\n' \
        "$required_file" >&2
      return 1
    fi
  done

  cat "$SERVICE_DIR/http-flows.log" || return 1
  show_informative_diff "$SERVICE_DIR/kube-proxy-before.log" \
    "$SERVICE_DIR/kube-proxy-after.log" || return 1
  show_informative_diff "$SERVICE_DIR/ct-before.log" \
    "$SERVICE_DIR/ct-after.log" || return 1
}

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

Per ogni stato delimitiamo una finestra Hubble, eseguiamo le sei connessioni e
acquisiamo oggetti, revisioni endpoint, policy map e verdetti. La funzione
salva ogni stato in una directory separata:

```bash
export POLICY_DIR="$(mktemp -d)"

capture_cilium_policy_state() {
  if [[ "$#" -ne 2 ]]
  then
    printf 'Uso: capture_cilium_policy_state STATO ASPETTATIVA\n' >&2
    return 2
  fi
  local POLICY_STATE="$1"
  local POLICY_EXPECTATION="$2"
  local POLICY_SINCE
  local POLICY_UNTIL
  local REQUIRED_FILE
  POLICY_SINCE="$(date -u --iso-8601=seconds)" || return 1
  run_policy_matrix "$POLICY_EXPECTATION" || return 1
  POLICY_UNTIL="$(date -u --iso-8601=seconds)" || return 1

  kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml \
    >"$POLICY_DIR/${POLICY_STATE}-networkpolicy.yaml" || return 1
  kubectl --context "$TESI_CONTEXT" get ciliumendpoint \
    -n net-lab client server-a server-b -o yaml \
    >"$POLICY_DIR/${POLICY_STATE}-endpoints.yaml" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf policy get --all \
    >"$POLICY_DIR/${POLICY_STATE}-bpf-policy.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- hubble observe \
    --server unix:///var/run/cilium/hubble.sock \
    --since "$POLICY_SINCE" --until "$POLICY_UNTIL" \
    --namespace net-lab --port 8080 -o jsonpb \
    >"$POLICY_DIR/${POLICY_STATE}-hubble.json" || return 1

  for REQUIRED_FILE in \
    "$POLICY_DIR/${POLICY_STATE}-networkpolicy.yaml" \
    "$POLICY_DIR/${POLICY_STATE}-endpoints.yaml" \
    "$POLICY_DIR/${POLICY_STATE}-bpf-policy.log" \
    "$POLICY_DIR/${POLICY_STATE}-hubble.json"
  do
    if [[ ! -s "$REQUIRED_FILE" ]]
    then
      printf 'ERROR: output policy E20 richiesto vuoto: %s\n' \
        "$REQUIRED_FILE" >&2
      return 1
    fi
  done
}
```

Eseguire i tre stati:

```bash
capture_cilium_policy_state baseline allow-all &&

kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/default-deny-ingress.yaml &&
capture_cilium_policy_state default-deny deny-all &&

kubectl --context "$TESI_CONTEXT" apply \
  -f manifests/cni/common/allow-client-to-http-servers.yaml &&
capture_cilium_policy_state selective-allow selective-allow &&

ls -la "$POLICY_DIR"
```

Controllare revisioni endpoint crescenti, policy map eBPF e verdetti Hubble
`FORWARDED` o `POLICY_DENIED`. La matrice attesa è 6/6 consentiti, 6/6
negati, poi 4/6 consentiti. Questi artefatti attribuiscono l'enforcement a
Cilium, non al controller policy K3s disabilitato.

Rimuovere entrambe le policy e acquisire uno stato finale `restored`. La
conclusione causale richiede che la matrice torni a `allow-all`:

```bash
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/allow-client-to-http-servers.yaml \
  --ignore-not-found &&
kubectl --context "$TESI_CONTEXT" delete \
  -f manifests/cni/common/default-deny-ingress.yaml \
  --ignore-not-found &&
capture_cilium_policy_state restored allow-all
```

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
i container nodo o i listener API creati dalla guida:

```bash
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
