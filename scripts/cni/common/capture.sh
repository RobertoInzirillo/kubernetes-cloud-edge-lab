#!/usr/bin/env bash

# Dipende da _tesi_is_ipv4, http_flow e dalle variabili di contesto definite
# caricando prima scripts/cni/common/lab-env.sh.

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

run_dual_view_capture() {
  if [[ "$#" -lt 12 ]]; then
    printf 'Uso: run_dual_view_capture ETICHETTA CAPTURE_LOG HTTP_LOG POD_SRC POD_DST POD_IP_SRC POD_IP_DST UNDERLAY_SRC UNDERLAY_DST PORTA_UDP -- COMANDO_TCPDUMP...\n' >&2
    return 2
  fi

  local capture_label="$1"
  local capture_file="$2"
  local http_file="$3"
  local http_source_pod="$4"
  local http_destination_pod="$5"
  local pod_source="$6"
  local pod_destination="$7"
  local underlay_source="$8"
  local underlay_destination="$9"
  local udp_port="${10}"
  shift 10

  if [[ "$1" != -- || "$#" -lt 2 ]]; then
    printf 'ERROR: separatore -- o comando tcpdump mancante.\n' >&2
    return 2
  fi
  shift

  (
    sleep 2
    http_flow "$http_source_pod" "$http_destination_pod"
  ) >"$http_file" 2>&1 &
  export HTTP_JOB=$!

  if "$@" >"$capture_file" 2>&1; then
    export CAPTURE_RC=0
  else
    export CAPTURE_RC=$?
  fi
  printf 'capture_exit=%s\n' "$CAPTURE_RC"

  if wait "$HTTP_JOB"; then
    export HTTP_RC=0
  else
    export HTTP_RC=$?
  fi
  printf 'http_exit=%s\n' "$HTTP_RC"

  export CAPTURE_FAILED=0
  case "$CAPTURE_RC" in
    0|124|143) ;;
    *)
      printf 'FAIL: terminazione inattesa della cattura\n' >&2
      CAPTURE_FAILED=1
      ;;
  esac
  if [[ "$HTTP_RC" -ne 0 ]]; then
    printf 'FAIL: richiesta HTTP della cattura fallita\n' >&2
    CAPTURE_FAILED=1
  fi
  if ! verify_no_tcpdump_processes; then
    CAPTURE_FAILED=1
  fi
  if ! verify_dual_view_capture \
      "$capture_file" "$pod_source" "$pod_destination" \
      "$underlay_source" "$underlay_destination" "$udp_port"; then
    CAPTURE_FAILED=1
  fi

  if [[ "$CAPTURE_FAILED" -ne 0 ]]; then
    printf 'STOP: cattura %s non valida; nessuna analisi successiva eseguita.\n' \
      "$capture_label" >&2
    return 1
  fi
}
