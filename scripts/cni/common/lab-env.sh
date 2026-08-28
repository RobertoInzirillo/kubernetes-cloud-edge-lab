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
      function has_endpoint(text, ip, pattern) {
        pattern=ip
        gsub(/\./, "\\.", pattern)
        return text ~ ("(^|[^0-9.])" pattern "\\.[0-9]+([^0-9]|$)")
      }
      function has_protocol(text, protocol) {
        return text ~ ("(^|[^[:alnum:]_])" protocol \
          "([^[:alnum:]_]|$)")
      }
      function has_port(text, port) {
        return text ~ ("\\." port "([^0-9]|$)") || \
          text ~ ("port[[:space:]]+" port "([^0-9]|$)")
      }
      {
        window=previous_two ORS previous_one ORS $0
        if (has_endpoint(window, source) && \
            has_endpoint(window, destination) && \
            has_protocol(window, "TCP") && has_port(window, 8080)) {
          found=1
        }
        previous_two=previous_one
        previous_one=$0
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
      function has_endpoint(text, ip, pattern) {
        pattern=ip
        gsub(/\./, "\\.", pattern)
        return text ~ ("(^|[^0-9.])" pattern "\\.[0-9]+([^0-9]|$)")
      }
      function has_protocol(text, protocol) {
        return text ~ ("(^|[^[:alnum:]_])" protocol \
          "([^[:alnum:]_]|$)")
      }
      function has_port(text, expected_port) {
        return text ~ ("\\." expected_port "([^0-9]|$)") || \
          text ~ ("port[[:space:]]+" expected_port "([^0-9]|$)")
      }
      {
        window=previous_two ORS previous_one ORS $0
        if (has_endpoint(window, source) && \
            has_endpoint(window, destination) && \
            has_protocol(window, "UDP") && has_port(window, port)) {
          found=1
        }
        previous_two=previous_one
        previous_one=$0
      }
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

wait_for_policy_convergence() {
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: wait_for_policy_convergence k3s|calico default-deny|selective-allow|restored\n' >&2
    return 2
  fi
  if ! _tesi_require_context; then
    return 2
  fi

  local dataplane="$1"
  local expected_state="$2"
  local deadline=$((SECONDS + 90))
  local pod_inventory
  local pod
  local node
  local pod_ip
  local extra
  local route_output
  local interface_name
  local iptables_output
  local line
  local default_chain
  local default_link
  local allow_chain
  local allow_link
  local default_chain_name
  local allow_chain_name
  local discovered_chain_name
  local pod_default_link
  local pod_allow_link
  local workload_policy_link
  local pending
  local -a workload_nodes=()
  local -A expected_pods=(
    [client]=1
    [server-a]=1
    [server-b]=1
  )
  local -A seen_pods=()
  local -A seen_nodes=()
  local -A target_nodes=()
  local -A pod_nodes=()
  local -A pod_ips=()
  local -A pod_interfaces=()

  case "$dataplane" in
    k3s|calico) ;;
    *)
      printf 'ERROR: dataplane policy non valido: %s.\n' "$dataplane" >&2
      return 2
      ;;
  esac
  case "$expected_state" in
    default-deny|selective-allow|restored) ;;
    *)
      printf 'ERROR: stato convergenza policy non valido: %s.\n' \
        "$expected_state" >&2
      return 2
      ;;
  esac

  if ! pod_inventory="$(kubectl --context "$TESI_CONTEXT" get pods \
      -n net-lab client server-a server-b \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{.status.podIP}{"\n"}{end}')"; then
    printf 'ERROR: inventario Pod/nodo per la convergenza policy fallito.\n' >&2
    return 2
  fi
  while IFS='|' read -r pod node pod_ip extra; do
    if [[ -n "$extra" || -z "${expected_pods[$pod]:-}" || \
          -n "${seen_pods[$pod]:-}" || \
          ! "$node" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
       ! _tesi_is_ipv4 "$pod_ip"; then
      printf 'ERROR: record Pod/nodo policy non valido: %q.\n' \
        "$pod_inventory" >&2
      return 2
    fi
    seen_pods["$pod"]=1
    pod_nodes["$pod"]="$node"
    pod_ips["$pod"]="$pod_ip"
    if [[ -z "${seen_nodes[$node]:-}" ]]; then
      seen_nodes["$node"]=1
      workload_nodes+=("$node")
    fi
    if [[ "$pod" == server-a || "$pod" == server-b ]]; then
      target_nodes["$node"]=1
    fi
  done <<< "$pod_inventory"
  if [[ "${#seen_pods[@]}" -ne 3 || "${#target_nodes[@]}" -eq 0 ]]; then
    printf 'ERROR: inventario workload policy incompleto o incoerente.\n' >&2
    return 2
  fi

  if [[ "$dataplane" == calico ]]; then
    for pod in client server-a server-b; do
      node="${pod_nodes[$pod]}"
      if ! route_output="$(docker exec "$node" \
          ip -o route get "${pod_ips[$pod]}")"; then
        printf 'ERROR: route workload Calico non leggibile per %s su %s.\n' \
          "$pod" "$node" >&2
        return 2
      fi
      if [[ -z "$route_output" || "$route_output" == *$'\n'* || \
            ! "$route_output" =~ (^|[[:space:]])dev[[:space:]]+(cali[a-zA-Z0-9_.-]+)($|[[:space:]]) ]]; then
        printf 'ERROR: interfaccia workload Calico non interpretabile per %s: %q.\n' \
          "$pod" "$route_output" >&2
        return 2
      fi
      interface_name="${BASH_REMATCH[2]}"
      pod_interfaces["$pod"]="$interface_name"
    done
  fi

  while true; do
    pending=0
    for node in "${workload_nodes[@]}"; do
      if ! iptables_output="$(docker exec "$node" \
          /bin/aux/iptables-save -c)"; then
        printf 'ERROR: lettura dataplane policy fallita sul nodo %s.\n' \
          "$node" >&2
        return 2
      fi
      if [[ -z "$iptables_output" || "$iptables_output" != *'*filter'* || \
            "$iptables_output" != *'COMMIT'* ]]; then
        printf 'ERROR: dump iptables non interpretabile sul nodo %s.\n' \
          "$node" >&2
        return 2
      fi

      default_chain=0
      default_link=0
      allow_chain=0
      allow_link=0
      default_chain_name=''
      allow_chain_name=''
      workload_policy_link=0
      while IFS= read -r line; do
        if [[ "$dataplane" == k3s ]]; then
          [[ "$line" == *'-A KUBE-NWPLCY-'* && \
             "$line" == *'net-lab/default-deny-ingress'* ]] && \
            default_chain=1
          [[ "$line" == *'-A KUBE-POD-FW-'* && \
             "$line" == *'run through nw policy default-deny-ingress'* ]] && \
            default_link=1
          [[ "$line" == *'-A KUBE-NWPLCY-'* && \
             "$line" == *'net-lab/allow-client-to-http-servers'* ]] && \
            allow_chain=1
          [[ "$line" == *'-A KUBE-POD-FW-'* && \
             "$line" == *'run through nw policy allow-client-to-http-servers'* ]] && \
            allow_link=1
        else
          if [[ "$line" == *'KubernetesNetworkPolicy net-lab/default-deny-ingress ingress'* ]]; then
            if [[ ! "$line" =~ -A[[:space:]]+(cali-pi-[^[:space:]]+).*KubernetesNetworkPolicy[[:space:]]+net-lab/default-deny-ingress[[:space:]]+ingress ]]; then
              printf 'ERROR: chain Calico default-deny non interpretabile su %s.\n' \
                "$node" >&2
              return 2
            fi
            discovered_chain_name="${BASH_REMATCH[1]}"
            if [[ -n "$default_chain_name" && \
                  "$default_chain_name" != "$discovered_chain_name" ]]; then
              printf 'ERROR: chain Calico default-deny ambigua su %s.\n' \
                "$node" >&2
              return 2
            fi
            default_chain_name="$discovered_chain_name"
            default_chain=1
          fi
          if [[ "$line" == *'KubernetesNetworkPolicy net-lab/allow-client-to-http-servers ingress'* ]]; then
            if [[ ! "$line" =~ -A[[:space:]]+(cali-pi-[^[:space:]]+).*KubernetesNetworkPolicy[[:space:]]+net-lab/allow-client-to-http-servers[[:space:]]+ingress ]]; then
              printf 'ERROR: chain Calico selective-allow non interpretabile su %s.\n' \
                "$node" >&2
              return 2
            fi
            discovered_chain_name="${BASH_REMATCH[1]}"
            if [[ -n "$allow_chain_name" && \
                  "$allow_chain_name" != "$discovered_chain_name" ]]; then
              printf 'ERROR: chain Calico selective-allow ambigua su %s.\n' \
                "$node" >&2
              return 2
            fi
            allow_chain_name="$discovered_chain_name"
            allow_chain=1
          fi
        fi
      done <<< "$iptables_output"

      if [[ "$dataplane" == calico ]]; then
        default_link=1
        if [[ -n "${target_nodes[$node]:-}" ]]; then
          allow_link=1
        else
          allow_link=0
        fi
        for pod in client server-a server-b; do
          [[ "${pod_nodes[$pod]}" == "$node" ]] || continue
          interface_name="${pod_interfaces[$pod]}"
          pod_default_link=0
          pod_allow_link=0
          while IFS= read -r line; do
            if [[ "$line" == *"-A cali-tw-${interface_name} "* && \
                  "$line" == *'-j cali-pi-'* ]]; then
              workload_policy_link=1
            fi
            if [[ -n "$default_chain_name" && \
                  "$line" == *"-A cali-tw-${interface_name} "* && \
                  "$line" == *"-j ${default_chain_name}"* ]]; then
              pod_default_link=1
            fi
            if [[ -n "$allow_chain_name" && \
                  "$line" == *"-A cali-tw-${interface_name} "* && \
                  "$line" == *"-j ${allow_chain_name}"* ]]; then
              pod_allow_link=1
            fi
          done <<< "$iptables_output"
          [[ "$pod_default_link" -eq 1 ]] || default_link=0
          if [[ "$pod" == server-a || "$pod" == server-b ]]; then
            [[ "$pod_allow_link" -eq 1 ]] || allow_link=0
          fi
        done
      fi

      case "$expected_state" in
        default-deny)
          [[ "$default_chain" -eq 1 && "$default_link" -eq 1 ]] || \
            pending=1
          ;;
        selective-allow)
          [[ "$default_chain" -eq 1 && "$default_link" -eq 1 ]] || \
            pending=1
          if [[ -n "${target_nodes[$node]:-}" ]]; then
            [[ "$allow_chain" -eq 1 && "$allow_link" -eq 1 ]] || \
              pending=1
          fi
          ;;
        restored)
          [[ "$default_chain" -eq 0 && "$default_link" -eq 0 && \
             "$allow_chain" -eq 0 && "$allow_link" -eq 0 && \
             "$workload_policy_link" -eq 0 ]] || \
            pending=1
          ;;
      esac
    done

    if [[ "$pending" -eq 0 ]]; then
      printf 'PASS: dataplane %s convergente per lo stato %s su %s nodi.\n' \
        "$dataplane" "$expected_state" "${#workload_nodes[@]}"
      return 0
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'FAIL: timeout di 90s attendendo la convergenza policy %s.\n' \
        "$expected_state" >&2
      return 1
    fi
    sleep 1
  done
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

_tesi_parse_service_http_observations() {
  if [[ "$#" -ne 1 ]]; then
    printf 'Uso interno: _tesi_parse_service_http_observations FILE.\n' >&2
    return 2
  fi
  if [[ ! -s "$1" ]]; then
    printf 'ERROR: output HTTP Service assente o vuoto: %s.\n' "$1" >&2
    return 2
  fi

  awk '
    function fail(message) {
      print "ERROR: output HTTP Service ambiguo: " message "." > "/dev/stderr"
      parser_error = 1
      exit
    }
    function field_value(token, prefix) {
      return substr(token, length(prefix) + 1)
    }
    function finish_record(    status) {
      if (!active) return
      if (attempt !~ /^[1-9][0-9]*$/ || seen_attempt[attempt]++)
        fail("numero di tentativo non valido o duplicato")
      if (backend != "server-a" && backend != "server-b")
        fail("backend mancante o non valido al tentativo " attempt)
      status = (probe_seen ? probe_rc : exit_rc)
      if ((!probe_seen && !exit_seen) || status != "0" ||
          (probe_seen && exit_seen && probe_rc != exit_rc))
        fail("esito non riuscito o incoerente al tentativo " attempt)
      attempts[++count] = attempt
      backends[count] = backend
      active = probe_seen = exit_seen = 0
      attempt = backend = probe_rc = exit_rc = ""
    }
    /^[[:space:]]*$/ { next }
    /^attempt=/ {
      finish_record()
      active = 1
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^attempt=/) {
          if (attempt != "") fail("campo attempt duplicato")
          attempt = field_value($i, "attempt=")
        } else if ($i ~ /^response=/) {
          if (backend != "") fail("campo response duplicato")
          backend = field_value($i, "response=")
        } else if ($i ~ /^probe_rc=/) {
          if (probe_seen) fail("campo probe_rc duplicato")
          probe_seen = 1
          probe_rc = field_value($i, "probe_rc=")
        } else if ($i ~ /^exit=/) {
          if (exit_seen) fail("campo exit duplicato")
          exit_seen = 1
          exit_rc = field_value($i, "exit=")
        }
      }
      next
    }
    /^response=/ {
      if (!active || backend != "" || NF != 1)
        fail("riga response fuori record o ambigua")
      backend = field_value($1, "response=")
      next
    }
    /^exit_code=/ {
      if (!active || exit_seen || NF != 1)
        fail("riga exit_code fuori record o ambigua")
      exit_seen = 1
      exit_rc = field_value($1, "exit_code=")
      next
    }
    { fail("riga non riconosciuta") }
    END {
      if (parser_error) exit 2
      finish_record()
      if (parser_error) exit 2
      if (count == 0) {
        print "ERROR: nessuna osservazione HTTP Service valida." > "/dev/stderr"
        exit 2
      }
      for (i = 1; i <= count; i++)
        print attempts[i], backends[i]
    }
  ' "$1"
}

_tesi_verify_service_iptables_counters() {
  if [[ "$#" -ne 9 ]]; then
    printf 'Uso interno: _tesi_verify_service_iptables_counters MODE SERVICE_IP PORTA IP_A IP_B OSS_A OSS_B PRIMA DOPO.\n' >&2
    return 2
  fi

  local mode="$1"
  local service_ip="$2"
  local service_port="$3"
  local server_a_ip="$4"
  local server_b_ip="$5"
  local observed_a="$6"
  local observed_b="$7"
  local before_file="$8"
  local after_file="$9"

  if [[ "$mode" != attribution && "$mode" != invariant ]]; then
    printf 'ERROR: modalità confronto iptables non valida: %s.\n' "$mode" >&2
    return 2
  fi
  if ! _tesi_is_ipv4 "$service_ip" || ! _tesi_is_ipv4 "$server_a_ip" ||
      ! _tesi_is_ipv4 "$server_b_ip" ||
      [[ ! "$service_port" =~ ^[1-9][0-9]*$ ]] ||
      [[ ! "$observed_a" =~ ^[0-9]+$ ]] ||
      [[ ! "$observed_b" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: parametri del confronto iptables non validi.\n' >&2
    return 2
  fi
  if [[ ! -s "$before_file" || ! -s "$after_file" ]]; then
    printf 'ERROR: snapshot iptables prima/dopo assente o vuoto.\n' >&2
    return 2
  fi

  awk -v mode="$mode" -v service_ip="$service_ip" \
      -v port="$service_port" -v ip_a="$server_a_ip" \
      -v ip_b="$server_b_ip" -v observed_a="$observed_a" \
      -v observed_b="$observed_b" -v before_file="$before_file" '
    function error(message) {
      print "ERROR: parser iptables Service: " message "." > "/dev/stderr"
      parser_error = 1
    }
    function causal_fail(message) {
      print "FAIL: attribuzione Service: " message "." > "/dev/stderr"
      causal_error = 1
    }
    function jump_target(rule,    fields, count, i) {
      count = split(rule, fields, /[[:space:]]+/)
      for (i = 1; i < count; i++)
        if (fields[i] == "-j") return fields[i + 1]
      return ""
    }
    function source_chain(rule,    fields) {
      split(rule, fields, /[[:space:]]+/)
      return (fields[1] == "-A" ? fields[2] : "")
    }
    function packet_delta(key) {
      return packet[2, key] - packet[1, key]
    }
    function byte_delta(key) {
      return bytes[2, key] - bytes[1, key]
    }
    {
      if (index($0, "net-lab/servers:http") == 0) next
      side = (FILENAME == before_file ? 1 : 2)
      first = $1
      if (first !~ /^\[[0-9][0-9]*:[0-9][0-9]*\]$/) {
        error("contatore non numerico in " FILENAME " riga " FNR)
        next
      }
      counters = first
      sub(/^\[/, "", counters)
      sub(/\]$/, "", counters)
      split(counters, values, ":")
      rule = $0
      sub(/^[^[:space:]]+[[:space:]]+/, "", rule)
      if ((side, rule) in packet) {
        error("regola duplicata in " FILENAME)
        next
      }
      packet[side, rule] = values[1] + 0
      bytes[side, rule] = values[2] + 0
      rules[rule] = 1
      count[side]++
    }
    END {
      if (parser_error) exit 2
      if (count[1] == 0 || count[2] == 0) {
        error("nessuna regola pertinente in uno snapshot")
        exit 2
      }
      for (rule in rules) {
        if (!((1, rule) in packet) || !((2, rule) in packet)) {
          error("snapshot strutturalmente incompatibili")
          continue
        }
        if (packet[2, rule] < packet[1, rule] ||
            bytes[2, rule] < bytes[1, rule])
          error("contatore diminuito")
        chain = source_chain(rule)
        target = jump_target(rule)
        if (chain == "KUBE-SERVICES" &&
            index(rule, "-d " service_ip "/32") &&
            index(rule, "--dport " port) && target ~ /^KUBE-SVC-/) {
          service_matches++
          service_rule = rule
          service_chain = target
        }
      }
      if (parser_error) exit 2
      if (service_matches != 1) {
        error("regola KUBE-SERVICES assente o ambigua")
        exit 2
      }
      for (rule in rules) {
        chain = source_chain(rule)
        target = jump_target(rule)
        if (chain == service_chain && target ~ /^KUBE-SEP-/) {
          if (index(rule, "net-lab/servers:http -> " ip_a ":" port)) {
            branch_a_matches++
            branch_a = rule
            sep_a = target
          }
          if (index(rule, "net-lab/servers:http -> " ip_b ":" port)) {
            branch_b_matches++
            branch_b = rule
            sep_b = target
          }
        }
      }
      if (branch_a_matches != 1 || branch_b_matches != 1 || sep_a == sep_b) {
        error("mapping backend KUBE-SVC/KUBE-SEP assente o ambiguo")
        exit 2
      }
      for (rule in rules) {
        chain = source_chain(rule)
        target = jump_target(rule)
        if (target == "DNAT" &&
            index(rule, "--to-destination " ip_a ":" port) &&
            chain == sep_a) {
          dnat_a_matches++
          dnat_a = rule
        }
        if (target == "DNAT" &&
            index(rule, "--to-destination " ip_b ":" port) &&
            chain == sep_b) {
          dnat_b_matches++
          dnat_b = rule
        }
      }
      if (dnat_a_matches != 1 || dnat_b_matches != 1) {
        error("regola DNAT KUBE-SEP assente o ambigua")
        exit 2
      }

      service_packets = packet_delta(service_rule)
      service_bytes = byte_delta(service_rule)
      delta_a = packet_delta(dnat_a)
      delta_b = packet_delta(dnat_b)
      printf "delta_kube_services_packets=%s bytes=%s\n", service_packets, service_bytes
      printf "delta_kube_sep backend=server-a ip=%s packets=%s bytes=%s\n", \
        ip_a, delta_a, byte_delta(dnat_a)
      printf "delta_kube_sep backend=server-b ip=%s packets=%s bytes=%s\n", \
        ip_b, delta_b, byte_delta(dnat_b)

      if (mode == "attribution") {
        if (observed_a + observed_b == 0)
          error("nessun backend HTTP osservato")
        if (service_packets <= 0 || service_bytes <= 0)
          causal_fail("nessun delta positivo sulla regola KUBE-SERVICES")
        if (observed_a > 0 && delta_a <= 0)
          causal_fail("backend HTTP server-a senza delta DNAT coerente")
        if (observed_b > 0 && delta_b <= 0)
          causal_fail("backend HTTP server-b senza delta DNAT coerente")
      } else {
        for (rule in rules)
          if (packet_delta(rule) != 0 || byte_delta(rule) != 0)
            causal_fail("contatore kube-proxy pertinente variato")
      }
      if (parser_error) exit 2
      if (causal_error) exit 1
      if (mode == "attribution")
        print "PASS: attribuzione kube-proxy/iptables causalmente verificata."
      else
        print "PASS: contatori kube-proxy pertinenti invariati."
    }
  ' "$before_file" "$after_file"
}

verify_kube_proxy_service_attribution() {
  if [[ "$#" -ne 7 ]]; then
    printf 'Uso: verify_kube_proxy_service_attribution SERVICE_IP PORTA IP_A IP_B HTTP PRIMA DOPO.\n' >&2
    return 2
  fi
  local observations
  local parser_rc
  local observed_a=0
  local observed_b=0
  local attempt
  local backend

  if observations="$(_tesi_parse_service_http_observations "$5")"; then
    :
  else
    parser_rc=$?
    return "$parser_rc"
  fi
  while read -r attempt backend; do
    case "$backend" in
      server-a) observed_a=$((observed_a + 1)) ;;
      server-b) observed_b=$((observed_b + 1)) ;;
      *)
        printf 'ERROR: backend HTTP normalizzato non riconosciuto: %s.\n' \
          "$backend" >&2
        return 2
        ;;
    esac
  done <<< "$observations"
  printf 'backend_http_osservati server-a=%s server-b=%s\n' \
    "$observed_a" "$observed_b"

  _tesi_verify_service_iptables_counters attribution \
    "$1" "$2" "$3" "$4" "$observed_a" "$observed_b" "$6" "$7"
}

verify_kube_proxy_service_invariance() {
  if [[ "$#" -ne 6 ]]; then
    printf 'Uso: verify_kube_proxy_service_invariance SERVICE_IP PORTA IP_A IP_B PRIMA DOPO.\n' >&2
    return 2
  fi
  _tesi_verify_service_iptables_counters invariant \
    "$1" "$2" "$3" "$4" 0 0 "$5" "$6"
}

verify_cilium_service_ct_lb() {
  if [[ "$#" -ne 12 ]]; then
    printf 'Uso: verify_cilium_service_ct_lb SERVICE_IP PORTA CLIENT_IP IP_A IP_B HTTP CT_PRIMA CT_DOPO FRONTEND BACKEND REVNAT CORRELAZIONE.\n' >&2
    return 2
  fi

  local service_ip="$1"
  local service_port="$2"
  local client_ip="$3"
  local server_a_ip="$4"
  local server_b_ip="$5"
  local http_file="$6"
  local ct_before="$7"
  local ct_after="$8"
  local frontend_file="$9"
  local backend_file="${10}"
  local revnat_file="${11}"
  local correlation_file="${12}"
  local observations
  local parser_rc
  local required_file
  local expected_a=0
  local expected_b=0
  local attempt
  local backend
  local correlation_temp

  if ! _tesi_is_ipv4 "$service_ip" || ! _tesi_is_ipv4 "$client_ip" ||
      ! _tesi_is_ipv4 "$server_a_ip" || ! _tesi_is_ipv4 "$server_b_ip" ||
      [[ ! "$service_port" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: parametri Cilium Service non validi.\n' >&2
    return 2
  fi
  for required_file in "$http_file" "$ct_before" "$ct_after" \
      "$frontend_file" "$backend_file" "$revnat_file"; do
    if [[ ! -s "$required_file" ]]; then
      printf 'ERROR: fixture Cilium Service assente o vuota: %s.\n' \
        "$required_file" >&2
      return 2
    fi
  done
  if observations="$(_tesi_parse_service_http_observations "$http_file")"; then
    :
  else
    parser_rc=$?
    return "$parser_rc"
  fi
  while read -r attempt backend; do
    case "$backend" in
      server-a) expected_a=$((expected_a + 1)) ;;
      server-b) expected_b=$((expected_b + 1)) ;;
      *)
        printf 'ERROR: backend HTTP Cilium non riconosciuto: %s.\n' \
          "$backend" >&2
        return 2
        ;;
    esac
  done <<< "$observations"
  printf 'backend_http_osservati server-a=%s server-b=%s\n' \
    "$expected_a" "$expected_b"

  if ! correlation_temp="$(mktemp "${correlation_file}.XXXXXX")"; then
    printf 'ERROR: creazione correlazione CT temporanea fallita.\n' >&2
    return 2
  fi

  if awk -v service_ip="$service_ip" -v port="$service_port" \
      -v client_ip="$client_ip" -v ip_a="$server_a_ip" \
      -v ip_b="$server_b_ip" -v expected_a="$expected_a" \
      -v expected_b="$expected_b" -v before_file="$ct_before" '
    function parser_error(message) {
      print "ERROR: parser Cilium CT: " message "." > "/dev/stderr"
      malformed = 1
    }
    function causal_fail(message) {
      print "FAIL: attribuzione Cilium CT: " message "." > "/dev/stderr"
      causal = 1
    }
    function value(prefix,    i) {
      for (i = 1; i <= NF; i++)
        if (index($i, prefix) == 1) return substr($i, length(prefix) + 1)
      return ""
    }
    function endpoint_port(endpoint,    parts, count) {
      count = split(endpoint, parts, ":")
      return (count == 2 ? parts[2] : "")
    }
    function endpoint_ip(endpoint,    parts, count) {
      count = split(endpoint, parts, ":")
      return (count == 2 ? parts[1] : "")
    }
    {
      side = (FILENAME == before_file ? 1 : 2)
      source = client_ip ":"
      destination = service_ip ":" port
      if ($1 == "TCP" && $2 == "SVC" && index($3, source) == 1 &&
          $4 == "->" && $5 == destination) {
        source_port = endpoint_port($3)
        revnat = value("RevNAT=")
        backend_id = value("BackendID=")
        flags = value("Flags=")
        tx_flags = value("TxFlagsSeen=")
        if (source_port !~ /^[1-9][0-9]*$/ ||
            revnat !~ /^[1-9][0-9]*$/ ||
            backend_id !~ /^[1-9][0-9]*$/ ||
            flags !~ /^0x[0-9a-fA-F][0-9a-fA-F]*$/ ||
            tx_flags !~ /^0x[0-9a-fA-F][0-9a-fA-F]*$/) {
          parser_error("entry TCP SVC pertinente malformata")
          next
        }
        key = source_port SUBSEP revnat SUBSEP backend_id
        if ((side, key) in svc) {
          parser_error("entry TCP SVC pertinente duplicata")
          next
        }
        svc[side, key] = 1
        svc_tx[side, key] = tx_flags
        svc_keys[key] = 1
        if (side == 2) {
          svc_port[key] = source_port
          svc_revnat[key] = revnat
          svc_backend[key] = backend_id
        }
        next
      }
      if (side == 2 && $1 == "TCP" && $2 == "OUT" &&
          index($3, source) == 1 && $4 == "->" &&
          endpoint_port($5) == port) {
        source_port = endpoint_port($3)
        backend_ip = endpoint_ip($5)
        revnat = value("RevNAT=")
        if (source_port !~ /^[1-9][0-9]*$/ ||
            (backend_ip != ip_a && backend_ip != ip_b) ||
            revnat !~ /^[1-9][0-9]*$/) next
        out_count[source_port]++
        out_ip[source_port] = backend_ip
        out_revnat[source_port] = revnat
      }
    }
    END {
      if (malformed) exit 2
      for (key in svc_keys) {
        if ((2, key) in svc && !((1, key) in svc)) {
          new_count++
          source_port = svc_port[key]
          if (svc_tx[2, key] == "0x00" || svc_tx[2, key] == "0x0") {
            causal_fail("entry TCP SVC senza stato trasmesso coerente")
            continue
          }
          if (out_count[source_port] != 1) {
            parser_error("mapping TCP SVC/TCP OUT assente o ambiguo")
            continue
          }
          if (out_revnat[source_port] != svc_revnat[key]) {
            parser_error("RevNAT incoerente fra TCP SVC e TCP OUT")
            continue
          }
          backend_ip = out_ip[source_port]
          backend_name = (backend_ip == ip_a ? "server-a" : "server-b")
          if (backend_name == "server-a") actual_a++
          else actual_b++
          records[new_count] = source_port " " backend_ip " " backend_name \
            " " svc_backend[key] " " svc_revnat[key]
        }
      }
      if (malformed) exit 2
      if (new_count == 0)
        causal_fail("nessuna nuova entry TCP SVC pertinente")
      if (new_count != expected_a + expected_b)
        causal_fail("numero di nuove entry TCP SVC diverso dai flussi HTTP")
      if (actual_a != expected_a || actual_b != expected_b)
        causal_fail("backend CT non coerenti con le risposte HTTP")
      if (causal) exit 1
      for (i = 1; i <= new_count; i++) print records[i]
    }
  ' "$ct_before" "$ct_after" >"$correlation_temp"; then
    :
  else
    parser_rc=$?
    rm -f -- "$correlation_temp"
    return "$parser_rc"
  fi

  if awk -v service_ip="$service_ip" -v port="$service_port" \
      -v correlation_file="$correlation_temp" \
      -v frontend_file="$frontend_file" -v backend_file="$backend_file" '
    function parser_error(message) {
      print "ERROR: parser mappe Cilium LB: " message "." > "/dev/stderr"
      malformed = 1
    }
    function causal_fail(message) {
      print "FAIL: attribuzione Cilium LB: " message "." > "/dev/stderr"
      causal = 1
    }
    function numeric_parenthesis(value,    copy) {
      copy = value
      sub(/^\(/, "", copy)
      sub(/\)$/, "", copy)
      return (copy ~ /^[0-9][0-9]*$/ ? copy : "")
    }
    function valid_ipv4(value,    octets, count, i) {
      count = split(value, octets, ".")
      if (count != 4) return 0
      for (i = 1; i <= count; i++)
        if (octets[i] !~ /^[0-9][0-9]*$/ ||
            octets[i] + 0 < 0 || octets[i] + 0 > 255)
          return 0
      return 1
    }
    FILENAME == correlation_file {
      if (NF != 5 || $1 !~ /^[1-9][0-9]*$/ ||
          $4 !~ /^[1-9][0-9]*$/ || $5 !~ /^[1-9][0-9]*$/) {
        parser_error("record CT normalizzato malformato")
        next
      }
      ct_count++
      ct_source_port[ct_count] = $1
      ct_backend[ct_count] = $4
      ct_ip[ct_count] = $2
      ct_name[ct_count] = $3
      ct_revnat[ct_count] = $5
      next
    }
    FILENAME == frontend_file && $1 == service_ip ":" port "/TCP" {
      slot = numeric_parenthesis($2)
      backend_id = $3
      revnat = ""
      for (i = 4; i <= NF; i++) {
        candidate = numeric_parenthesis($i)
        if (candidate != "") revnat = candidate
      }
      if (slot == "" || backend_id !~ /^[0-9][0-9]*$/ ||
          revnat !~ /^[1-9][0-9]*$/) {
        parser_error("frontend Service malformato")
        next
      }
      if (slot == 0) {
        main_count++
        main_revnat = revnat
      } else {
        frontend_backend[backend_id]++
        frontend_revnat[backend_id] = revnat
      }
      next
    }
    FILENAME == backend_file {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($1 == "ID" && $2 == "BACKEND") next
      if (NF != 2 || $1 !~ /^[1-9][0-9]*$/) {
        parser_error("riga backend map malformata")
        next
      }

      id = $1
      raw_backend = $2
      protocol = map_ip = map_port = ""
      has_port = 0
      uri_count = split(raw_backend, uri, "://")
      if (uri_count == 2) {
        protocol = uri[1]
        map_ip = uri[2]
      } else {
        protocol_count = split(raw_backend, protocol_parts, "/")
        if (protocol_count != 2) {
          parser_error("protocollo backend map assente o ambiguo")
          next
        }
        protocol = protocol_parts[2]
        endpoint_count = split(protocol_parts[1], endpoint, ":")
        if (endpoint_count != 2) {
          parser_error("endpoint backend map malformato")
          next
        }
        map_ip = endpoint[1]
        map_port = endpoint[2]
        has_port = 1
      }
      if (protocol !~ /^[A-Z][A-Z0-9]*$/ || !valid_ipv4(map_ip) ||
          (has_port && map_port !~ /^[1-9][0-9]*$/)) {
        parser_error("protocollo, IP o porta backend map non validi")
        next
      }
      if (id in backend_ip) {
        if (backend_protocol[id] != protocol || backend_ip[id] != map_ip ||
            backend_has_port[id] != has_port ||
            (has_port && backend_port[id] != map_port))
          parser_error("backend ID associato a mapping differenti")
        else
          parser_error("backend ID duplicato")
        next
      }
      backend_map[id] = 1
      backend_protocol[id] = protocol
      backend_ip[id] = map_ip
      backend_has_port[id] = has_port
      if (has_port) backend_port[id] = map_port
      next
    }
    FILENAME != correlation_file && FILENAME != frontend_file &&
        FILENAME != backend_file && $1 ~ /^[1-9][0-9]*$/ {
      endpoint_count = split($2, endpoint, ":")
      sub(/\/TCP$/, "", endpoint[2])
      if (endpoint_count == 2 && endpoint[1] == service_ip &&
          endpoint[2] == port) {
        revnat_map[$1]++
      }
    }
    END {
      if (malformed) exit 2
      if (ct_count == 0) {
        parser_error("nessuna correlazione CT")
        exit 2
      }
      if (main_count != 1) {
        causal_fail("frontend principale del Service assente o ambiguo")
      }
      if (revnat_map[main_revnat] != 1) {
        causal_fail("mappa RevNAT del Service assente o ambigua")
      }
      for (i = 1; i <= ct_count; i++) {
        id = ct_backend[i]
        if (frontend_backend[id] != 1) {
          causal_fail("backend ID CT non correlabile al frontend Service")
          continue
        }
        if (backend_map[id] != 1) {
          causal_fail("backend ID CT assente dalla backend map")
          continue
        }
        if (backend_protocol[id] != "TCP") {
          causal_fail("protocollo backend map diverso da TCP")
          continue
        }
        if (backend_ip[id] != ct_ip[i]) {
          causal_fail("IP backend map diverso dalla TCP OUT correlata")
          continue
        }
        if (backend_has_port[id] && backend_port[id] != port) {
          causal_fail("porta esplicita backend map diversa dal flusso")
          continue
        }
        if (ct_revnat[i] != main_revnat ||
            frontend_revnat[id] != main_revnat) {
          causal_fail("RevNAT incoerente fra CT e mappe LB")
          continue
        }
      }
      if (malformed) exit 2
      if (causal) exit 1
      printf "cilium_lb_service=%s:%s revnat_id=%s ct_service_entries=%s\n", \
        service_ip, port, main_revnat, ct_count
      for (i = 1; i <= ct_count; i++)
        printf "cilium_backend source_port=%s backend=%s ip=%s backend_id=%s\n", \
          ct_source_port[i], ct_name[i], ct_ip[i], ct_backend[i]
    }
  ' "$correlation_temp" "$frontend_file" "$backend_file" "$revnat_file"; then
    :
  else
    parser_rc=$?
    rm -f -- "$correlation_temp"
    return "$parser_rc"
  fi

  if ! mv -f -- "$correlation_temp" "$correlation_file"; then
    printf 'ERROR: promozione correlazione CT/LB fallita.\n' >&2
    rm -f -- "$correlation_temp"
    return 2
  fi
  printf 'PASS: CT Service e mappe Cilium LB/backend/RevNAT coerenti.\n'
}

verify_cilium_service_hubble() {
  if [[ "$#" -ne 6 ]]; then
    printf 'Uso: verify_cilium_service_hubble HUBBLE CORRELAZIONE SINCE UNTIL CLIENT_IP PORTA.\n' >&2
    return 2
  fi
  if [[ ! -s "$2" ]] || ! _tesi_is_ipv4 "$5" ||
      [[ ! "$6" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: correlazione CT/Hubble assente o parametri non validi.\n' >&2
    return 2
  fi

  awk -v correlation_file="$2" -v since="$3" -v until="$4" \
      -v client_ip="$5" -v port="$6" '
    function valid_timestamp(value) {
      return value ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+Z$/
    }
    function valid_json_record(value,    i, char, quoted, escaped, braces, brackets) {
      if (substr(value, 1, 1) != "{" ||
          substr(value, length(value), 1) != "}") return 0
      for (i = 1; i <= length(value); i++) {
        char = substr(value, i, 1)
        if (quoted) {
          if (escaped) escaped = 0
          else if (char == "\\") escaped = 1
          else if (char == "\"") quoted = 0
          continue
        }
        if (char == "\"") quoted = 1
        else if (char == "{") braces++
        else if (char == "}") braces--
        else if (char == "[") brackets++
        else if (char == "]") brackets--
        if (braces < 0 || brackets < 0) return 0
      }
      return !quoted && !escaped && braces == 0 && brackets == 0
    }
    function extract_after(value, marker,    start, tail, finish) {
      start = index(value, marker)
      if (!start) return ""
      tail = substr(value, start + length(marker))
      finish = index(tail, "\"")
      return (finish ? substr(tail, 1, finish - 1) : "")
    }
    FILENAME == correlation_file {
      if (NF != 5 || $1 !~ /^[1-9][0-9]*$/) {
        parser_error = 1
        next
      }
      expected++
      expected_port[expected] = $1
      expected_ip[expected] = $2
      expected_name[expected] = $3
      next
    }
    {
      sub(/\r$/, "")
      if ($0 == "") next
      records++
      if (!valid_json_record($0)) {
        parser_error = 1
        next
      }
      compact = $0
      gsub(/[[:space:]]/, "", compact)
      timestamp = extract_after(compact, "\"flow\":{\"time\":\"")
      if (!valid_timestamp(timestamp)) {
        parser_error = 1
        next
      }
      if (timestamp < since || timestamp > until) next
      source_start = index(compact, "\"source\":{")
      destination_start = index(compact, "\"destination\":{")
      if (!source_start || !destination_start || destination_start <= source_start) {
        parser_error = 1
        next
      }
      source_object = substr(compact, source_start,
        destination_start - source_start)
      destination_object = substr(compact, destination_start)
      for (i = 1; i <= expected; i++) {
        ip_marker = "\"IP\":{\"source\":\"" client_ip \
          "\",\"destination\":\"" expected_ip[i] "\""
        tcp_marker = "\"TCP\":{\"source_port\":" expected_port[i] \
          ",\"destination_port\":" port
        if (index(compact, ip_marker) && index(compact, tcp_marker) &&
            index(compact, "\"verdict\":\"FORWARDED\"") &&
            index(source_object, "\"namespace\":\"net-lab\"") &&
            index(source_object, "\"pod_name\":\"client\"") &&
            index(destination_object, "\"namespace\":\"net-lab\"") &&
            index(destination_object,
              "\"pod_name\":\"" expected_name[i] "\""))
          found[i] = 1
      }
    }
    END {
      if (!valid_timestamp(since) || !valid_timestamp(until) || since > until)
        parser_error = 1
      if (parser_error) {
        print "ERROR: parser Hubble Service: JSONPB o finestra temporale non validi." > "/dev/stderr"
        exit 2
      }
      if (records == 0) exit 1
      for (i = 1; i <= expected; i++)
        if (!found[i]) missing++
      if (missing) exit 1
      printf "PASS: Hubble correla %s flussi CT controllati nella finestra %s / %s.\n", \
        expected, since, until
    }
  ' "$2" "$1"
}

printf 'Ambiente comune caricato: repo=%s\n' "$TESI_REPO_ROOT"
