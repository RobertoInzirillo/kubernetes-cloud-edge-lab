#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  printf 'Questo ambiente comune richiede una shell Bash.\n' >&2
  return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'Questo file deve essere caricato con: source scripts/cni/common/lab-env.sh\n' >&2
  exit 1
fi

_tesi_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export TESI_REPO_ROOT="$(cd -- "${_tesi_script_dir}/../../.." && pwd -P)"
unset _tesi_script_dir

if [[ "$(pwd -P)" != "$TESI_REPO_ROOT" ]]; then
  printf 'Repository rilevata in %s\n' "$TESI_REPO_ROOT" >&2
  printf 'Eseguire prima: cd %q\n' "$TESI_REPO_ROOT" >&2
  return 1
fi

if [[ ! -f manifests/cni/common/workload.yaml || \
      ! -f docs/reproduction-guide.md ]]; then
  printf 'Root della repository non valida: %s\n' "$TESI_REPO_ROOT" >&2
  return 1
fi

export TESI_K3S_IMAGE='docker.io/rancher/k3s@sha256:0487bcfa1ea34f02a80c93122520fb70af434663a3bcdb61a697a0b5ab37e69d'

_tesi_require_context() {
  if [[ -z "${TESI_CONTEXT:-}" || -z "${TESI_NODE_PREFIX:-}" ]]; then
    printf "Definire TESI_CONTEXT e TESI_NODE_PREFIX per l'esperimento corrente.\n" >&2
    return 1
  fi
}

_tesi_is_ipv4() {
  if [[ "$#" -ne 1 || ! "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  local octet
  local -a octets
  IFS=. read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    if ((10#$octet > 255)); then
      return 1
    fi
  done
}

_tesi_export_runtime() {
  if [[ "$#" -lt 3 || ! "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    printf 'Uso: _tesi_export_runtime VAR TIPO COMANDO [ARGOMENTI...].\n' >&2
    return 2
  fi

  local variable_name="$1"
  local value_type="$2"
  local value
  local command_rc
  shift 2

  if value="$("$@")"; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [[ "$command_rc" -ne 0 ]]; then
    printf 'ERROR: acquisizione runtime %s fallita (rc=%s).\n' \
      "$variable_name" "$command_rc" >&2
    return 1
  fi

  case "$value_type" in
    ipv4)
      if ! _tesi_is_ipv4 "$value"; then
        printf 'ERROR: valore runtime IPv4 non valido per %s: %q.\n' \
          "$variable_name" "$value" >&2
        return 1
      fi
      ;;
    positive-integer)
      if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: valore runtime intero non valido per %s: %q.\n' \
          "$variable_name" "$value" >&2
        return 1
      fi
      ;;
    pod-name)
      if [[ ${#value} -gt 253 || \
            ! "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        printf 'ERROR: nome Pod runtime non valido per %s: %q.\n' \
          "$variable_name" "$value" >&2
        return 1
      fi
      ;;
    nonempty)
      if [[ -z "$value" ]]; then
        printf 'ERROR: valore runtime vuoto per %s.\n' "$variable_name" >&2
        return 1
      fi
      ;;
    *)
      printf 'ERROR: tipo runtime non supportato per %s: %s.\n' \
        "$variable_name" "$value_type" >&2
      return 2
      ;;
  esac

  printf -v "$variable_name" '%s' "$value"
  export "$variable_name"
}

verify_dual_view_capture() {
  if [[ "$#" -ne 6 ]]; then
    printf 'Uso: verify_dual_view_capture FILE POD_SRC POD_DST UNDERLAY_SRC UNDERLAY_DST PORTA_UDP.\n' >&2
    return 2
  fi

  local capture_file="$1"
  local pod_source="$2"
  local pod_destination="$3"
  local underlay_source="$4"
  local underlay_destination="$5"
  local udp_port="$6"
  local awk_rc

  if [[ ! -s "$capture_file" ]]; then
    printf 'FAIL: cattura vuota o assente: %s.\n' "$capture_file" >&2
    return 1
  fi
  if ! _tesi_is_ipv4 "$pod_source" || ! _tesi_is_ipv4 "$pod_destination" || \
      ! _tesi_is_ipv4 "$underlay_source" || \
      ! _tesi_is_ipv4 "$underlay_destination" || \
      [[ ! "$udp_port" =~ ^[1-9][0-9]*$ || "$udp_port" -gt 65535 ]]; then
    printf 'ERROR: parametri runtime non validi per il gate della cattura.\n' >&2
    return 1
  fi

  if awk -v source="$pod_source" -v destination="$pod_destination" '
      index($0, source) && index($0, destination) &&
      $0 ~ /TCP/ && (index($0, ".8080") || index($0, "port 8080")) {
        found=1
      }
      END { exit !found }
    ' "$capture_file"; then
    awk_rc=0
  else
    awk_rc=$?
  fi
  case "$awk_rc" in
    0) ;;
    1)
      printf 'FAIL: vista Pod TCP/8080 non trovata nella cattura %s.\n' \
        "$capture_file" >&2
      return 1
      ;;
    *)
      printf 'ERROR: parser della vista Pod fallito (awk rc=%s).\n' \
        "$awk_rc" >&2
      return 1
      ;;
  esac

  if awk -v source="$underlay_source" -v destination="$underlay_destination" \
      -v port="$udp_port" '
      index($0, source) && index($0, destination) && $0 ~ /UDP/ &&
      (index($0, "." port) || index($0, "port " port)) { found=1 }
      END { exit !found }
    ' "$capture_file"; then
    awk_rc=0
  else
    awk_rc=$?
  fi
  case "$awk_rc" in
    0)
      printf 'PASS: cattura con vista Pod TCP/8080 e vista underlay UDP/%s.\n' \
        "$udp_port"
      ;;
    1)
      printf 'FAIL: vista underlay UDP/%s non trovata nella cattura %s.\n' \
        "$udp_port" "$capture_file" >&2
      return 1
      ;;
    *)
      printf 'ERROR: parser della vista underlay fallito (awk rc=%s).\n' \
        "$awk_rc" >&2
      return 1
      ;;
  esac
}

show_informative_diff() {
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: show_informative_diff FILE_PRIMA FILE_DOPO.\n' >&2
    return 2
  fi

  local diff_rc
  if diff -u "$1" "$2"; then
    diff_rc=0
  else
    diff_rc=$?
  fi
  case "$diff_rc" in
    0|1) return 0 ;;
    *)
      printf 'ERROR: confronto diff fallito (rc=%s): %s %s.\n' \
        "$diff_rc" "$1" "$2" >&2
      return 1
      ;;
  esac
}

check_experiment_preflight() {
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: check_experiment_preflight NOME_CLUSTER PORTA_API\n' >&2
    return 2
  fi

  local cluster_name="$1"
  local api_port="$2"
  local blocked=0
  local cluster_list
  local port_list
  local parser_rc
  local pgrep_rc

  if ! command -v k3d >/dev/null || ! command -v ss >/dev/null || \
      ! command -v pgrep >/dev/null; then
    printf 'STOP: toolchain incompleta per il preflight.\n' >&2
    return 1
  fi

  if ! cluster_list="$(k3d cluster list 2>&1)"; then
    printf 'STOP: impossibile leggere i cluster k3d:\n%s\n' \
      "$cluster_list" >&2
    return 1
  fi

  if printf '%s\n' "$cluster_list" | \
      awk -v expected="$cluster_name" \
        '$1 == expected { found=1 } END { exit !found }'; then
    parser_rc=0
  else
    parser_rc=$?
  fi
  case "$parser_rc" in
    0)
      printf 'STOP: esiste già il cluster %s.\n' "$cluster_name" >&2
      blocked=1
      ;;
    1) ;;
    *)
      printf 'STOP: parser dell’inventario cluster fallito (awk rc=%s).\n' \
        "$parser_rc" >&2
      return 1
      ;;
  esac

  if ! port_list="$(ss -H -ltn "sport = :${api_port}")"; then
    printf 'STOP: impossibile verificare la porta API %s con ss.\n' \
      "$api_port" >&2
    return 1
  fi

  if [[ -n "$port_list" ]]; then
    printf 'STOP: la porta API %s è già in ascolto.\n' "$api_port" >&2
    ss -H -ltnp "sport = :${api_port}" || true
    blocked=1
  fi

  if pgrep -x tcpdump >/dev/null; then
    pgrep_rc=0
  else
    pgrep_rc=$?
  fi
  case "$pgrep_rc" in
    0)
      printf 'STOP: sono presenti processi tcpdump; verificarne la provenienza.\n' >&2
      pgrep -a -x tcpdump >&2 || true
      blocked=1
      ;;
    1) ;;
    *)
      printf 'STOP: impossibile verificare i processi tcpdump (pgrep rc=%s).\n' \
        "$pgrep_rc" >&2
      return 1
      ;;
  esac

  if [[ "$blocked" -ne 0 ]]; then
    printf '%s\n' \
      "Non viene rimosso nulla automaticamente: riprendere l'analisi esistente" \
      "oppure eseguire consapevolmente il cleanup dell'esperimento precedente." >&2
    return 1
  fi

  printf 'PASS preflight: cluster=%s porta_api=%s tcpdump_residui=0\n' \
    "$cluster_name" "$api_port"
}

verify_no_tcpdump_processes() {
  local pgrep_rc

  if ! command -v pgrep >/dev/null; then
    printf 'ERROR: pgrep non disponibile; impossibile verificare tcpdump.\n' >&2
    return 1
  fi

  if pgrep -x tcpdump >/dev/null; then
    pgrep_rc=0
  else
    pgrep_rc=$?
  fi

  case "$pgrep_rc" in
    0)
      printf 'FAIL: tcpdump residuo.\n' >&2
      pgrep -a -x tcpdump >&2 || true
      return 1
      ;;
    1)
      printf 'PASS: nessun tcpdump residuo.\n'
      return 0
      ;;
    *)
      printf 'ERROR: verifica tcpdump fallita (pgrep rc=%s).\n' \
        "$pgrep_rc" >&2
      return 1
      ;;
  esac
}

deploy_common_workload() {
  _tesi_require_context || return 1

  kubectl --context "$TESI_CONTEXT" label node \
    "${TESI_NODE_PREFIX}-agent-0" tesi-placement=a --overwrite || return 1
  kubectl --context "$TESI_CONTEXT" label node \
    "${TESI_NODE_PREFIX}-agent-1" tesi-placement=b --overwrite || return 1
  kubectl --context "$TESI_CONTEXT" apply \
    -f manifests/cni/common/workload.yaml || return 1
  kubectl --context "$TESI_CONTEXT" wait -n net-lab \
    --for=condition=Ready pod/client pod/server-a pod/server-b \
    --timeout=180s || return 1
  kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide || return 1
  kubectl --context "$TESI_CONTEXT" get service -n net-lab \
    servers -o wide || return 1
  kubectl --context "$TESI_CONTEXT" get endpointslice -n net-lab \
    -l kubernetes.io/service-name=servers -o wide || return 1
}

verify_service_backends() {
  if ! _tesi_require_context; then
    printf 'ERROR: contesto Service non definito.\n' >&2
    return 1
  fi

  local endpoints
  local backend
  local parser_rc
  if ! endpoints="$(kubectl --context "$TESI_CONTEXT" get endpointslice \
    -n net-lab -l kubernetes.io/service-name=servers \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\n"}{end}')"; then
    printf 'ERROR: lettura EndpointSlice del Service fallita.\n' >&2
    return 1
  fi
  printf '%s\n' "$endpoints"

  for backend in server-a server-b; do
    if printf '%s\n' "$endpoints" | awk -v expected="$backend" \
        '$1 == expected && $2 == "true" { found=1 } END { exit !found }'; then
      parser_rc=0
    else
      parser_rc=$?
    fi
    case "$parser_rc" in
      0) ;;
      1)
        printf 'FAIL backend Ready non trovato: %s\n' "$backend" >&2
        return 1
        ;;
      *)
        printf 'ERROR: parser EndpointSlice fallito (awk rc=%s).\n' \
          "$parser_rc" >&2
        return 1
        ;;
    esac
  done

  printf 'PASS backend Ready: server-a server-b\n'
}

_tesi_wget_probe() {
  if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
    printf 'ERROR: uso interno probe POD URL BODY_ATTESO_1 [BODY_ATTESO_2].\n' >&2
    return 70
  fi

  local source_pod="$1"
  local target_url="$2"
  local expected_body_1="$3"
  local expected_body_2="${4:-}"
  local exec_output
  local exec_rc
  local line
  local wget_rc=''
  local response_body=''
  local saw_body=0
  local saw_done=0

  if exec_output="$(kubectl --context "$TESI_CONTEXT" exec -n net-lab \
      "$source_pod" -- sh -c '
        target_url="$1"
        body="$(wget -qO- -T 3 "$target_url")"
        wget_rc=$?
        printf "TESI_WGET_RC=%s\n" "$wget_rc"
        printf "TESI_RESPONSE_BODY=%s\n" "$body"
        printf "TESI_PROBE_DONE=1\n"
        exit 0
      ' sh "$target_url")"; then
    exec_rc=0
  else
    exec_rc=$?
  fi

  if [[ "$exec_rc" -ne 0 ]]; then
    printf 'ERROR kind=kubectl-exec source=%s rc=%s\n' \
      "$source_pod" "$exec_rc" >&2
    return 71
  fi

  while IFS= read -r line; do
    case "$line" in
      TESI_WGET_RC=*) wget_rc="${line#TESI_WGET_RC=}" ;;
      TESI_RESPONSE_BODY=*)
        response_body="${line#TESI_RESPONSE_BODY=}"
        saw_body=1
        ;;
      TESI_PROBE_DONE=1) saw_done=1 ;;
      '') ;;
      *)
        printf 'ERROR kind=remote-probe-output source=%s line=%q\n' \
          "$source_pod" "$line" >&2
        return 72
        ;;
    esac
  done <<< "$exec_output"

  if [[ "$saw_done" -ne 1 || "$saw_body" -ne 1 || \
        ! "$wget_rc" =~ ^[0-9]+$ ]]; then
    printf 'ERROR kind=remote-probe-malformed source=%s\n' "$source_pod" >&2
    return 72
  fi

  printf 'response=%s\nexit_code=%s\n' "$response_body" "$wget_rc"

  case "$wget_rc" in
    0)
      if [[ "$response_body" == "$expected_body_1" || \
            ( -n "$expected_body_2" && "$response_body" == "$expected_body_2" ) ]]; then
        return 0
      fi
      printf 'ERROR kind=unexpected-body source=%s expected=%s' \
        "$source_pod" "$expected_body_1" >&2
      if [[ -n "$expected_body_2" ]]; then
        printf '|%s' "$expected_body_2" >&2
      fi
      printf ' actual=%q\n' "$response_body" >&2
      return 20
      ;;
    1)
      return 10
      ;;
    *)
      printf 'ERROR kind=remote-wget source=%s rc=%s\n' \
        "$source_pod" "$wget_rc" >&2
      return 72
      ;;
  esac
}

http_flow() {
  if ! _tesi_require_context; then
    printf 'ERROR kind=local-context\n' >&2
    return 70
  fi
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: http_flow POD_SORGENTE POD_DESTINAZIONE\n' >&2
    return 70
  fi

  local source_pod="$1"
  local destination_pod="$2"
  local destination_ip
  local probe_rc
  local denial_control
  local denial_control_rc
  if ! destination_ip="$(kubectl --context "$TESI_CONTEXT" get pod \
      -n net-lab "$destination_pod" \
      -o jsonpath='{.status.podIP}')"; then
    printf 'ERROR kind=kubectl-api pod=%s\n' "$destination_pod" >&2
    return 70
  fi
  if ! _tesi_is_ipv4 "$destination_ip"; then
    printf 'ERROR kind=invalid-pod-ip pod=%s value=%q\n' \
      "$destination_pod" "$destination_ip" >&2
    return 70
  fi

  if _tesi_wget_probe "$source_pod" \
      "http://${destination_ip}:8080/" "$destination_pod"; then
    return 0
  else
    probe_rc=$?
  fi

  if [[ "$probe_rc" -ne 10 ]]; then
    return "$probe_rc"
  fi

  if denial_control="$(_tesi_wget_probe "$destination_pod" \
      'http://127.0.0.1:8080/' "$destination_pod")"; then
    printf 'deny_control=PASS destination=%s\n' "$destination_pod"
    return 10
  else
    denial_control_rc=$?
  fi

  printf 'ERROR kind=deny-control destination=%s rc=%s\n%s\n' \
    "$destination_pod" "$denial_control_rc" "$denial_control" >&2
  return 73
}

_tesi_expect() {
  local expected="$1"
  local source_pod="$2"
  local destination_pod="$3"
  local rc

  if http_flow "$source_pod" "$destination_pod"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$expected" == ALLOW && "$rc" -eq 0 ]] || \
      [[ "$expected" == DENY && "$rc" -eq 10 ]]; then
    printf 'PASS expected=%s flow=%s->%s rc=%s\n' \
      "$expected" "$source_pod" "$destination_pod" "$rc"
    return 0
  fi

  printf 'FAIL expected=%s flow=%s->%s rc=%s\n' \
    "$expected" "$source_pod" "$destination_pod" "$rc" >&2
  return 1
}

expect_allow() {
  _tesi_expect ALLOW "$1" "$2"
}

expect_deny() {
  _tesi_expect DENY "$1" "$2"
}

run_policy_matrix() {
  if [[ "$#" -ne 1 ]]; then
    printf 'Uso: run_policy_matrix allow-all|deny-all|selective-allow\n' >&2
    return 2
  fi

  local mode="$1"
  local passed=0
  local failed=0
  local expected_allowed
  local expected_denied
  local expectation
  local source_pod
  local destination_pod
  local repetition

  case "$mode" in
    allow-all)
      expected_allowed=6
      expected_denied=0
      ;;
    deny-all)
      expected_allowed=0
      expected_denied=6
      ;;
    selective-allow)
      expected_allowed=4
      expected_denied=2
      ;;
    *)
      printf 'Modalità matrice non valida: %s\n' "$mode" >&2
      return 2
      ;;
  esac

  while read -r source_pod destination_pod; do
    for repetition in 1 2; do
      expectation=allow
      if [[ "$mode" == deny-all ]]; then
        expectation=deny
      elif [[ "$mode" == selective-allow && "$source_pod" == server-a ]]; then
        expectation=deny
      fi

      if [[ "$expectation" == allow ]]; then
        if expect_allow "$source_pod" "$destination_pod"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
      elif expect_deny "$source_pod" "$destination_pod"; then
        passed=$((passed + 1))
      else
        failed=$((failed + 1))
      fi
    done
  done <<'EOF'
client server-a
client server-b
server-a server-b
EOF

  printf 'matrix_summary mode=%s expected_allowed=%s expected_denied=%s passed=%s failed=%s total=6\n' \
    "$mode" "$expected_allowed" "$expected_denied" "$passed" "$failed"
  [[ "$failed" -eq 0 ]]
}

service_http_flows() {
  if ! _tesi_require_context; then
    printf 'ERROR: contesto Service non definito.\n' >&2
    return 1
  fi

  local attempts="${1:-6}"
  local service_ip
  local attempt
  local body
  local rc
  local failed=0

  if [[ ! "$attempts" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Il numero di connessioni deve essere un intero positivo.\n' >&2
    return 2
  fi

  if ! service_ip="$(kubectl --context "$TESI_CONTEXT" get service -n net-lab \
      servers -o jsonpath='{.spec.clusterIP}')"; then
    printf 'ERROR: lettura ClusterIP del Service fallita.\n' >&2
    return 1
  fi
  if ! _tesi_is_ipv4 "$service_ip"; then
    printf 'ERROR: ClusterIP del Service non valido: %q.\n' "$service_ip" >&2
    return 1
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if body="$(_tesi_wget_probe client \
        "http://${service_ip}:8080/" server-a server-b)"; then
      rc=0
    else
      rc=$?
      failed=$((failed + 1))
    fi
    printf 'attempt=%s probe_rc=%s\n%s\n' "$attempt" "$rc" "$body"
  done

  [[ "$failed" -eq 0 ]]
}

capture_service_iptables_snapshot() {
  if [[ "$#" -ne 3 ]]; then
    printf 'Uso: capture_service_iptables_snapshot NODO FILE_COMPLETO FILE_FILTRATO\n' >&2
    return 2
  fi

  local node_name="$1"
  local full_output="$2"
  local filtered_output="$3"
  local grep_rc

  if ! docker exec "$node_name" /bin/aux/iptables-save -c -t nat \
      >"$full_output"; then
    printf 'ERROR: acquisizione iptables fallita sul nodo %s.\n' \
      "$node_name" >&2
    return 1
  fi
  if [[ ! -s "$full_output" ]]; then
    printf 'ERROR: snapshot iptables completo vuoto sul nodo %s.\n' \
      "$node_name" >&2
    return 1
  fi

  if grep -F 'net-lab/servers:http' "$full_output" >"$filtered_output"; then
    grep_rc=0
  else
    grep_rc=$?
  fi
  case "$grep_rc" in
    0) ;;
    1)
      printf 'ERROR: regole Service net-lab/servers:http non trovate sul nodo %s.\n' \
        "$node_name" >&2
      return 1
      ;;
    *)
      printf 'ERROR: filtro dello snapshot iptables fallito (grep rc=%s).\n' \
        "$grep_rc" >&2
      return 1
      ;;
  esac

  if [[ ! -s "$filtered_output" ]]; then
    printf 'ERROR: snapshot iptables filtrato vuoto sul nodo %s.\n' \
      "$node_name" >&2
    return 1
  fi
}

printf 'Ambiente comune caricato: repo=%s\n' "$TESI_REPO_ROOT"
