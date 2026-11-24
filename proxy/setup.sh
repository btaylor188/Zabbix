#!/usr/bin/env bash
# Zabbix proxy setup: prompts for client, writes .env, generates PSK, sets perms.
# Re-runnable. Usage: ./setup.sh   (or non-interactive: CLIENT=acme ./setup.sh)
set -euo pipefail
cd "$(dirname "$0")"

ZBX_UID=1997                                   # zabbix user in official images
DEFAULT_SERVER=""                              # e.g. monitoring.example.com:10051

slugify() {  # lowercase, non-alnum -> '-', trim/collapse dashes
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

ask() {  # ask "Prompt" default -> echoes answer
  local prompt=$1 def=${2:-} ans
  if [[ -n $def ]]; then read -rp "$prompt [$def]: " ans; else read -rp "$prompt: " ans; fi
  echo "${ans:-$def}"
}

# --- Existing config? ---
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
  echo "Existing .env: proxy=$ZBX_PROXY_NAME server=$ZBX_SERVER_HOST"
  [[ $(ask "Reconfigure? (y/N)" n) =~ ^[Yy]$ ]] || RECONF=0
fi

if [[ ${RECONF:-1} -eq 1 ]]; then
  CLIENT=$(slugify "${CLIENT:-$(ask "Client name (e.g. Acme Dental)")}")
  [[ -n $CLIENT ]] || { echo "Client name required." >&2; exit 1; }
  SERVER=${SERVER:-$(ask "Zabbix server[:port] (e.g. monitoring.example.com:10051)" "${ZBX_SERVER_HOST:-$DEFAULT_SERVER}")}
  [[ -n $SERVER ]] || { echo "Server required." >&2; exit 1; }

  ZBX_PROXY_NAME="px-${CLIENT}"
  ZBX_PSK_IDENTITY="PSK-${ZBX_PROXY_NAME}"
  ZBX_SERVER_HOST=$SERVER

  if (( ${#ZBX_PROXY_NAME} > 128 )); then echo "Proxy name too long (max 128)." >&2; exit 1; fi

  echo
  echo "  Proxy name:   $ZBX_PROXY_NAME"
  echo "  PSK identity: $ZBX_PSK_IDENTITY"
  echo "  Server:       $ZBX_SERVER_HOST"
  [[ $(ask "Write .env? (Y/n)" y) =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

  printf 'ZBX_PROXY_NAME=%s\nZBX_SERVER_HOST=%s\nZBX_PSK_IDENTITY=%s\n' \
    "$ZBX_PROXY_NAME" "$ZBX_SERVER_HOST" "$ZBX_PSK_IDENTITY" > .env
  chmod 600 .env
  echo "Wrote .env"
fi

# --- Dirs + PSK (enc/ is owned by the container user, so test/read with sudo) ---
mkdir -p enc db_data mibs
if sudo test -s enc/proxy.psk; then
  echo "enc/proxy.psk exists - keeping it."
else
  openssl rand -hex 32 | sudo tee enc/proxy.psk >/dev/null
  echo "Generated new PSK."
fi

sudo chown -R "$ZBX_UID:$ZBX_UID" enc db_data
sudo chmod 700 enc
sudo chmod 400 enc/proxy.psk

cat <<MSG

Frontend: Administration > Proxies > Create proxy
  Proxy name:    $ZBX_PROXY_NAME
  Proxy mode:    Active
  Encryption:    Connections from proxy = PSK (uncheck "No encryption")
  PSK identity:  $ZBX_PSK_IDENTITY
  PSK:           $(sudo cat enc/proxy.psk)

Then: sudo docker compose up -d && sudo docker compose logs -f
MSG
