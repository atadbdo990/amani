#!/bin/bash
# AMANI-MORA — bare-metal/VPS entrypoint (used when NOT running inside the
# Docker image, e.g. on a VPS where xray is already installed on PATH).
set -eu

PROTO=${PROTO:-vless}
USER_ID=${USER_ID:-changeme}
WS_PATH=${WS_PATH:-/ws}
NETWORK=${NETWORK:-ws}
HOST=${HOST:-localhost}
SPEED_LIMIT=${SPEED_LIMIT:-0}

# ensure WS_PATH begins with /
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac

# ensure target directory exists
mkdir -p /etc/xray

if [ ! -f /config.json.tpl ]; then
  echo "❌ config.json.tpl not found" >&2
  exit 1
fi

# Generate config from template
sed -e "s|__PROTO__|${PROTO}|g" \
    -e "s|__USER_ID__|${USER_ID}|g" \
    -e "s|__WS_PATH__|${WS_PATH}|g" \
    -e "s|__NETWORK__|${NETWORK}|g" \
    -e "s|__HOST__|${HOST}|g" \
    -e "s|__PORT__|${PORT:-8080}|g" \
    -e "s|__SPEED_LIMIT__|${SPEED_LIMIT}|g" \
    /config.json.tpl > /etc/xray/config.json

# Start xray
exec xray run -config /etc/xray/config.json
