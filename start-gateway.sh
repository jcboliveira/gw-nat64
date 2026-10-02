#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONTAINER=gw-nat64
IMAGE=gw-nat64:latest
EXTERNAL_NETWORK=${GW_EXTERNAL_NETWORK:-ext-net}
ACTION=${1:-start}
DOMAIN=${2:-GW}

case "$ACTION" in
	stop)
		docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
		printf 'Gateway stopped.\n'
		exit 0
		;;
	start)
		;;
	*)
		printf 'Usage: %s [start [collision-domain] | stop]\n' "$0" >&2
		exit 2
		;;
esac

if [[ ! "$DOMAIN" =~ ^[[:alnum:]_-]+$ ]]; then
	printf 'Invalid collision domain: %s\n' "$DOMAIN" >&2
	exit 2
fi

if [[ ! -c /dev/net/tun ]]; then
	printf '/dev/net/tun is unavailable on this host.\n' >&2
	exit 1
fi

mapfile -t networks < <(
	docker network ls --format '{{.Name}} {{.Driver}}' |
		awk -v marker="_${DOMAIN}_" '$2 ~ /^kathara\// && index($1, marker) { print $1 }'
)

if [[ ${#networks[@]} -eq 0 ]]; then
	printf 'No running Kathara network found for collision domain %s. Start the lab first.\n' "$DOMAIN" >&2
	exit 1
fi

if [[ ${#networks[@]} -ne 1 ]]; then
	printf 'Found multiple Kathara networks for collision domain %s; stop the other labs first.\n' "$DOMAIN" >&2
	exit 1
fi

docker build -t "$IMAGE" "$SCRIPT_DIR"
if ! docker network inspect "$EXTERNAL_NETWORK" >/dev/null 2>&1; then
	docker network create "$EXTERNAL_NETWORK" >/dev/null
fi

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
	docker rm -f "$CONTAINER" >/dev/null
fi

docker create --name "$CONTAINER" --network "$EXTERNAL_NETWORK" --privileged "$IMAGE" >/dev/null
docker network connect "${networks[0]}" "$CONTAINER"
docker start "$CONTAINER" >/dev/null

if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER") != true ]]; then
	docker logs "$CONTAINER" >&2
	exit 1
fi

printf 'Gateway started on Kathara network %s.\n' "${networks[0]}"
docker exec "$CONTAINER" ip -brief address