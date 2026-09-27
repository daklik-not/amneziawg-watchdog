#!/bin/bash

docker rm -f system_stat 2>/dev/null || true
docker build -t system_stat:latest .

# Ошибки исправлены: флаги --log-opt перенесены ДО имени образа,
# а аргументы приложения (-vi amn0) поставлены в самый конец.
CONTAINER_ID=$(docker ps --no-trunc --filter "name=amnezia" --format "{{.ID}}")
if [[ -z "$CONTAINER_ID" ]]; then
  echo "There is no amnezia container, maybe it started as a kernel module"
fi

# Секреты (BOT_TOKEN/CHAT_ID) читаем из .env рядом со скриптом, а не хардкодим в файле.
# Файл .env НЕ должен коммититься в git — добавьте его в .gitignore.

BOT_TOKEN="8802040267:AAFKujH3J8y_GgQxoYq9PmxIODlqAa_iTKk"
CHAT_ID="1685250687"

# Массив с базовыми аргументами, которые нужны всегда
ARGS=(
  -d --name system_stat
  --pid=host
  --network=host
  --cap-add=NET_ADMIN
  -v /:/host:ro
  -e ROOT_PATH=/host
  -e "BOT_TOKEN=${BOT_TOKEN:-}"
  -e "CHAT_ID=${CHAT_ID:-}"
  --log-opt max-size=10m
  --log-opt max-file=3
)

if ! [ -z "$CONTAINER_ID" ]; then
  ARGS+=( -v "/var/lib/docker/containers/${CONTAINER_ID}:/host-docker/amnezia:ro" )
fi

ARGS+=( system_stat:latest )

if [[ $# -gt 0 ]]; then
  ARGS+=( "$@" )
else
  ARGS+=( -vi amn0 )
fi

docker run "${ARGS[@]}"


echo "done. logs:"
sleep 1
docker logs -f system_stat