#!/usr/bin/env bash

# Helper specifici per l'attribuzione Service E20/Cilium. Caricare prima
# scripts/cni/common/lab-env.sh e scripts/cni/common/service.sh.

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

wait_for_cilium_service_hubble() {
  if [[ "$#" -ne 4 ]]
  then
    printf 'Uso: wait_for_cilium_service_hubble SINCE UNTIL CORRELAZIONE OUTPUT.\n' >&2
    return 2
  fi
  local SINCE="$1"
  local UNTIL="$2"
  local CORRELATION_FILE="$3"
  local HUBBLE_FINAL="$4"
  local HUBBLE_TEMP
  local VERIFY_RC
  local DEADLINE=$((SECONDS + CILIUM_SERVICE_HUBBLE_TIMEOUT))

  if ! HUBBLE_TEMP="$(mktemp "$SERVICE_DIR/.hubble-service.XXXXXX")"
  then
    printf 'ERROR: creazione file Hubble Service temporaneo fallita.\n' >&2
    return 2
  fi
  while true
  do
    if ! kubectl --context "$TESI_CONTEXT" exec -n kube-system \
        "$CILIUM_AGENT0" -- hubble observe \
        --server unix:///var/run/cilium/hubble.sock \
        --since "$SINCE" --until "$UNTIL" \
        --from-pod net-lab/client --port 8080 -o jsonpb \
        >"$HUBBLE_TEMP"
    then
      printf 'ERROR: observer Hubble Service fallito.\n' >&2
      rm -f -- "$HUBBLE_TEMP"
      return 2
    fi
    if verify_cilium_service_hubble \
        "$HUBBLE_TEMP" "$CORRELATION_FILE" "$SINCE" "$UNTIL" \
        "$CLIENT_IP" 8080
    then
      if ! mv -f -- "$HUBBLE_TEMP" "$HUBBLE_FINAL"
      then
        printf 'ERROR: promozione output Hubble Service fallita.\n' >&2
        rm -f -- "$HUBBLE_TEMP"
        return 2
      fi
      return 0
    else
      VERIFY_RC=$?
    fi
    if [[ "$VERIFY_RC" -eq 2 ]]
    then
      rm -f -- "$HUBBLE_TEMP"
      return 2
    fi
    if [[ "$SECONDS" -ge "$DEADLINE" ]]
    then
      printf 'FAIL: Hubble non ha esposto tutti i flussi Service controllati entro %ss.\n' \
        "$CILIUM_SERVICE_HUBBLE_TIMEOUT" >&2
      rm -f -- "$HUBBLE_TEMP"
      return 1
    fi
    sleep 0.5
  done
}

run_e20_service_attribution() {
  local START_UTC
  local END_UTC
  local required_file
  local VERIFY_RC

  verify_service_backends || return 1

  capture_service_iptables_snapshot "$CILIUM_NODE" \
    "$SERVICE_DIR/kube-proxy-before-full.log" \
    "$SERVICE_DIR/kube-proxy-before.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --frontends \
    >"$SERVICE_DIR/lb-frontends-before.log" || {
      printf 'ERROR: observer frontend LB Cilium fallito.\n' >&2
      return 2
    }
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --backends \
    >"$SERVICE_DIR/lb-backends-before.log" || {
      printf 'ERROR: observer backend LB Cilium fallito.\n' >&2
      return 2
    }
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf lb list --revnat \
    >"$SERVICE_DIR/lb-revnat-before.log" || {
      printf 'ERROR: observer RevNAT Cilium fallito.\n' >&2
      return 2
    }
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf ct list global \
    >"$SERVICE_DIR/ct-before.log" || {
      printf 'ERROR: observer Cilium CT iniziale fallito.\n' >&2
      return 2
    }

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

  START_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" || return 1
  if ! service_http_flows 6 >"$SERVICE_DIR/http-flows.log"
  then
    printf 'ERROR: almeno un flusso Service E20 è fallito; snapshot successivi non acquisiti.\n' >&2
    return 1
  fi
  END_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" || return 1

  capture_service_iptables_snapshot "$CILIUM_NODE" \
    "$SERVICE_DIR/kube-proxy-after-full.log" \
    "$SERVICE_DIR/kube-proxy-after.log" || return 1
  kubectl --context "$TESI_CONTEXT" exec -n kube-system \
    "$CILIUM_AGENT0" -- cilium-dbg bpf ct list global \
    >"$SERVICE_DIR/ct-after.log" || {
      printf 'ERROR: observer Cilium CT successivo fallito.\n' >&2
      return 2
    }

  for required_file in \
    "$SERVICE_DIR/http-flows.log" \
    "$SERVICE_DIR/ct-after.log"
  do
    if [[ ! -s "$required_file" ]]
    then
      printf 'ERROR: output Service E20 richiesto vuoto: %s\n' \
        "$required_file" >&2
      return 1
    fi
  done

  if verify_cilium_service_ct_lb \
      "$SERVICE_IP" 8080 "$CLIENT_IP" "$SERVER_A_IP" "$SERVER_B_IP" \
      "$SERVICE_DIR/http-flows.log" \
      "$SERVICE_DIR/ct-before.log" "$SERVICE_DIR/ct-after.log" \
      "$SERVICE_DIR/lb-frontends-before.log" \
      "$SERVICE_DIR/lb-backends-before.log" \
      "$SERVICE_DIR/lb-revnat-before.log" \
      "$SERVICE_DIR/ct-service-correlation.log"
  then
    :
  else
    VERIFY_RC=$?
    return "$VERIFY_RC"
  fi
  if verify_kube_proxy_service_invariance \
      "$SERVICE_IP" 8080 "$SERVER_A_IP" "$SERVER_B_IP" \
      "$SERVICE_DIR/kube-proxy-before.log" \
      "$SERVICE_DIR/kube-proxy-after.log"
  then
    :
  else
    VERIFY_RC=$?
    return "$VERIFY_RC"
  fi
  if wait_for_cilium_service_hubble \
      "$START_UTC" "$END_UTC" \
      "$SERVICE_DIR/ct-service-correlation.log" \
      "$SERVICE_DIR/hubble-service.json"
  then
    :
  else
    VERIFY_RC=$?
    return "$VERIFY_RC"
  fi

  cat "$SERVICE_DIR/http-flows.log" || return 1
  cat "$SERVICE_DIR/ct-service-correlation.log" || return 1
  show_informative_diff "$SERVICE_DIR/kube-proxy-before.log" \
    "$SERVICE_DIR/kube-proxy-after.log" || return 1
  show_informative_diff "$SERVICE_DIR/ct-before.log" \
    "$SERVICE_DIR/ct-after.log" || return 1
  printf 'PASS: per i flussi ClusterIP controllati, CT/mappe/Hubble attribuiscono il percorso a Cilium e i contatori kube-proxy pertinenti restano invariati.\n'
}
