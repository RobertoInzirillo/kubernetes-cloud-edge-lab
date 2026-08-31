#!/usr/bin/env bash

# Helper NetworkPolicy specifici di E10/Calico. Caricare prima
# scripts/cni/common/lab-env.sh.

inspect_calico_policy_plane() {
  local FAILED=0
  local FILTER_RC
  local IPSET_OUTPUT
  local IPTABLES_OUTPUT
  local LOG_OUTPUT
  local POD_OUTPUT
  local POLICY_OUTPUT

  if POLICY_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get \
      networkpolicy -n net-lab -o yaml)"
  then
    printf '%s\n' "$POLICY_OUTPUT"
  else
    printf 'ERROR: acquisizione NetworkPolicy Calico fallita.\n' >&2
    FAILED=1
  fi
  if POD_OUTPUT="$(kubectl --context "$TESI_CONTEXT" get pods \
      -n net-lab -o wide)"
  then
    printf '%s\n' "$POD_OUTPUT"
  else
    printf 'ERROR: acquisizione Pod/IP/nodo per la policy Calico fallita.\n' >&2
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

wait_for_calico_policy_convergence() {
  if [[ "$#" -ne 1 ]]; then
    printf 'Uso: wait_for_calico_policy_convergence default-deny|selective-allow|restored\n' >&2
    return 2
  fi
  if ! _tesi_require_context; then
    return 2
  fi

  local dataplane='calico'
  local expected_state="$1"
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
      done <<< "$iptables_output"

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
