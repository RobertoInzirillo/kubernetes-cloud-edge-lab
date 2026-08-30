#!/usr/bin/env bash

# Orchestrazione specifica dell'attribuzione Service E10. Caricare prima
# scripts/cni/common/lab-env.sh e scripts/cni/common/service.sh.

run_e10_service_attribution() {
  local GREP_RC
  local VERIFY_RC

  verify_service_backends || return 1

  if ! docker logs "$CALICO_AGENT0" \
      >"$SERVICE_DIR/kube-proxy-full.log" 2>&1
  then
    printf 'ERROR: acquisizione log kube-proxy fallita.\n' >&2
    return 1
  fi
  if grep -E 'kube-proxy|Using iptables Proxier' \
      "$SERVICE_DIR/kube-proxy-full.log" \
      >"$SERVICE_DIR/kube-proxy.log"
  then
    :
  else
    GREP_RC=$?
    if [[ "$GREP_RC" -gt 1 ]]
    then
      printf 'ERROR: filtro log kube-proxy fallito (grep rc=%s).\n' \
        "$GREP_RC" >&2
      return 1
    fi
    printf 'INFO: nessuna riga kube-proxy trovata nel log; il file non viene usato come gate.\n'
  fi

  capture_service_iptables_snapshot "$CALICO_AGENT0" \
    "$SERVICE_DIR/iptables-before-full.log" \
    "$SERVICE_DIR/iptables-before.log" || return 1

  if ! service_http_flows 6 >"$SERVICE_DIR/http-flows.log"
  then
    printf 'ERROR: almeno un flusso Service E10 è fallito; snapshot successivo non acquisito.\n' >&2
    return 1
  fi

  capture_service_iptables_snapshot "$CALICO_AGENT0" \
    "$SERVICE_DIR/iptables-after-full.log" \
    "$SERVICE_DIR/iptables-after.log" || return 1

  cat "$SERVICE_DIR/http-flows.log" || return 1
  if verify_kube_proxy_service_attribution \
      "$SERVICE_IP" 8080 "$SERVER_A_IP" "$SERVER_B_IP" \
      "$SERVICE_DIR/http-flows.log" \
      "$SERVICE_DIR/iptables-before.log" \
      "$SERVICE_DIR/iptables-after.log"
  then
    :
  else
    VERIFY_RC=$?
    return "$VERIFY_RC"
  fi
  show_informative_diff "$SERVICE_DIR/iptables-before.log" \
    "$SERVICE_DIR/iptables-after.log" || return 1
}
