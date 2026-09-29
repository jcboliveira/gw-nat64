# GW-NAT64

Gateway dual-stack para laboratórios Kathará. Distribui endereços por DHCPv4 e DHCPv6, oferece DNS64 e encaminha tráfego IPv4 e NAT64 para a rede externa.

> **Atenção:** `2001:db8:64::/64` é um prefixo reservado para documentação. Use-o apenas em laboratório isolado; não é roteável na Internet.

## Recursos

| Serviço | Implementação | Configuração |
| --- | --- | --- |
| DHCPv4 | dnsmasq | `192.168.1.100` a `192.168.1.200` |
| DHCPv6 | dnsmasq stateful | `2001:db8:64::100` a `2001:db8:64::200` |
| Router Advertisement | radvd | anuncia roteador e prefixo; SLAAC desativado |
| DNS64 | BIND 9 | sintetiza AAAA no prefixo `64:ff9b::/96` |
| NAT64 | Tayga | traduz IPv6 para destinos IPv4 |
| NAT44 | nftables | permite saída IPv4 dos clientes pela interface externa |

O RA continua necessário para anunciar o roteador IPv6. `AdvAutonomous off` desativa SLAAC; os endereços IPv6 são entregues por DHCPv6. DHCPv6 não anuncia a rota padrão, por isso os clientes aprendem o roteador pelo RA.

## Endereçamento

| Uso | Endereço |
| --- | --- |
| Gateway IPv4 na rede Kathará | `192.168.1.1/24` |
| Pool DHCPv4 | `192.168.1.100-192.168.1.200` |
| Gateway IPv6 na rede Kathará | `2001:db8:64::1/64` |
| Pool DHCPv6 | `2001:db8:64::100-2001:db8:64::200` |
| Prefixo NAT64 | `64:ff9b::/96` |
| Pool IPv4 interno do Tayga | `192.0.0.0/24` |

> Verifique se esses prefixos não conflitam com outras redes do laboratório. O gateway usa `eth1` como interface Kathará por padrão; configure `LAN_IF` se a interface tiver outro nome. A interface com a rota IPv4 padrão é usada como saída externa.

## Requisitos

- Docker com acesso ao daemon e suporte a IPv6 nas redes necessárias.
- Uma rede externa com conectividade IPv4.
- Uma rede Kathará separada para os clientes, conectada ao mesmo segmento L2 do gateway.
- A rede Kathará deve comportar os prefixos acima e reservar `192.168.1.1` e `2001:db8:64::1` para o gateway.
- O host deve disponibilizar `/dev/net/tun`.

Não conecte a interface DHCP a uma LAN física compartilhada: o servidor responde aos clientes DHCP nesse segmento. Os clientes precisam estar no mesmo domínio de camada 2; DHCP relay não está configurado.

## Build e execução

Construa a imagem:

```bash
docker build -t gw-nat64 .
```

Crie ou identifique a rede externa. `ext-net` é apenas um exemplo:

```bash
docker network create ext-net
```

Crie o container ligado primeiro à rede externa. Depois conecte-o à rede do laboratório **antes de iniciá-lo**; assim, a LAN será normalmente `eth1`:

```bash
docker create \
  --name gw-nat64 \
  --network ext-net \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  -e LAN_IF=eth1 \
  gw-nat64

KATHARA_NET="nome-da-rede-kathara"
docker network connect \
  --ip 192.168.1.1 \
  --ip6 2001:db8:64::1 \
  "$KATHARA_NET" gw-nat64

docker start gw-nat64
```

Defina `KATHARA_NET` com o nome da rede Docker criada pelo Kathará. Configure essa rede para os prefixos deste guia e reserve os endereços do gateway. Se a ordem ou o nome das interfaces for diferente, ajuste `LAN_IF` antes de iniciar o container.

O gateway anuncia a rota padrão e faz NAT de saída. Portanto, a rede é isolada no nível do segmento Kathará, mas os clientes podem alcançar redes externas através do gateway. A topologia Kathará precisa conectar os clientes à mesma rede Docker usada em `KATHARA_NET`.

## Verificação

Confira a inicialização e os logs:

```bash
docker logs gw-nat64
```

Nos clientes, confirme que receberam endereços IPv4 e IPv6 por DHCP e que têm o gateway IPv6 anunciado por RA. Para testar DNS64, consulte um nome que tenha apenas registro A:

```bash
dig AAAA ipv4only.arpa @192.168.1.1
```

A resposta sintetizada deve usar `64:ff9b::/96`.

## Gateway em LXC no Proxmox

Esta opção cria uma rede de laboratório separada do bridge físico. O LXC tem uma interface externa com saída IPv4 e outra ligada à rede privada. Os clientes recebem IPv4 por DHCPv4 e IPv6 por DHCPv6; o RA anuncia a rota padrão. IPv4 sai por NAT44 e clientes IPv6 alcançam destinos IPv4 pela combinação DNS64/NAT64.

> **Limite do prefixo:** `2001:db8:64::/64` é reservado para documentação. Com os valores deste guia, clientes IPv6 têm acesso a destinos IPv4 via NAT64, mas não a destinos IPv6 nativos. Para IPv6 nativo na Internet, use um `/64` global delegado pelo ISP, configure a rota no Proxmox e substitua o prefixo nos arquivos `entrypoint.sh`, `radvd.conf` e `dnsmasq.conf`.

### 1. Criar a bridge isolada

No host Proxmox, acrescente em `/etc/network/interfaces`:

```ini
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

`vmbr1` não tem porta física nem endereço IP no host. Aplique a configuração com `ifreload -a` (ifupdown2) ou durante uma janela de manutenção reinicie a rede.

### 2. Criar o LXC gateway

Use um template Debian 12 disponível no storage do Proxmox; ajuste o caminho do template, o ID e a configuração da interface externa à sua instalação:

```bash
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname gw-nat64 \
  --cores 2 --memory 1024 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --net1 name=eth1,bridge=vmbr1,ip=manual,ip6=manual \
  --unprivileged 0
```

O exemplo usa um LXC privilegiado para permitir ao entrypoint criar a interface TUN, alterar rotas/sysctls e configurar nftables. Isso reduz o isolamento entre o container e o host: mantenha o LXC atualizado e não exponha serviços desnecessários. Uma instalação não privilegiada exige ajustar e validar essas permissões no Proxmox.

O Tayga precisa de `/dev/net/tun`. No host Proxmox, carregue o módulo `tun` se necessário e acrescente ao `/etc/pve/lxc/200.conf`:

```ini
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Inicie o LXC e instale as dependências:

```bash
pct start 200
pct exec 200 -- apt update
pct exec 200 -- apt install -y tayga radvd dnsmasq gettext-base bind9 iproute2 nftables procps
pct exec 200 -- bash -lc 'systemctl disable --now tayga radvd dnsmasq bind9 || true'
```

### 3. Copiar a configuração e iniciar os serviços

Os comandos `pct push` abaixo são executados no host Proxmox; os arquivos de origem do repositório precisam estar acessíveis nele:

```bash
pct push 200 ./entrypoint.sh /usr/local/sbin/gw-nat64-entrypoint --perms 0755
pct push 200 ./tayga.conf /etc/tayga.conf
pct push 200 ./radvd.conf /etc/radvd.conf.template
pct push 200 ./dnsmasq.conf /etc/dnsmasq.conf.template
pct push 200 ./named.conf.options /etc/bind/named.conf.options
```

Entre no LXC e crie `/etc/systemd/system/gw-nat64.service`:

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

Ative o serviço dentro do LXC:

```bash
systemctl daemon-reload
systemctl enable --now gw-nat64
systemctl status gw-nat64
```

O entrypoint configura `192.168.1.1/24` e `2001:db8:64::1/64` em `eth1`; `eth0` é a saída e precisa obter uma rota IPv4 padrão. Se `eth1` tiver outro nome, altere `LAN_IF` na unit. O gateway deve ser iniciado antes dos clientes para que DHCP e RA estejam disponíveis.

### 4. Ligar os clientes e verificar

Conecte as VMs ou outros LXC clientes a `vmbr1`, configure as interfaces para obter IPv4 por DHCP e habilite DHCPv6. Não configure SLAAC para obter endereços: o prefixo é anunciado com `AdvAutonomous off`. Permita no firewall do Proxmox DHCP (UDP 67/68 e 546/547), ICMPv6/NDP/RA e o encaminhamento entre `vmbr1` e a interface externa.

Nos clientes, confirme o recebimento de endereços nos prefixos `192.168.1.0/24` e `2001:db8:64::/64`, além da rota padrão. Teste a resolução DNS64 apontando para `192.168.1.1`:

```bash
dig AAAA ipv4only.arpa @192.168.1.1
```

Para uma rede de produção, escolha sub-redes sem conflito com a LAN existente. Não use o prefixo `2001:db8` fora de laboratório; para IPv6 nativo, use um prefixo público roteado em vez de simplesmente trocar por uma ULA.

## Arquivos

- `Dockerfile`: imagem Debian 12 e dependências.
- `entrypoint.sh`: configura interfaces, encaminhamento, rotas e NAT; inicia os serviços.
- `dnsmasq.conf`: pools DHCPv4/DHCPv6 e opções de DNS.
- `radvd.conf`: anúncios IPv6 com SLAAC desativado.
- `named.conf.options`: DNS recursivo com DNS64.
- `tayga.conf`: configuração NAT64.

O Dockerfile constrói a imagem Docker. A seção Proxmox reutiliza os arquivos de configuração e o entrypoint em um LXC Debian; a rede e os serviços são geridos pelo próprio Proxmox/systemd.