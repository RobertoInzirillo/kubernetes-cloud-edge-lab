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

check_experiment_preflight() {
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: check_experiment_preflight NOME_CLUSTER PORTA_API\n' >&2
    return 2
  fi

  local cluster_name="$1"
  local api_port="$2"
  local blocked=0
  local cluster_list

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
      awk -v expected="$cluster_name" '$1 == expected { found=1 } END { exit !found }'; then
    printf 'STOP: esiste già il cluster %s.\n' "$cluster_name" >&2
    blocked=1
  fi

  if ss -H -ltn "sport = :${api_port}" | grep -q .; then
    printf 'STOP: la porta API %s è già in ascolto.\n' "$api_port" >&2
    ss -H -ltnp "sport = :${api_port}" || true
    blocked=1
  fi

  if pgrep -x tcpdump >/dev/null; then
    printf 'STOP: sono presenti processi tcpdump; verificarne la provenienza.\n' >&2
    pgrep -a -x tcpdump >&2 || true
    blocked=1
  fi

  if [[ "$blocked" -ne 0 ]]; then
    printf '%s\n' \
      "Non viene rimosso nulla automaticamente: riprendere l'analisi esistente" \
      "oppure eseguire consapevolmente il cleanup dell'esperimento precedente." >&2
    return 1
  fi

  printf 'PASS preflight: cluster=%s porta_api=%s tcpdump_residui=0\n' \
    "$cluster_name" "$api_port"
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
  kubectl --context "$TESI_CONTEXT" get pods -n net-lab -o wide
  kubectl --context "$TESI_CONTEXT" get service -n net-lab servers -o wide
  kubectl --context "$TESI_CONTEXT" get endpointslice -n net-lab \
    -l kubernetes.io/service-name=servers -o wide
}

verify_service_backends() {
  _tesi_require_context || return 1

  local endpoints
  local backend
  endpoints="$(kubectl --context "$TESI_CONTEXT" get endpointslice \
    -n net-lab -l kubernetes.io/service-name=servers \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.conditions.ready}{"\n"}{end}')" || \
    return 1
  printf '%s\n' "$endpoints"

  for backend in server-a server-b; do
    if ! printf '%s\n' "$endpoints" | \
        awk -v expected="$backend" '$1 == expected && $2 == "true" { found=1 } END { exit !found }'; then
      printf 'FAIL backend Ready non trovato: %s\n' "$backend" >&2
      return 1
    fi
  done

  printf 'PASS backend Ready: server-a server-b\n'
}

http_flow() {
  _tesi_require_context || return 1
  if [[ "$#" -ne 2 ]]; then
    printf 'Uso: http_flow POD_SORGENTE POD_DESTINAZIONE\n' >&2
    return 2
  fi

  local source_pod="$1"
  local destination_pod="$2"
  local destination_ip
  destination_ip="$(kubectl --context "$TESI_CONTEXT" get pod \
    -n net-lab "$destination_pod" \
    -o jsonpath='{.status.podIP}')" || return 1

  kubectl --context "$TESI_CONTEXT" exec -n net-lab \
    "$source_pod" -- sh -c '
      destination_ip="$1"
      body="$(wget -qO- -T 3 "http://${destination_ip}:8080/")"
      rc=$?
      printf "response=%s\nexit_code=%s\n" "$body" "$rc"
      exit "$rc"
    ' sh "$destination_ip"
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
      [[ "$expected" == DENY && "$rc" -ne 0 ]]; then
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
  _tesi_require_context || return 1

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

  service_ip="$(kubectl --context "$TESI_CONTEXT" get service -n net-lab \
    servers -o jsonpath='{.spec.clusterIP}')" || return 1

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if body="$(kubectl --context "$TESI_CONTEXT" exec -n net-lab client -- \
      wget -qO- -T 5 "http://${service_ip}:8080/")"; then
      rc=0
    else
      rc=$?
      failed=$((failed + 1))
    fi
    printf 'attempt=%s response=%s exit_code=%s\n' "$attempt" "$body" "$rc"
  done

  [[ "$failed" -eq 0 ]]
}

printf 'Ambiente comune caricato: repo=%s\n' "$TESI_REPO_ROOT"
