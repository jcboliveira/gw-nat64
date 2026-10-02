# GW-NAT64

Dual-stack gateway for Kathara labs. It assigns addresses using DHCPv4 and DHCPv6, provides DNS64, and forwards IPv4 and NAT64 traffic to the external network.

> **Warning:** `2001:db8:64::/64` is reserved for documentation. Use it only in an isolated lab; it is not routable on the Internet.

## Features

| Service | Implementation | Configuration |
| --- | --- | --- |
| DHCPv4 | dnsmasq | `192.168.1.100` to `192.168.1.200` |
| DHCPv6 | dnsmasq stateful | `2001:db8:64::100` to `2001:db8:64::200` |
| Router Advertisement | radvd | advertises the router and prefix; SLAAC is disabled |
| DNS64 | BIND 9 | synthesizes AAAA records using the `64:ff9b::/96` prefix |
| NAT64 | Tayga | translates IPv6 traffic to IPv4 destinations |
| NAT44 | nftables | enables clients' IPv4 egress through the external interface |

RA is still required to advertise the IPv6 router. `AdvAutonomous off` disables SLAAC; IPv6 addresses are assigned through DHCPv6. DHCPv6 does not advertise the default route, so clients learn the router from RA.

## Addressing

| Purpose | Address |
| --- | --- |
| IPv4 gateway on the Kathara network | `192.168.1.1/24` |
| DHCPv4 pool | `192.168.1.100-192.168.1.200` |
| IPv6 gateway on the Kathara network | `2001:db8:64::1/64` |
| DHCPv6 pool | `2001:db8:64::100-2001:db8:64::200` |
| NAT64 prefix | `64:ff9b::/96` |
| Tayga internal IPv4 pool | `192.0.0.0/24` |

> Make sure these prefixes do not conflict with other lab networks. The entrypoint uses the interface with the IPv4 default route as the external interface and identifies the other interface as the LAN. If there is more than one LAN interface, set `LAN_IF` explicitly.

## Requirements

- Docker access to the daemon and IPv6 support on the required networks.
- An external network with IPv4 connectivity.
- A separate Kathara network for clients, connected to the same Layer 2 segment as the gateway.
- The Kathara network must support the prefixes above and reserve `192.168.1.1` and `2001:db8:64::1` for the gateway.
- The host must provide `/dev/net/tun`.

Do not connect the DHCP interface to a shared physical LAN: the server responds to DHCP clients on that segment. Clients must be on the same Layer 2 domain; DHCP relay is not configured.

## Quick Start with Kathara

1. Start the lab as usual with `kathara lstart`.
2. From this repository, run:

```bash
./start-gateway.sh
```

The script builds the image, finds the Kathara network for domain `GW`, creates `ext-net` if needed, and starts the gateway connected to the WAN and LAN. To use a different WAN network, set `GW_EXTERNAL_NETWORK` before running the script. To stop and remove the gateway:

```bash
./start-gateway.sh stop
```

The container starts with `--privileged` so Tayga can use TUN and the entrypoint can configure IPv6. This gives the gateway broad access to the host, so use it only in an isolated lab. If more than one lab with a `GW` domain is active, stop the other labs before running the script.

## Manual Container Creation (Docker)

This option is for administration or troubleshooting. For normal student use, run only `./start-gateway.sh`; do not combine the two methods. The manual flow uses `docker create` to create the container and `docker start` to start it.

Build the image:

```bash
docker build -t gw-nat64 .
```

Create or identify the external network. `ext-net` is only an example:

```bash
docker network create ext-net
```

Find the name of the Docker network created by Kathara **before** connecting the container to it. Kathara names networks as `kathara_<lab-hash>_<domain>_<hash>`; the prefix and suffix are generated automatically, cannot be fixed in `lab.conf`, and change if the lab is recreated. Instead of entering the full name, filter by the collision domain declared in `lab.conf` (`GW` in this example, e.g. `br[2]=GW`):

```bash
KATHARA_NET=$(docker network ls --format '{{.Name}}' | grep '_GW_')
echo "$KATHARA_NET"
```

Create the container attached to the external network first (`$KATHARA_NET` is not used yet; it is only used by the `docker network connect` command below). Then connect it to the lab network **before starting it**. The entrypoint identifies the external interface from the IPv4 default route and uses the other interface as the LAN:

```bash
docker create \
  --name gw-nat64 \
  --network ext-net \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
  --security-opt systempaths=unconfined \
  --security-opt apparmor=unconfined \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  gw-nat64

docker network connect "$KATHARA_NET" gw-nat64

docker start gw-nat64
```

Kathara networks use a custom driver (`kathara/katharanp_vde`) without real Docker IPAM (IPv6 is disabled and the subnet is `0.0.0.0/0`), so `docker network connect` does not accept `--ip` or `--ip6` on these networks. The `entrypoint.sh` configures `192.168.1.1/24` and `2001:db8:64::1/64` on the LAN interface. Verify the result after startup with `docker exec gw-nat64 ip -brief address`.

Docker disables IPv6 by default on any interface connected to a network without IPv6 enabled (such as Kathara networks) and mounts `/proc/sys` read-only in unprivileged containers, preventing `entrypoint.sh` from re-enabling IPv6 on that interface. `--security-opt systempaths=unconfined` allows writes to `/proc/sys`; `--security-opt apparmor=unconfined` removes the default policy that also blocks those writes. Without both options, the container fails to start with `Error: ipv6: IPv6 is disabled on this device`.

The gateway advertises the default route and performs outbound NAT. The segment is isolated at the Kathara network level, but clients can reach external networks through the gateway. The Kathara topology must connect clients to the same Docker network used in `KATHARA_NET`.

## Verification

Check startup and logs:

```bash
docker logs gw-nat64
```

On the clients, confirm that they received IPv4 and IPv6 addresses through DHCP and learned the IPv6 gateway through RA. To test DNS64, query a name that has only an A record:

```bash
dig AAAA ipv4only.arpa @192.168.1.1
```

The synthesized response should use the `64:ff9b::/96` prefix.

## Gateway in an LXC on Proxmox

This option creates a lab network separate from the physical bridge. The LXC has an external interface with IPv4 connectivity and another interface connected to the private network. Clients receive IPv4 through DHCPv4 and IPv6 through DHCPv6; RA advertises the default route. IPv4 uses NAT44, and IPv6 clients reach IPv4 destinations through DNS64/NAT64.

> **Prefix limitation:** `2001:db8:64::/64` is reserved for documentation. With the values in this guide, IPv6 clients can reach IPv4 destinations through NAT64, but not native IPv6 destinations. For native IPv6 Internet access, use a global `/64` delegated by your ISP, configure the route in Proxmox, and replace the prefix in `entrypoint.sh`, `radvd.conf`, and `dnsmasq.conf`.

### 1. Create the isolated bridge

On the Proxmox host, add this to `/etc/network/interfaces`:

```ini
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

`vmbr1` has no physical port or IP address on the host. Apply the configuration with `ifreload -a` (ifupdown2), or restart networking during a maintenance window.

### 2. Create the gateway LXC

Use a Debian 12 template available in Proxmox storage; adjust the template path, ID, and external interface configuration for your installation:

```bash
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname gw-nat64 \
  --cores 2 --memory 1024 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --net1 name=eth1,bridge=vmbr1,ip=manual,ip6=manual \
  --unprivileged 0
```

This example uses a privileged LXC so the entrypoint can create the TUN interface, change routes and sysctls, and configure nftables. This reduces isolation between the container and the host: keep the LXC updated and do not expose unnecessary services. An unprivileged installation requires adjusting and validating these permissions in Proxmox.

Tayga requires `/dev/net/tun`. On the Proxmox host, load the `tun` module if needed and add the following to `/etc/pve/lxc/200.conf`:

```ini
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Start the LXC and install the dependencies:

```bash
pct start 200
pct exec 200 -- apt update
pct exec 200 -- apt install -y tayga radvd dnsmasq gettext-base bind9 iproute2 nftables procps
pct exec 200 -- bash -lc 'systemctl disable --now tayga radvd dnsmasq bind9 || true'
```

### 3. Copy the configuration and start the services

Run the `pct push` commands below on the Proxmox host; the source files from this repository must be available there:

```bash
pct push 200 ./entrypoint.sh /usr/local/sbin/gw-nat64-entrypoint --perms 0755
pct push 200 ./tayga.conf /etc/tayga.conf
pct push 200 ./radvd.conf /etc/radvd.conf.template
pct push 200 ./dnsmasq.conf /etc/dnsmasq.conf.template
pct push 200 ./named.conf.options /etc/bind/named.conf.options
```

Enter the LXC and create `/etc/systemd/system/gw-nat64.service`:

```ini
[Unit]
Description=Gateway DHCP, DNS64 e NAT64
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=LAN_IF=eth1
ExecStart=/usr/local/sbin/gw-nat64-entrypoint
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Enable the service inside the LXC:

```bash
systemctl daemon-reload
systemctl enable --now gw-nat64
systemctl status gw-nat64
```

The entrypoint configures `192.168.1.1/24` and `2001:db8:64::1/64` on `eth1`; `eth0` is the external interface and must have an IPv4 default route. If the LAN interface has a different name, change `LAN_IF` in the unit. Start the gateway before the clients so DHCP and RA are available.

### 4. Connect the clients and verify

Connect the client VMs or other LXCs to `vmbr1`, configure their interfaces to obtain IPv4 through DHCP, and enable DHCPv6. Do not use SLAAC to obtain addresses: the prefix is advertised with `AdvAutonomous off`. Allow DHCP (UDP 67/68 and 546/547), ICMPv6/NDP/RA, and forwarding between `vmbr1` and the external interface in the Proxmox firewall.

On the clients, confirm they receive addresses from the `192.168.1.0/24` and `2001:db8:64::/64` prefixes, along with a default route. Test DNS64 resolution using `192.168.1.1`:

```bash
dig AAAA ipv4only.arpa @192.168.1.1
```

For a production network, choose subnets that do not conflict with the existing LAN. Do not use the `2001:db8` prefix outside a lab; for native IPv6, use a publicly routed prefix rather than simply replacing it with a ULA.

## Files

- `Dockerfile`: Debian 12 image and dependencies.
- `entrypoint.sh`: configures interfaces, forwarding, routes, and NAT; starts the services.
- `dnsmasq.conf`: DHCPv4/DHCPv6 pools and DNS options.
- `radvd.conf`: IPv6 advertisements with SLAAC disabled.
- `named.conf.options`: recursive DNS with DNS64.
- `tayga.conf`: NAT64 configuration.

The Dockerfile builds the Docker image. The Proxmox section reuses the configuration files and entrypoint in a Debian LXC; Proxmox/systemd manage its networking and services.