#!/usr/bin/env bash
set -euo pipefail

# Run on the RHDP bastion as lab-user. Does not create or delete a CaaS order.
usage() {
  echo "Usage: $0 auto|status|agent-dns|finish|refresh-dns|access [order-xxxxx]" >&2
  exit 2
}
die() { echo "Error: $*" >&2; exit 1; }
log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

[[ $# -ge 1 && $# -le 2 ]] || usage
action=$1
[[ "$action" == auto || "$action" == status || "$action" == agent-dns || "$action" == finish || "$action" == refresh-dns || "$action" == access ]] || usage
command -v oc >/dev/null
command -v jq >/dev/null
explicit_order=${2:-}
[[ -z "$explicit_order" || "$explicit_order" =~ ^order-[a-z0-9]+$ ]] || die "Unexpected order name: $explicit_order"

resolve_order() {
  if [[ -n "$explicit_order" ]]; then
    order=$explicit_order
    oc -n osac get clusterorder "$order" >/dev/null 2>&1
    return
  fi
  local orders_json
  orders_json=$(oc -n osac get clusterorder -o json 2>/dev/null) || return 1
  mapfile -t orders < <(jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' <<< "$orders_json")
  [[ ${#orders[@]} -gt 0 ]] || return 1
  [[ ${#orders[@]} == 1 ]] || die "Found ${#orders[@]} active orders; pass the order name explicitly."
  order=${orders[0]}
}

if [[ "$action" == auto ]]; then
  until resolve_order; do
    log 'Waiting for the ClusterOrder to appear...'
    sleep 15
  done
else
  resolve_order || die 'No matching active order yet; create the cluster in the UI first.'
fi
[[ "$order" =~ ^order-[a-z0-9]+$ ]] || die "Unexpected order name: $order"

base_domain=$(oc -n osac get cm cluster-fulfillment-ig -o jsonpath='{.data.HOSTED_CLUSTER_BASE_DOMAIN}')
[[ "$base_domain" =~ ^[a-z0-9.-]+$ ]] || die 'Hosted base domain is missing or invalid.'
domain="$order.$base_domain"

refresh_context() {
  local order_json bmi_json bmh_json vip_list
  order_json=$(oc -n osac get clusterorder "$order" -o json 2>/dev/null) || return 1
  order_phase=$(jq -r '.status.phase // "Pending"' <<< "$order_json")
  vip_list=$(oc get svc -A -o json 2>/dev/null | jq -r --arg order "$order" '
    [.items[] | select(.metadata.name == "kube-apiserver") |
     select(.metadata.namespace | startswith("osac-" + $order)) |
     .status.loadBalancer.ingress[0].ip // empty] | unique | .[]') || return 1
  [[ $(wc -l <<< "$vip_list") -le 1 ]] || die "Multiple API VIPs found for $order."
  vip=$vip_list
  bmi_json=$(oc -n osac get bmi -o json 2>/dev/null) || return 1
  mapfile -t bmh_names < <(jq -r --arg order "$order" '
    .items[] | select(.metadata.deletionTimestamp == null) |
    select(.metadata.annotations["osac.openshift.io/owner-reference"] == ("ClusterOrder/" + $order)) |
    .spec.externalHostID // empty | select(startswith("osac/")) | split("/")[1]' <<< "$bmi_json")
  bmh_count=${#bmh_names[@]}
  [[ "$bmh_count" -le 1 ]] || die "This helper expects one worker BMH for $order; found $bmh_count."
  bmh=''
  guest_ip=''
  guest_uuid=''
  node=''
  bmh_state=''
  agent_state=''
  agent_json=''
  if [[ "$bmh_count" == 1 ]]; then
    bmh=${bmh_names[0]}
    [[ "$bmh" =~ ^virtual-bmh-[a-z0-9-]+$ ]] || die "Unexpected BMH name: $bmh"
    bmh_json=$(oc -n osac get bmh "$bmh" -o json 2>/dev/null) || return 1
    bmh_state=$(jq -r '.status.provisioning.state // empty' <<< "$bmh_json")
    guest_ip=$(jq -r '.status.hardware.nics[0].ip // empty' <<< "$bmh_json")
    guest_uuid=$(jq -r '.spec.bmc.address // "" | sub(".*/Systems/"; "")' <<< "$bmh_json")
    if [[ "$guest_uuid" =~ ^[0-9a-f-]{36}$ ]]; then
      agent_json=$(oc -n osac get agent "$guest_uuid" -o json 2>/dev/null || true)
      if [[ -n "$agent_json" ]]; then
        agent_state=$(jq -r '.status.debugInfo.state // empty' <<< "$agent_json")
        # Assisted Installer uses the Agent inventory hostname for the guest Node name;
        # it is not necessarily the BMH NIC MAC (this lab reports console-openshift-console).
        node=$(jq -r '.status.inventory.hostname // empty' <<< "$agent_json")
      fi
    fi
  fi
}
refresh_context || die "Could not read current state for $order."

need_worker() {
  [[ "$bmh_count" == 1 ]] || die "Expected one claimed worker BMH, found $bmh_count."
  [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Worker guest IP is not available yet.'
  [[ "$guest_uuid" =~ ^[0-9a-f-]{36}$ ]] || die 'Worker UUID could not be read from its BMC address.'
  [[ "$node" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Worker node hostname is not available from the Agent inventory.'
}
need_vip() {
  [[ "$vip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'API VIP is not ready yet; wait for osac-create-hosted-cluster.'
}

bmf_dns() {
  local mode=$1 ip=$2
  sudo ssh -o BatchMode=yes root@10.10.10.2 bash -s -- "$mode" "$ip" "$domain" <<'REMOTE'
set -euo pipefail
mode=$1 ip=$2 domain=$3
if [[ $mode == api ]]; then
  xml="<host ip='$ip'><hostname>api.$domain</hostname><hostname>api-int.$domain</hostname></host>"
  lookup="api.$domain"
  names=("api.$domain" "api-int.$domain")
else
  xml="<host ip='$ip'><hostname>console-openshift-console.apps.$domain</hostname><hostname>canary-openshift-ingress-canary.apps.$domain</hostname><hostname>oauth-openshift.apps.$domain</hostname></host>"
  lookup="console-openshift-console.apps.$domain"
  names=("console-openshift-console.apps.$domain" "canary-openshift-ingress-canary.apps.$domain" "oauth-openshift.apps.$domain")
fi
network_xml=$(virsh net-dumpxml default)
old_xml=$(printf '%s' "$network_xml" | python3 -c '
import sys
import xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for host in root.findall("./dns/host"):
    if host.get("ip") == sys.argv[1]:
        print(ET.tostring(host, encoding="unicode"))
        break
' "$ip")
already=true
for name in "${names[@]}"; do
  [[ $old_xml == *"<hostname>$name</hostname>"* ]] || already=false
done
if [[ -z $old_xml ]]; then
  virsh net-update default add dns-host "$xml" --live --config
elif [[ $already == true ]]; then
  echo "libvirt DNS already contains $lookup"
elif ! virsh net-update default modify dns-host "$xml" --live --config; then
  # Older libvirt builds cannot modify dns-host. Restore the old record if add fails.
  virsh net-update default delete dns-host "$old_xml" --live --config
  if ! virsh net-update default add dns-host "$xml" --live --config; then
    virsh net-update default add dns-host "$old_xml" --live --config || true
    exit 1
  fi
fi
for attempt in {1..10}; do
  if dig +short @192.168.122.1 "$lookup" | grep -Fxq "$ip"; then
    echo "libvirt DNS: $lookup -> $ip"
    exit 0
  fi
  sleep 2
done
echo "libvirt DNS did not resolve $lookup to $ip" >&2
exit 1
REMOTE
}

kubeconfig=''
cleanup() {
  [[ -z "$kubeconfig" ]] || rm -f "$kubeconfig"
}
trap cleanup EXIT

guest_ssh() {
  local known_hosts_file ssh_status
  known_hosts_file=$(mktemp)
  # The live Agent OS and installed RHCOS can present different host keys.
  if ssh -i "$HOME/.ssh/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$known_hosts_file" \
    -o 'ProxyCommand=sudo ssh -o BatchMode=yes -W %h:%p root@10.10.10.2' \
    "core@$guest_ip" "$@"; then
    ssh_status=0
  else
    ssh_status=$?
  fi
  rm -f "$known_hosts_file"
  return "$ssh_status"
}

ensure_kubeconfig() {
  local encoded
  if [[ -n "$kubeconfig" && -s "$kubeconfig" ]]; then
    return 0
  fi
  encoded=$(oc -n "osac-$order" get secret "$order-admin-kubeconfig" \
    -o jsonpath='{.data.kubeconfig}' 2>/dev/null) || return 1
  [[ -n "$encoded" ]] || return 1
  [[ -n "$kubeconfig" ]] || kubeconfig=$(mktemp)
  chmod 600 "$kubeconfig"
  if ! printf '%s' "$encoded" | base64 -d > "$kubeconfig" 2>/dev/null; then
    return 1
  fi
  [[ -s "$kubeconfig" ]]
}
guest_oc() {
  ensure_kubeconfig || return 1
  oc --kubeconfig="$kubeconfig" --server="https://$vip:6443" \
    --insecure-skip-tls-verify --request-timeout=10s "$@"
}

case "$action" in
  auto)
    poll_seconds=${CAAS_WA_POLL_SECONDS:-15}
    [[ "$poll_seconds" =~ ^[0-9]+$ && "$poll_seconds" -ge 5 ]] || die 'CAAS_WA_POLL_SECONDS must be an integer of at least 5.'
    command -v flock >/dev/null || die 'flock is required for auto mode.'
    exec {lock_fd}>"/tmp/caas-wa-${order}.lock"
    flock -n "$lock_fd" || die "Another caas-wa.sh auto watcher is already running for $order."
    log "Watching $order ($domain); checking every ${poll_seconds}s. Press Ctrl-C to stop."
    api_done=false
    agent_done=false
    finish_done=false
    refresh_done=false
    last_summary=''
    last_heartbeat=0
    last_console_check=0
    finish_at=0
    applied_vip=''
    watched_worker=''
    while true; do
      if ! refresh_context; then
        log "Cannot read $order now; retrying."
        sleep "$poll_seconds"
        continue
      fi
      now=$(date +%s)
      current_worker="$bmh/$guest_uuid"
      if [[ -n "$watched_worker" && "$current_worker" != "$watched_worker" ]]; then
        log "Worker changed from $watched_worker to $current_worker; rechecking worker workarounds."
        agent_done=false
        finish_done=false
        refresh_done=false
        finish_at=0
      fi
      watched_worker=$current_worker
      if [[ "$api_done" == true && "$vip" != "$applied_vip" ]]; then
        log "API VIP changed from $applied_vip to ${vip:-pending}; rechecking DNS."
        api_done=false
        agent_done=false
        finish_done=false
        refresh_done=false
        finish_at=0
      fi
      summary="phase=$order_phase VIP=${vip:-pending} BMH=${bmh:-pending}/${bmh_state:-pending} Agent=${agent_state:-pending}"
      if [[ "$summary" != "$last_summary" || $((now - last_heartbeat)) -ge 120 ]]; then
        log "$summary"
        last_summary=$summary
        last_heartbeat=$now
      fi
      if [[ "$order_phase" == Ready ]]; then
        log "ClusterOrder $order is Ready. All required workarounds have completed."
        exit 0
      fi
      if [[ "$order_phase" == Failed ]]; then
        die "ClusterOrder $order failed; inspect oc -n osac describe clusterorder $order."
      fi

      if [[ "$api_done" == false && "$vip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "Trigger: hosted API VIP $vip is assigned. Applying libvirt api/api-int DNS."
        if bmf_dns api "$vip"; then
          api_done=true
          applied_vip=$vip
          log 'WA applied: hosted API DNS is available from the worker network.'
        else
          log 'Hosted API DNS update failed; will retry.'
        fi
      fi

      if [[ "$agent_done" == false && "$api_done" == true && "$bmh_state" == provisioned && "$agent_state" == insufficient ]]; then
        dns_errors=$(jq -r '
          ([.status.validationsInfo[][]? | select(.status == "failure") | .message] +
           [.status.conditions[]? | select(.status == "False") | .message]) | join(" ")' <<< "$agent_json")
        if grep -Eiq 'resolv|dns|lookup|api-int|apps\.' <<< "$dns_errors"; then
          log "Trigger: Agent $guest_uuid is insufficient with DNS validation errors. Applying temporary wildcard DNS."
          if bash "$0" agent-dns "$order"; then
            agent_done=true
            log 'WA applied: worker wildcard DNS is set and agent.service restarted.'
          else
            log 'Agent DNS update failed or the install stage changed; will recheck.'
          fi
        fi
      fi
      if [[ "$agent_state" == installing || "$agent_state" == installed || "$agent_state" == done ]]; then
        agent_done=true
      fi

      if [[ "$finish_done" == false && "$bmh_state" == provisioned && -n "$vip" && -n "$node" ]]; then
        node_json=$(guest_oc get node "$node" -o json 2>/dev/null || true)
        node_ready=$(jq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // "False"' <<< "$node_json" 2>/dev/null || true)
        if [[ "$node_ready" == True ]]; then
          log "Trigger: guest node $node is Ready. Applying providerID and apps DNS workarounds."
          if bash "$0" finish "$order"; then
            finish_done=true
            finish_at=$now
            log 'WA applied: providerID checked, apps DNS points to the worker, and temporary resolver removed.'
          else
            log 'Post-install workaround failed; will retry while the node stays Ready.'
          fi
        fi
      fi

      if [[ "$finish_done" == true && "$refresh_done" == false && $((now - finish_at)) -ge 60 && $((now - last_console_check)) -ge 60 ]]; then
        last_console_check=$now
        console_json=$(guest_oc get co console -o json 2>/dev/null || true)
        console_available=$(jq -r '[.status.conditions[]? | select(.type == "Available") | .status][0] // "Unknown"' <<< "$console_json" 2>/dev/null || true)
        if [[ "$console_available" == False ]]; then
          console_logs=$(guest_oc -n openshift-console-operator logs deploy/console-operator --since=3m --tail=100 2>/dev/null || true)
          if grep -Fqi 'server misbehaving' <<< "$console_logs"; then
            resolver=$(guest_ssh "grep -m1 '^nameserver' /etc/resolv.conf" 2>/dev/null || true)
            if [[ "$resolver" == *192.168.122.1* ]]; then
              log 'Trigger: console operator reports DNS server misbehaving after resolver cleanup. Restarting DNS and console operator pods.'
              if bash "$0" refresh-dns "$order"; then
                refresh_done=true
                log 'WA applied: guest DNS and console operator pods restarted.'
              else
                log 'DNS pod refresh failed; will retry after the next check.'
              fi
            else
              log "Console DNS error detected, but worker resolver is ${resolver:-unavailable}; waiting for resolver recovery."
            fi
          fi
        fi
      fi
      sleep "$poll_seconds"
    done
    ;;
  status)
    echo "Order: $order; DNS: $domain; API VIP: ${vip:-pending}; BMH: ${bmh:-pending}; guest: ${guest_ip:-pending}"
    oc -n osac get clusterorder "$order"
    oc -n osac get bmh,bmi,agent
    oc get nodepool -A
    if [[ -f "$HOME/aap-jobs.sh" ]]; then
      bash "$HOME/aap-jobs.sh" list -n 5 --name osac-create
    fi
    ;;
  agent-dns)
    need_vip
    need_worker
    state=$(oc -n osac get bmh "$bmh" -o jsonpath='{.status.provisioning.state}')
    [[ "$state" == provisioned ]] || die "Wait for $bmh to be provisioned (now $state)."
    [[ "$agent_state" == insufficient ]] || die "Agent is not in insufficient state (now ${agent_state:-pending}); refusing to restart it."
    bmf_dns api "$vip"
    guest_ssh "sudo bash -s -- '$domain' '$vip'" <<'REMOTE'
set -euo pipefail
domain=$1 vip=$2
if systemctl is-active --quiet kubelet; then
  echo 'The worker has already booted into the installed OS; do not restart the Agent.' >&2
  exit 1
fi
install -d /etc/NetworkManager/dnsmasq.d /etc/NetworkManager/conf.d
printf 'address=/.%s/%s\n' "$domain" "$vip" > /etc/NetworkManager/dnsmasq.d/hosted.conf
printf '[main]\ndns=dnsmasq\n' > /etc/NetworkManager/conf.d/90-dnsmasq.conf
systemctl reload NetworkManager
for attempt in {1..10}; do
  if getent hosts "api.$domain" >/dev/null && getent hosts "probe.apps.$domain" >/dev/null; then
    systemctl restart agent.service
    echo 'Agent DNS is ready; agent.service restarted.'
    exit 0
  fi
  sleep 2
done
echo 'Guest DNS did not become ready; Agent was not restarted.' >&2
exit 1
REMOTE
    ;;
  finish)
    need_vip
    need_worker
    ensure_kubeconfig || die 'Guest kubeconfig secret is not ready.'
    node_json=$(guest_oc get node "$node" -o json)
    ready=$(jq -r '[.status.conditions[] | select(.type == "Ready") | .status][0] // "False"' <<< "$node_json")
    [[ "$ready" == True ]] || die "Guest node $node is not Ready yet."
    provider_id=$(jq -r '.spec.providerID // empty' <<< "$node_json")
    if [[ -z "$provider_id" ]]; then
      guest_oc patch node "$node" --type=merge \
        -p "{\"spec\":{\"providerID\":\"agent://$guest_uuid\"}}"
      echo "Set providerID=agent://$guest_uuid on $node"
    elif [[ "$provider_id" == "agent://$guest_uuid" ]]; then
      echo "ProviderID already set: $provider_id"
    else
      die "Node $node has unexpected providerID $provider_id; refusing to modify it."
    fi
    bmf_dns apps "$guest_ip"
    guest_ssh 'sudo bash -s' <<'REMOTE'
set -euo pipefail
if [[ -e /etc/NetworkManager/conf.d/90-dnsmasq.conf || -e /etc/NetworkManager/dnsmasq.d/hosted.conf ]]; then
  rm -f /etc/NetworkManager/conf.d/90-dnsmasq.conf /etc/NetworkManager/dnsmasq.d/hosted.conf
  systemctl reload NetworkManager
fi
echo "Worker resolver: $(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
REMOTE
    echo 'Wait for NodePool 1/1 and ClusterOrder Ready; run status to watch.'
    ;;
  refresh-dns)
    need_vip
    echo 'Restarting guest DNS and console operator pods after confirmed DNS server misbehaving error.'
    guest_oc delete pod -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default
    guest_oc delete pod -n openshift-console-operator --all
    ;;
  access)
    # Solve path for Exercise 6: publish the hosted API and console through the hub router.
    need_vip
    [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Worker guest IP is not available yet.'
    ensure_kubeconfig || die 'Guest kubeconfig secret is not ready.'
    hcp_ns="osac-$order"
    apps=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
    [[ "$apps" =~ ^[a-z0-9.-]+$ ]] || die 'Hub apps domain is missing or invalid.'
    console_host="console-$order.$apps"
    oc create namespace osac-hosted-access --dry-run=client -o yaml | oc apply -f - >/dev/null
    for svc in "api 6443 $vip api-$order.$apps" "console 443 $guest_ip $console_host"; do
      read -r kind port ip host <<< "$svc"
      oc apply -n osac-hosted-access -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $kind-$order
spec:
  ports:
  - name: https
    port: $port
    targetPort: $port
    protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $kind-$order
  labels:
    kubernetes.io/service-name: $kind-$order
    endpointslice.kubernetes.io/managed-by: osac-lab
addressType: IPv4
ports:
- name: https
  port: $port
  protocol: TCP
endpoints:
- addresses:
  - $ip
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $kind-$order
spec:
  host: $host
  to:
    kind: Service
    name: $kind-$order
  port:
    targetPort: https
  tls:
    termination: passthrough
EOF
    done
    # Reuse the hub's trusted *.apps wildcard; per-host DNS-01 certs leave stale _acme-challenge records here
    hub_cert=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}')
    [[ -n "$hub_cert" ]] || die 'Hub ingress controller has no default certificate.'
    tls_json=$(oc get secret "$hub_cert" -n openshift-ingress -o json)
    tls_secret() {
      jq --arg ns "$1" '{apiVersion: "v1", kind: "Secret", type: "kubernetes.io/tls",
        metadata: {name: "console-custom-tls", namespace: $ns},
        data: {"tls.crt": .data["tls.crt"], "tls.key": .data["tls.key"]}}' <<< "$tls_json"
    }
    tls_secret "$hcp_ns" | oc apply -f -
    tls_secret openshift-config | guest_oc apply -f -
    oc patch hostedcluster "$order" -n "$hcp_ns" --type merge -p "$(jq -nc --arg h "$console_host" \
      '{spec: {configuration: {ingress: {componentRoutes: [{name: "console", namespace: "openshift-console",
        hostname: $h, servingCertKeyPairSecret: {name: "console-custom-tls"}}]}}}}')"
    # Trust the hosted OAuth route too: the hub wildcard covers it. "names" is required by HyperShift's CEL rule.
    oauth_host=$(oc get route oauth -n "$hcp_ns-$order" -o jsonpath='{.spec.host}')
    [[ "$oauth_host" =~ ^[a-z0-9.-]+$ ]] || die 'Hosted OAuth route not found.'
    oauth_patch=$(oc patch hostedcluster "$order" -n "$hcp_ns" --type merge -p "$(jq -nc --arg h "$oauth_host" \
      '{spec: {configuration: {apiServer: {servingCerts: {namedCertificates: [{names: [$h],
        servingCertificate: {name: "console-custom-tls"}}]}}}}}')")
    echo "$oauth_patch"
    if [[ "$oauth_patch" != *"(no change)"* ]]; then
      # The patch rolls kube-apiserver and oauth-openshift; OAuth returns 400/500 for ~2 min after healthz is up
      log "Waiting for OAuth on $oauth_host to serve the trusted certificate..."
      for _ in {1..60}; do
        curl -fsS -m 5 -o /dev/null "https://$oauth_host/healthz" 2>/dev/null && break
        sleep 10
      done
      curl -fsS -m 5 -o /dev/null "https://$oauth_host/healthz" || die "OAuth on $oauth_host not healthy with a trusted certificate."
      sleep 90
    fi
    log "Waiting for the hosted console operator to serve $console_host..."
    for _ in {1..60}; do
      route_host=$(guest_oc get route console-custom -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)
      available=$(guest_oc get co console -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
      if [[ "$route_host" == "$console_host" && "$available" == True ]]; then
        echo "API:     https://api-$order.$apps"
        echo "Console: https://$console_host"
        echo "OAuth:   https://$oauth_host"
        exit 0
      fi
      sleep 10
    done
    die "Console not Available on $console_host after 10 minutes (route=${route_host:-none}, Available=${available:-unknown})."
    ;;
esac
