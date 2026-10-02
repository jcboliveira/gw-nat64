#!/bin/bash
set -e

LAN_IF=${LAN_IF:-}
EXT_IF=$(ip -o -4 route show default | awk 'NR==1 {print $5; exit}')

if [[ -z "$EXT_IF" ]]; then
	printf 'No IPv4 default route found; connect the external network before starting.\n' >&2
	exit 1
fi

if [[ -z "$LAN_IF" ]]; then
	for iface_path in /sys/class/net/*; do
		candidate=${iface_path##*/}
		if [[ ! -e "$iface_path/ifindex" ]]; then
			continue
		fi
		if [[ "$candidate" == lo || "$candidate" == nat64 || "$candidate" == "$EXT_IF" ]]; then
			continue
		fi
		if [[ -n "$LAN_IF" ]]; then
			printf 'More than one LAN interface candidate found; set LAN_IF explicitly.\n' >&2
			exit 1
		fi
		LAN_IF=$candidate
	done
fi

if [[ -z "$LAN_IF" || "$LAN_IF" == "$EXT_IF" ]]; then
	printf 'Set LAN_IF to the Kathara-facing interface (different from %s).\n' "$EXT_IF" >&2
	exit 1
fi
export LAN_IF

# Already set via docker create --sysctl; ignore if read-only in this container.
sysctl -w net.ipv4.ip_forward=1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 || true

# Configure the Kathara-facing network for dual-stack clients.
if ! ip link show dev "$LAN_IF" >/dev/null 2>&1; then
	printf 'Interface %s not found; set LAN_IF to the Kathara interface.\n' "$LAN_IF" >&2
	exit 1
fi
ip link set dev "$LAN_IF" up
# Kathara networks without Docker IPv6 IPAM disable IPv6 per-interface by default.
sysctl -w "net.ipv6.conf.${LAN_IF}.disable_ipv6=0"
ip address replace 192.168.1.1/24 dev "$LAN_IF"
ip -6 address replace 2001:db8:64::1/64 dev "$LAN_IF"
mkdir -p /run /var/lib/misc
envsubst '${LAN_IF}' < /etc/radvd.conf.template > /run/radvd.conf
envsubst '${LAN_IF}' < /etc/dnsmasq.conf.template > /run/dnsmasq.conf

# criar/subir a interface do tayga (NAT64)
mkdir -p /var/db/tayga
tayga --mktun -c /etc/tayga.conf
ip link set nat64 up
ip route replace 64:ff9b::/96 dev nat64
ip route replace 192.0.0.0/24 dev nat64

# NAT44 para a saída IPv4.
nft add table ip nat 2>/dev/null || true
nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
nft add rule ip nat postrouting ip saddr 192.0.0.0/24 oif "$EXT_IF" masquerade
nft add rule ip nat postrouting ip saddr 192.168.1.0/24 oif "$EXT_IF" masquerade

tayga -c /etc/tayga.conf --nodetach &
named -f -c /etc/bind/named.conf &
radvd -n -C /run/radvd.conf &
dnsmasq --keep-in-foreground --conf-file=/run/dnsmasq.conf &

wait -n

