FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    tayga radvd dnsmasq gettext-base bind9 iproute2 nftables iptables-persistent procps \
    && rm -rf /var/lib/apt/lists/*

COPY tayga.conf /etc/tayga.conf
COPY radvd.conf /etc/radvd.conf.template
COPY dnsmasq.conf /etc/dnsmasq.conf.template
COPY named.conf.options /etc/bind/named.conf.options
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
