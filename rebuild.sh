#!/bin/bash

docker rm -f system_stat 2>/dev/null || true
docker build -t system_stat:latest .

# Find a running AmneziaWG container (userspace mode). In kernel mode there is no
# container, so this is optional — we just skip mounting its logs below.
CONTAINER_ID=$(docker ps --no-trunc --filter "name=amnezia" --format "{{.ID}}")
if [[ -z "$CONTAINER_ID" ]]; then
  echo "No amnezia container found; it may be running as a kernel module."
fi

# Telegram credentials are taken from the environment, so secrets never live in the repo:
#   BOT_TOKEN=123456:ABC CHAT_ID=987654321 ./rebuild.sh -vi amn0
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "warning: BOT_TOKEN/CHAT_ID are not set - Telegram alerts will not be delivered" >&2
fi

# Base docker arguments that are always required.
ARGS=(
  -d --name system_stat
  --restart unless-stopped
  --pid=host
  --network=host
  --cap-add=NET_ADMIN
  -v /:/host:ro
  -e ROOT_PATH=/host
  -e "BOT_TOKEN=${BOT_TOKEN}"
  -e "CHAT_ID=${CHAT_ID}"
  --log-opt max-size=10m
  --log-opt max-file=3
)

# In userspace mode, expose the amnezia container's logs directory (it holds
# config.v2.json, from which the AWG_* metrics are read) as a read-only volume.
if [[ -n "$CONTAINER_ID" ]]; then
  ARGS+=( -v "/var/lib/docker/containers/${CONTAINER_ID}:/host-docker/amnezia:ro" )
fi

ARGS+=( system_stat:latest )

# Application arguments: use the CLI ones if given, otherwise default to "-vi amn0".
if [[ $# -gt 0 ]]; then
  ARGS+=( "$@" )
else
  ARGS+=( -vi amn0 )
fi

docker run "${ARGS[@]}"

# The container runs detached (-d), so follow its logs with the command below.
echo "Started. Follow the logs with: docker logs -f system_stat"
