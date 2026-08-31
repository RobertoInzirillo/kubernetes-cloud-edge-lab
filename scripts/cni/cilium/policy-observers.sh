#!/usr/bin/env bash

# Observer Hubble e mappe BPF policy multi-agent per E20/Cilium.
# Caricare prima scripts/cni/common/lab-env.sh.

_verify_cilium_hubble_policy_capture() {
  if [[ "$#" -ne 4 ]]
  then
    printf 'Uso: _verify_cilium_hubble_policy_capture FILE STATO SINCE UNTIL\n' >&2
    return 2
  fi
  local HUBBLE_FILE="$1"
  local POLICY_STATE="$2"
  local POLICY_SINCE="$3"
  local POLICY_UNTIL="$4"
  local VERIFY_RC

  awk -v state="$POLICY_STATE" \
      -v since="$POLICY_SINCE" -v until="$POLICY_UNTIL" '
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
    BEGIN {
      if (!valid_timestamp(since) || !valid_timestamp(until) || since > until) {
        parser_error = 1
        exit
      }
    }
    {
      sub(/\r$/, "")
      if ($0 == "") next
      records++
      if (!valid_json_record($0)) {
        parser_error = 1
        exit
      }
      compact = $0
      gsub(/[[:space:]]/, "", compact)
      if (index(compact, "\"flow\":{") &&
          index(compact, "\"namespace\":\"net-lab\"") &&
          index(compact, "\"TCP\":{") &&
          index(compact, "\"destination_port\":8080")) {
        marker = "\"time\":\""
        start = index(compact, marker)
        if (!start) {
          parser_error = 1
          exit
        }
        timestamp = substr(compact, start + length(marker))
        finish = index(timestamp, "\"")
        if (!finish) {
          parser_error = 1
          exit
        }
        timestamp = substr(timestamp, 1, finish - 1)
        if (!valid_timestamp(timestamp)) {
          parser_error = 1
          exit
        }
        if (timestamp >= since && timestamp <= until) {
          relevant++
          if (index(compact, "\"verdict\":\"FORWARDED\"")) forwarded++
          if (index(compact, "\"verdict\":\"DROPPED\"") &&
              index(compact, "\"drop_reason_desc\":\"POLICY_DENIED\""))
            policy_denied++
        }
      }
    }
    END {
      if (parser_error) exit 2
      if (records == 0 || relevant == 0) exit 1
      if (state == "baseline" || state == "restored")
        exit !(forwarded > 0)
      if (state == "default-deny")
        exit !(policy_denied > 0)
      if (state == "selective-allow")
        exit !(forwarded > 0 && policy_denied > 0)
      exit 2
    }
  ' "$HUBBLE_FILE"
  VERIFY_RC=$?
  case "$VERIFY_RC" in
    0|1) return "$VERIFY_RC" ;;
    *)
      printf 'ERROR: output Hubble JSONPB malformato per lo stato %s.\n' \
        "$POLICY_STATE" >&2
      return 2
      ;;
  esac
}

_remove_cilium_hubble_temp_files() {
  local TEMP_FILE

  for TEMP_FILE in "$@"
  do
    if [[ -z "$TEMP_FILE" || "$TEMP_FILE" != "$POLICY_DIR"/.* ]]
    then
      printf 'ERROR: percorso temporaneo Hubble non valido: %q.\n' \
        "$TEMP_FILE" >&2
      return 1
    fi
    rm -f -- "$TEMP_FILE" || return 1
  done
}

wait_for_cilium_hubble_policy_capture() {
  if [[ "$#" -ne 4 ]]
  then
    printf 'Uso: wait_for_cilium_hubble_policy_capture STATO SINCE UNTIL FILE\n' >&2
    return 2
  fi
  local POLICY_STATE="$1"
  local POLICY_SINCE="$2"
  local POLICY_UNTIL="$3"
  local HUBBLE_FINAL="$4"
  local HUBBLE_AGGREGATE
  local HUBBLE_AGENT_FILE
  local AGENT
  local INDEX
  local -a HUBBLE_AGENT_FILES=()
  local DEADLINE=$((SECONDS + CILIUM_HUBBLE_TIMEOUT))
  local VERIFY_RC

  case "$POLICY_STATE" in
    baseline|default-deny|selective-allow|restored) ;;
    *)
      printf 'ERROR: stato Hubble E20 non riconosciuto: %s.\n' \
        "$POLICY_STATE" >&2
      return 2
      ;;
  esac
  if [[ "${#CILIUM_POLICY_AGENTS[@]}" -eq 0 ]]
  then
    printf 'ERROR: nessun agent Cilium associato ai workload E20.\n' >&2
    return 1
  fi
  if ! HUBBLE_AGGREGATE="$(mktemp \
      "$POLICY_DIR/.${POLICY_STATE}-hubble-aggregate.XXXXXX")"
  then
    printf 'ERROR: creazione aggregato Hubble temporaneo fallita.\n' >&2
    return 1
  fi
  for INDEX in "${!CILIUM_POLICY_AGENTS[@]}"
  do
    AGENT="${CILIUM_POLICY_AGENTS[$INDEX]}"
    if [[ ! "$AGENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
    then
      printf 'ERROR: nome agent Cilium non valido: %q.\n' "$AGENT" >&2
      _remove_cilium_hubble_temp_files \
        "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
      return 1
    fi
    if ! HUBBLE_AGENT_FILE="$(mktemp \
        "$POLICY_DIR/.${POLICY_STATE}-hubble-agent-${INDEX}.XXXXXX")"
    then
      printf 'ERROR: creazione del file Hubble per-agent fallita.\n' >&2
      _remove_cilium_hubble_temp_files \
        "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
      return 1
    fi
    HUBBLE_AGENT_FILES+=("$HUBBLE_AGENT_FILE")
  done

  while true
  do
    if ! : >"$HUBBLE_AGGREGATE"
    then
      printf 'ERROR: inizializzazione aggregato Hubble fallita.\n' >&2
      _remove_cilium_hubble_temp_files \
        "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
      return 1
    fi
    for INDEX in "${!CILIUM_POLICY_AGENTS[@]}"
    do
      AGENT="${CILIUM_POLICY_AGENTS[$INDEX]}"
      HUBBLE_AGENT_FILE="${HUBBLE_AGENT_FILES[$INDEX]}"
      printf 'INFO: query Hubble locale stato=%s agent=%s.\n' \
        "$POLICY_STATE" "$AGENT" >&2
      if ! kubectl --context "$TESI_CONTEXT" exec -n kube-system \
          "$AGENT" -- hubble observe \
          --server unix:///var/run/cilium/hubble.sock \
          --since "$POLICY_SINCE" --until "$POLICY_UNTIL" \
          --namespace net-lab --port 8080 -o jsonpb \
          >"$HUBBLE_AGENT_FILE"
      then
        printf 'ERROR: query Hubble fallita per agent %s nello stato %s.\n' \
          "$AGENT" "$POLICY_STATE" >&2
        _remove_cilium_hubble_temp_files \
          "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
        return 1
      fi
      if ! cat -- "$HUBBLE_AGENT_FILE" >>"$HUBBLE_AGGREGATE"
      then
        printf 'ERROR: aggregazione Hubble fallita per agent %s.\n' \
          "$AGENT" >&2
        _remove_cilium_hubble_temp_files \
          "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
        return 1
      fi
    done

    if _verify_cilium_hubble_policy_capture \
        "$HUBBLE_AGGREGATE" "$POLICY_STATE" \
        "$POLICY_SINCE" "$POLICY_UNTIL"
    then
      if ! mv -f -- "$HUBBLE_AGGREGATE" "$HUBBLE_FINAL"
      then
        printf 'ERROR: promozione atomica dell output Hubble fallita.\n' >&2
        _remove_cilium_hubble_temp_files \
          "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
        return 1
      fi
      if ! _remove_cilium_hubble_temp_files "${HUBBLE_AGENT_FILES[@]}"
      then
        printf 'ERROR: pulizia dei file Hubble per-agent fallita.\n' >&2
        return 1
      fi
      printf 'PASS: evidence Hubble %s aggregata da %s agent nella finestra %s / %s.\n' \
        "$POLICY_STATE" "${#CILIUM_POLICY_AGENTS[@]}" \
        "$POLICY_SINCE" "$POLICY_UNTIL"
      return 0
    else
      VERIFY_RC=$?
    fi
    if [[ "$VERIFY_RC" -eq 2 ]]
    then
      _remove_cilium_hubble_temp_files \
        "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
      return 1
    fi
    if [[ "$SECONDS" -ge "$DEADLINE" ]]
    then
      printf 'ERROR: timeout evidence Hubble incompleta per lo stato %s.\n' \
        "$POLICY_STATE" >&2
      _remove_cilium_hubble_temp_files \
        "$HUBBLE_AGGREGATE" "${HUBBLE_AGENT_FILES[@]}" || true
      return 1
    fi
    sleep 0.5
  done
}

capture_cilium_bpf_policy_maps() {
  if [[ "$#" -ne 1 ]]
  then
    printf 'Uso: capture_cilium_bpf_policy_maps STATO\n' >&2
    return 2
  fi
  local POLICY_STATE="$1"
  local AGGREGATE_FINAL="$POLICY_DIR/${POLICY_STATE}-bpf-policy.log"
  local AGGREGATE_TEMP
  local AGENT
  local AGENT_FINAL
  local AGENT_COUNT=0
  local -A SEEN_AGENTS=()

  case "$POLICY_STATE" in
    baseline|default-deny|selective-allow|restored) ;;
    *)
      printf 'ERROR: stato BPF policy E20 non riconosciuto: %s.\n' \
        "$POLICY_STATE" >&2
      return 2
      ;;
  esac
  if [[ "${#CILIUM_POLICY_AGENTS[@]}" -eq 0 ]]
  then
    printf 'ERROR: nessun agent Cilium per la raccolta BPF policy.\n' >&2
    return 1
  fi
  if ! AGGREGATE_TEMP="$(mktemp \
      "$POLICY_DIR/.${POLICY_STATE}-bpf-policy-aggregate.XXXXXX")"
  then
    printf 'ERROR: creazione aggregato BPF policy fallita.\n' >&2
    return 1
  fi

  for AGENT in "${CILIUM_POLICY_AGENTS[@]}"
  do
    if [[ ! "$AGENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
    then
      printf 'ERROR: nome agent Cilium non valido: %q.\n' "$AGENT" >&2
      rm -f -- "$AGGREGATE_TEMP"
      return 1
    fi
    if [[ -n "${SEEN_AGENTS[$AGENT]:-}" ]]
    then
      printf 'INFO: agent Cilium duplicato ignorato nella raccolta BPF: %s.\n' \
        "$AGENT" >&2
      continue
    fi
    SEEN_AGENTS["$AGENT"]=1
    AGENT_FINAL="$POLICY_DIR/${POLICY_STATE}-bpf-policy-${AGENT}.log"

    if ! kubectl --context "$TESI_CONTEXT" exec -n kube-system \
        "$AGENT" -- cilium-dbg bpf policy get --all >"$AGENT_FINAL"
    then
      printf 'ERROR: raccolta BPF policy fallita sull agent %s.\n' \
        "$AGENT" >&2
      rm -f -- "$AGENT_FINAL" "$AGGREGATE_TEMP"
      return 1
    fi
    if [[ ! -s "$AGENT_FINAL" ]]
    then
      printf 'ERROR: output BPF policy vuoto sull agent %s.\n' \
        "$AGENT" >&2
      rm -f -- "$AGENT_FINAL" "$AGGREGATE_TEMP"
      return 1
    fi
    if ! printf '===== agent=%s raw-file=%s =====\n' \
        "$AGENT" "${AGENT_FINAL##*/}" >>"$AGGREGATE_TEMP" || \
       ! cat -- "$AGENT_FINAL" >>"$AGGREGATE_TEMP" || \
       ! printf '\n' >>"$AGGREGATE_TEMP"
    then
      printf 'ERROR: aggregazione BPF policy fallita per %s.\n' \
        "$AGENT" >&2
      rm -f -- "$AGGREGATE_TEMP"
      return 1
    fi
    AGENT_COUNT=$((AGENT_COUNT + 1))
  done
  if ! mv -f -- "$AGGREGATE_TEMP" "$AGGREGATE_FINAL"
  then
    printf 'ERROR: promozione aggregato BPF policy fallita.\n' >&2
    rm -f -- "$AGGREGATE_TEMP"
    return 1
  fi
  printf 'PASS: BPF policy %s acquisita da %s agent distinti.\n' \
    "$POLICY_STATE" "$AGENT_COUNT"
}
