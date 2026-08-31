#!/usr/bin/env bash

# Helper NetworkPolicy specifici di E02/K3s. Caricare prima
# scripts/cni/common/lab-env.sh.

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

wait_for_k3s_policy_convergence() {
  if [[ "$#" -ne 1 ]]; then
    printf 'Uso: wait_for_k3s_policy_convergence default-deny|selective-allow|restored\n' >&2
    return 2
  fi
  if ! _tesi_require_context; then
    return 2
  fi

  local dataplane='k3s'
  local expected_state="$1"
  local deadline=$((SECONDS + 90))
  local pod_inventory
  local pod
  local node
  local pod_ip
  local extra
  local iptables_output
  local line
  local default_chain
  local default_link
  local allow_chain
  local allow_link
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
      workload_policy_link=0
      while IFS= read -r line; do
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
      done <<< "$iptables_output"

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
