#!/usr/bin/env bash

# Dipende da _tesi_require_context, _tesi_is_ipv4, _tesi_wget_probe e dalle
# variabili di contesto definite caricando prima scripts/cni/common/lab-env.sh.

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
