#!/usr/bin/env bash
# Managed by Ansible (ocp4_workload_osac).
# Re-applies the OSAC BMF forwarding/NAT rules in one atomic nft batch.
# Rules owned here carry comment "osac" and are replaced on every run.
# Run by osac-bmf-nft.service (boot + timer) and the libvirt network hook.
set -euo pipefail

# Hub control-plane IPs; metal3-httpd (:6180) runs on whichever node hosts the metal3 pod
METAL3_HOSTS="10.10.10.10 10.10.10.11 10.10.10.12"
IRONIC_VIP=10.10.10.100

batch=$(mktemp)
trap 'rm -f "$batch"' EXIT

# Delete rules owned by previous runs (and any legacy :6180 DNAT)
delete_owned() {
  nft -a list chain "$@" 2>/dev/null |
    awk -v c="$*" '/comment "osac"/ || (c ~ /prerouting/ && /tcp dport 6180/) {print "delete rule " c " handle " $NF}'
}

{
  echo 'add chain inet nat prerouting { type nat hook prerouting priority dstnat; }'
  delete_owned inet filter forward
  delete_owned inet nat postrouting
  delete_owned inet nat prerouting

  cat <<'EOF'
insert rule inet filter forward iifname "virbr0" oifname "enp2s0" accept comment "osac"
insert rule inet filter forward iifname "enp2s0" oifname "virbr0" ct state established,related accept comment "osac"
insert rule inet filter forward iifname "enp2s0" oifname "virbr0" ip daddr 192.168.122.0/24 tcp dport 9999 ct state new accept comment "osac"
insert rule inet filter forward iifname "enp2s0" oifname "virbr0" icmp type echo-request accept comment "osac"
insert rule inet filter forward iifname "virbr0" oifname "enp1s0" accept comment "osac"
insert rule inet filter forward iifname "enp1s0" oifname "virbr0" ct state established,related accept comment "osac"
add rule inet nat postrouting ip saddr 192.168.122.0/24 oifname "enp2s0" masquerade comment "osac"
add rule inet nat postrouting ip saddr 192.168.122.0/24 oifname "enp1s0" masquerade comment "osac"
EOF

  for ip in $METAL3_HOSTS; do
    if curl -s -o /dev/null -m 2 "http://$ip:6180/"; then
      echo "add rule inet nat prerouting ip daddr $IRONIC_VIP tcp dport 6180 dnat to $ip comment \"osac\""
      break
    fi
  done

  # libvirt rebuilds this table whenever the network or virtnetworkd restarts
  if nft list table ip libvirt_network >/dev/null 2>&1; then
    delete_owned ip libvirt_network guest_input
    # Stateless masquerade rewrites guest replies to Ironic's inbound :9999; keep only "ct state new"
    nft -a list chain ip libvirt_network guest_nat |
      awk '/masquerade/ && !/ct state new/ {print "delete rule ip libvirt_network guest_nat handle " $NF}'
    echo 'insert rule ip libvirt_network guest_input oif "virbr0" ip daddr 192.168.122.0/24 tcp dport 9999 accept comment "osac"'
    if ! nft list chain ip libvirt_network guest_nat | grep -q 'ct state new'; then
      cat <<'EOF'
add rule ip libvirt_network guest_nat meta l4proto { tcp, udp } ip saddr 192.168.122.0/24 ip daddr != 192.168.122.0/24 ct state new masquerade to :1024-65535
add rule ip libvirt_network guest_nat ip saddr 192.168.122.0/24 ip daddr != 192.168.122.0/24 ct state new masquerade
EOF
    fi
  fi
} > "$batch"

nft -f "$batch"
