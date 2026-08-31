#!/usr/bin/env bash

# Helper per revision, convergenza endpoint e orchestrazione NetworkPolicy
# E20/Cilium. Caricare prima lab-env.sh, common/service.sh e
# scripts/cni/cilium/policy-observers.sh.

_read_cilium_agent_revision() {
  if [[ "$#" -ne 1 ]]
  then
    printf 'Uso: _read_cilium_agent_revision AGENT\n' >&2
    return 2
  fi
  local AGENT="$1"

  if ! CILIUM_CURRENT_REVISION="$(kubectl --context "$TESI_CONTEXT" \
      exec -n kube-system "$AGENT" -- cilium-dbg policy get \
      -o jsonpath='{.revision}')"
  then
    printf 'ERROR: lettura della policy revision fallita sull agent %s.\n' \
      "$AGENT" >&2
    return 1
  fi
  if [[ ! "$CILIUM_CURRENT_REVISION" =~ ^[0-9]+$ ]]
  then
    printf 'ERROR: policy revision non valida sull agent %s: %q.\n' \
      "$AGENT" "$CILIUM_CURRENT_REVISION" >&2
    return 1
  fi
}

_read_cilium_agent_policy() {
  if [[ "$#" -ne 1 ]]
  then
    printf 'Uso: _read_cilium_agent_policy AGENT\n' >&2
    return 2
  fi
  local AGENT="$1"

  if ! CILIUM_CURRENT_POLICY="$(kubectl --context "$TESI_CONTEXT" \
      exec -n kube-system "$AGENT" -- cilium-dbg policy get \
      -o jsonpath='{.policy}')"
  then
    printf 'ERROR: lettura delle policy importate fallita sull agent %s.\n' \
      "$AGENT" >&2
    return 1
  fi
}

_cilium_policy_state_matches() {
  if [[ "$#" -ne 2 ]]
  then
    printf 'Uso: _cilium_policy_state_matches STATO DOCUMENTO\n' >&2
    return 2
  fi
  local EXPECTED_STATE="$1"
  local POLICY_DOCUMENT="$2"
  local NORMALIZED
  local DENY_LABEL='"key":"io.cilium.k8s.policy.name","value":"default-deny-ingress"'
  local ALLOW_LABEL='"key":"io.cilium.k8s.policy.name","value":"allow-client-to-http-servers"'
  local HAS_DENY=0
  local HAS_ALLOW=0

  if ! NORMALIZED="$(awk '
    { text = text $0 }
    END {
      gsub(/[[:space:]]/, "", text)
      if (text !~ /^\[.*\]$/) exit 2
      print text
    }
  ' <<<"$POLICY_DOCUMENT")"
  then
    printf 'ERROR: documento policy Cilium malformato.\n' >&2
    return 2
  fi
  [[ "$NORMALIZED" == *"$DENY_LABEL"* ]] && HAS_DENY=1
  [[ "$NORMALIZED" == *"$ALLOW_LABEL"* ]] && HAS_ALLOW=1

  case "$EXPECTED_STATE" in
    default-deny)
      [[ "$HAS_DENY" -eq 1 && "$HAS_ALLOW" -eq 0 ]]
      ;;
    selective-allow)
      [[ "$HAS_DENY" -eq 1 && "$HAS_ALLOW" -eq 1 ]]
      ;;
    restored)
      [[ "$HAS_DENY" -eq 0 && "$HAS_ALLOW" -eq 0 ]]
      ;;
    *)
      printf 'ERROR: stato policy Cilium non riconosciuto: %s.\n' \
        "$EXPECTED_STATE" >&2
      return 2
      ;;
  esac
}

snapshot_cilium_policy_revisions() {
  local POD_OUTPUT
  local POD
  local NODE
  local EXTRA
  local AGENT_OUTPUT
  local AGENT
  local REVISION
  local -a NODE_ORDER=()
  local -A EXPECTED_PODS=(
    [client]=1
    [server-a]=1
    [server-b]=1
  )
  local -A SEEN_PODS=()
  local -A PODS_BY_NODE=()

  if ! POD_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get pods \
      -n net-lab client server-a server-b \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}')"
  then
    printf 'ERROR: inventario Pod/nodo E20 fallito.\n' >&2
    return 1
  fi

  while IFS=$'\t' read -r POD NODE EXTRA
  do
    if [[ -n "$EXTRA" || -z "${EXPECTED_PODS[$POD]:-}" || \
          -n "${SEEN_PODS[$POD]:-}" || \
          ! "$NODE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
    then
      printf 'ERROR: record Pod/nodo E20 non valido: %q.\n' \
        "$POD_OUTPUT" >&2
      return 1
    fi
    SEEN_PODS["$POD"]=1
    if [[ -z "${PODS_BY_NODE[$NODE]+presente}" ]]
    then
      NODE_ORDER+=("$NODE")
      PODS_BY_NODE["$NODE"]="$POD"
    else
      PODS_BY_NODE["$NODE"]+=" $POD"
    fi
  done <<<"$POD_OUTPUT"

  if [[ "${#SEEN_PODS[@]}" -ne 3 ]]
  then
    printf 'ERROR: attesi client, server-a e server-b nell inventario E20.\n' >&2
    return 1
  fi

  CILIUM_POLICY_NODES=()
  CILIUM_POLICY_AGENTS=()
  CILIUM_POLICY_REVISIONS=()
  CILIUM_POLICY_PODS=()
  for NODE in "${NODE_ORDER[@]}"
  do
    if ! AGENT_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get pods \
        -n kube-system -l k8s-app=cilium \
        --field-selector "spec.nodeName=$NODE,status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
    then
      printf 'ERROR: ricerca dell agent Cilium sul nodo %s fallita.\n' \
        "$NODE" >&2
      return 1
    fi
    if [[ ! "$AGENT_OUTPUT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
    then
      printf 'ERROR: atteso un solo agent Cilium Running sul nodo %s: %q.\n' \
        "$NODE" "$AGENT_OUTPUT" >&2
      return 1
    fi
    AGENT="$AGENT_OUTPUT"
    _read_cilium_agent_revision "$AGENT" || return 1
    REVISION="$CILIUM_CURRENT_REVISION"
    CILIUM_POLICY_NODES+=("$NODE")
    CILIUM_POLICY_AGENTS+=("$AGENT")
    CILIUM_POLICY_REVISIONS+=("$REVISION")
    CILIUM_POLICY_PODS+=("${PODS_BY_NODE[$NODE]}")
    printf 'policy_snapshot node=%s agent=%s revision=%s pods=%s\n' \
      "$NODE" "$AGENT" "$REVISION" "${PODS_BY_NODE[$NODE]}"
  done
}

_cilium_workload_endpoints_ready() {
  if [[ "$#" -ne 3 ]]
  then
    printf 'Uso: _cilium_workload_endpoints_ready AGENT PODS REVISION\n' >&2
    return 2
  fi
  local AGENT="$1"
  local PODS="$2"
  local REQUIRED_REVISION="$3"
  local ENDPOINT_OUTPUT
  local POD_REF
  local STATE
  local SPEC_REVISION
  local REALIZED_REVISION
  local EXTRA
  local POD
  local -A EXPECTED=()
  local -A SEEN=()

  for POD in $PODS
  do
    EXPECTED["net-lab/$POD"]=1
  done
  if ! ENDPOINT_OUTPUT="$(kubectl --context "$TESI_CONTEXT" exec \
      -n kube-system "$AGENT" -- cilium-dbg endpoint list \
      -o jsonpath='{range [*]}{@.status.external-identifiers.pod-name}{"|"}{@.status.state}{"|"}{@.status.policy.spec.policy-revision}{"|"}{@.status.policy.realized.policy-revision}{"\n"}{end}')"
  then
    printf 'ERROR: lettura endpoint Cilium fallita sull agent %s.\n' \
      "$AGENT" >&2
    return 2
  fi

  while IFS='|' read -r POD_REF STATE SPEC_REVISION REALIZED_REVISION EXTRA
  do
    [[ -n "${EXPECTED[$POD_REF]:-}" ]] || continue
    if [[ -n "$EXTRA" || -n "${SEEN[$POD_REF]:-}" || \
          ! "$SPEC_REVISION" =~ ^[0-9]+$ || \
          ! "$REALIZED_REVISION" =~ ^[0-9]+$ ]]
    then
      printf 'ERROR: record endpoint Cilium non valido per %s: %q.\n' \
        "$POD_REF" "$ENDPOINT_OUTPUT" >&2
      return 2
    fi
    SEEN["$POD_REF"]=1
    if [[ "$STATE" != ready || \
          "$SPEC_REVISION" -lt "$REQUIRED_REVISION" || \
          "$REALIZED_REVISION" -lt "$REQUIRED_REVISION" || \
          "$SPEC_REVISION" -ne "$REALIZED_REVISION" ]]
    then
      return 1
    fi
  done <<<"$ENDPOINT_OUTPUT"

  for POD in $PODS
  do
    [[ -n "${SEEN[net-lab/$POD]:-}" ]] || return 1
  done
}

wait_for_cilium_policy_convergence() {
  if [[ "$#" -ne 1 ]]
  then
    printf 'Uso: wait_for_cilium_policy_convergence default-deny|selective-allow|restored\n' >&2
    return 2
  fi
  local EXPECTED_STATE="$1"
  local DEADLINE=$((SECONDS + CILIUM_POLICY_TIMEOUT))
  local INDEX
  local AGENT
  local NODE
  local PODS
  local BEFORE_REVISION
  local FIRST_REVISION
  local AFTER_REVISION
  local TARGET_REVISION
  local REMAINING
  local MATCH_RC
  local ENDPOINT_RC
  local PENDING_REASON

  case "$EXPECTED_STATE" in
    default-deny|selective-allow|restored) ;;
    *)
      printf 'ERROR: stato policy Cilium non riconosciuto: %s.\n' \
        "$EXPECTED_STATE" >&2
      return 2
      ;;
  esac
  if [[ "${#CILIUM_POLICY_AGENTS[@]}" -eq 0 || \
        "${#CILIUM_POLICY_AGENTS[@]}" -ne "${#CILIUM_POLICY_REVISIONS[@]}" || \
        "${#CILIUM_POLICY_AGENTS[@]}" -ne "${#CILIUM_POLICY_PODS[@]}" ]]
  then
    printf 'ERROR: snapshot delle policy revision Cilium assente o incoerente.\n' >&2
    return 1
  fi

  for INDEX in "${!CILIUM_POLICY_AGENTS[@]}"
  do
    AGENT="${CILIUM_POLICY_AGENTS[$INDEX]}"
    NODE="${CILIUM_POLICY_NODES[$INDEX]}"
    PODS="${CILIUM_POLICY_PODS[$INDEX]}"
    BEFORE_REVISION="${CILIUM_POLICY_REVISIONS[$INDEX]}"
    PENDING_REASON='revisione non ancora avanzata'

    while true
    do
      _read_cilium_agent_revision "$AGENT" || return 1
      FIRST_REVISION="$CILIUM_CURRENT_REVISION"
      if [[ "$FIRST_REVISION" -gt "$BEFORE_REVISION" ]]
      then
        _read_cilium_agent_policy "$AGENT" || return 1
        _read_cilium_agent_revision "$AGENT" || return 1
        AFTER_REVISION="$CILIUM_CURRENT_REVISION"
        if [[ "$FIRST_REVISION" -ne "$AFTER_REVISION" ]]
        then
          PENDING_REASON='revisione cambiata durante la lettura'
        elif _cilium_policy_state_matches \
            "$EXPECTED_STATE" "$CILIUM_CURRENT_POLICY"
        then
          TARGET_REVISION="$AFTER_REVISION"
          break
        else
          MATCH_RC=$?
          if [[ "$MATCH_RC" -eq 2 ]]
          then
            return 1
          fi
          PENDING_REASON='stato semantico della policy non ancora convergente'
        fi
      fi

      if [[ "$SECONDS" -ge "$DEADLINE" ]]
      then
        printf 'ERROR: timeout policy Cilium su %s/%s: %s.\n' \
          "$NODE" "$AGENT" "$PENDING_REASON" >&2
        return 1
      fi
      sleep 1
    done

    REMAINING=$((DEADLINE - SECONDS))
    if [[ "$REMAINING" -le 0 ]]
    then
      printf 'ERROR: timeout policy Cilium prima del policy wait su %s.\n' \
        "$AGENT" >&2
      return 1
    fi
    if ! kubectl --context "$TESI_CONTEXT" exec -n kube-system \
        "$AGENT" -- cilium-dbg policy wait "$TARGET_REVISION" \
        --max-wait-time "$REMAINING" --fail-wait-time "$REMAINING" \
        --sleep-time 1
    then
      printf 'ERROR: policy wait revision %s fallito sull agent %s.\n' \
        "$TARGET_REVISION" "$AGENT" >&2
      return 1
    fi

    while true
    do
      if _cilium_workload_endpoints_ready \
          "$AGENT" "$PODS" "$TARGET_REVISION"
      then
        break
      else
        ENDPOINT_RC=$?
      fi
      if [[ "$ENDPOINT_RC" -eq 2 ]]
      then
        return 1
      fi
      if [[ "$SECONDS" -ge "$DEADLINE" ]]
      then
        printf 'ERROR: endpoint workload non convergenti su %s/%s.\n' \
          "$NODE" "$AGENT" >&2
        return 1
      fi
      sleep 1
    done
    printf 'PASS: policy %s convergente su %s, revision %s > %s.\n' \
      "$EXPECTED_STATE" "$AGENT" "$TARGET_REVISION" "$BEFORE_REVISION"
  done
}

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
  local HUBBLE_FILE="$POLICY_DIR/${POLICY_STATE}-hubble.json"
  local REQUIRED_FILE
  POLICY_SINCE="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" || return 1
  run_policy_matrix "$POLICY_EXPECTATION" || return 1
  POLICY_UNTIL="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" || return 1
  wait_for_cilium_hubble_policy_capture \
    "$POLICY_STATE" "$POLICY_SINCE" "$POLICY_UNTIL" "$HUBBLE_FILE" || \
    return 1

  kubectl --context "$TESI_CONTEXT" get networkpolicy -n net-lab -o yaml \
    >"$POLICY_DIR/${POLICY_STATE}-networkpolicy.yaml" || return 1
  kubectl --context "$TESI_CONTEXT" get ciliumendpoint \
    -n net-lab client server-a server-b -o yaml \
    >"$POLICY_DIR/${POLICY_STATE}-endpoints.yaml" || return 1
  capture_cilium_bpf_policy_maps "$POLICY_STATE" || return 1

  for REQUIRED_FILE in \
    "$POLICY_DIR/${POLICY_STATE}-networkpolicy.yaml" \
    "$POLICY_DIR/${POLICY_STATE}-endpoints.yaml" \
    "$POLICY_DIR/${POLICY_STATE}-bpf-policy.log" \
    "$HUBBLE_FILE"
  do
    if [[ ! -s "$REQUIRED_FILE" ]]
    then
      printf 'ERROR: output policy E20 richiesto vuoto: %s\n' \
        "$REQUIRED_FILE" >&2
      return 1
    fi
  done
}
