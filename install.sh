#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

Install or update a RuneScape: Dragonwilds dedicated server on ARM64 Linux.

Options:
  --owner-id STEAMID64       17-digit SteamID64 that owns the server world
  --server-name NAME        Display name for a newly configured server
  --world-name NAME         World name for a newly configured server
  --world-password-file FILE
                             Read the private world password from FILE
  --port PORT                UDP listening port (default: 7777)
  --rebuild-box64           Build a fresh Box64 runtime even when one exists
  --non-interactive         Require supplied options instead of prompting
  -h, --help                Show this help text

Existing DedicatedServer.ini files are preserved. Edit the game configuration
while the service is stopped when changing an existing world.
EOF
}

read_with_default() {
  local variable_name=$1
  local prompt=$2
  local default_value=$3
  local value

  read -r -p "$prompt [$default_value]: " value
  printf -v "$variable_name" '%s' "${value:-$default_value}"
}

read_owner_id() {
  local value

  while :; do
    read -r -p 'Owner SteamID64 (17 digits): ' value
    if validate_owner_id "$value"; then
      printf '%s\n' "$value"
      return
    fi
    warn 'Enter a 17-digit SteamID64.'
  done
}

owner_id=''
server_name=''
world_name=''
world_password_file=''
port=7777
non_interactive=0
rebuild_box64=0

while (($#)); do
  case "$1" in
    --owner-id)
      (($# >= 2)) || die '--owner-id requires a value.'
      owner_id=$2
      shift 2
      ;;
    --server-name)
      (($# >= 2)) || die '--server-name requires a value.'
      server_name=$2
      shift 2
      ;;
    --world-name)
      (($# >= 2)) || die '--world-name requires a value.'
      world_name=$2
      shift 2
      ;;
    --world-password-file)
      (($# >= 2)) || die '--world-password-file requires a value.'
      world_password_file=$2
      shift 2
      ;;
    --port)
      (($# >= 2)) || die '--port requires a value.'
      port=$2
      shift 2
      ;;
    --rebuild-box64)
      rebuild_box64=1
      shift
      ;;
    --non-interactive)
      non_interactive=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_root
ensure_arm64_host
ensure_systemd
validate_port "$port" || die "Invalid UDP port: $port"

if has_complete_server_config; then
  if [[ -n "$owner_id$server_name$world_name$world_password_file" ]]; then
    die 'An existing server configuration is preserved. Stop the service and edit DedicatedServer.ini to reconfigure it.'
  fi
  log 'Existing server configuration detected; preserving world settings.'
else
  if [[ -z "$owner_id" ]]; then
    (( non_interactive )) && die '--owner-id is required for a new non-interactive installation.'
    owner_id="$(read_owner_id)"
  fi
  validate_owner_id "$owner_id" || die 'OwnerId must be a 17-digit SteamID64.'

  if [[ -z "$server_name" ]]; then
    if (( non_interactive )); then
      server_name='Dragonwilds Server'
    else
      read_with_default server_name 'Server name' 'Dragonwilds Server'
    fi
  fi
  validate_ini_value "$server_name" || die 'Invalid server name.'

  if [[ -z "$world_name" ]]; then
    if (( non_interactive )); then
      world_name='Dragonwilds'
    else
      read_with_default world_name 'World name' 'Dragonwilds'
    fi
  fi
  validate_ini_value "$world_name" || die 'Invalid world name.'
fi

needs_box64=0
if (( rebuild_box64 )) || [[ ! -x "$DW_BOX64" ]]; then
  needs_box64=1
fi
install_dependencies "$needs_box64"
ensure_service_user
install_depotdownloader
download_server

if (( needs_box64 )); then
  build_box64
fi

prepare_server_permissions

if ! has_complete_server_config; then
  world_password=''
  if [[ -n "$world_password_file" ]]; then
    [[ -r "$world_password_file" ]] || die "Cannot read world password file: $world_password_file"
    world_password="$(<"$world_password_file")"
  elif (( ! non_interactive )); then
    read -r -s -p 'World password (leave blank to generate one): ' world_password
    printf '\n'
  fi

  if [[ -z "$world_password" ]]; then
    world_password="$(openssl rand -hex 16)"
  fi
  validate_ini_value "$world_password" || die 'World password must not be empty or contain a line break.'
  write_server_config "$owner_id" "$server_name" "$world_name" "$world_password"
  unset world_password
fi

render_systemd_unit "$SCRIPT_DIR/templates/dragonwilds.service.in" "$port"
write_runtime_config "$port"
systemctl daemon-reload
systemctl enable "$DW_SERVICE_NAME"

if service_is_active; then
  systemctl restart "$DW_SERVICE_NAME"
else
  systemctl start "$DW_SERVICE_NAME"
fi

if ! wait_for_server_listener "$port"; then
  systemctl stop "$DW_SERVICE_NAME" || true
  show_service_failure_logs
  die "The service did not open UDP port $port within 180 seconds."
fi

log "Server is running and listening on UDP $port."
log "The private world password is stored at $DW_PASSWORD_FILE."
log 'Open the same UDP port in the host and cloud firewalls before inviting players.'
