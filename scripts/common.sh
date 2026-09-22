#!/usr/bin/env bash

set -Eeuo pipefail

readonly DW_APP_ID=4019830
readonly DW_SERVICE_NAME=dragonwilds.service
readonly DW_SERVER_USER=dragonwilds
readonly DW_SERVER_GROUP=dragonwilds
readonly DW_INSTALL_DIR=/opt/dragonwilds
readonly DW_STATE_DIR=/var/lib/dragonwilds
readonly DW_CONFIG_DIR=/etc/dragonwilds
readonly DW_PASSWORD_FILE="$DW_CONFIG_DIR/world-password"
readonly DW_RUNTIME_CONFIG="$DW_CONFIG_DIR/runtime.conf"
readonly DW_SYSTEMD_UNIT="/etc/systemd/system/$DW_SERVICE_NAME"
readonly DW_TOOLS_DIR="$DW_INSTALL_DIR/tools"
readonly DW_DOWNLOADER="$DW_TOOLS_DIR/DepotDownloader"
readonly DW_BOX64="$DW_INSTALL_DIR/runtime/box64"
readonly DW_SERVER_BINARY="$DW_INSTALL_DIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
readonly DW_CRASHPAD_HANDLER="$DW_INSTALL_DIR/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler"
readonly DW_SERVER_CONFIG="$DW_INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
readonly DW_ENGINE_SAVED_DIR="$DW_INSTALL_DIR/Engine/Saved"
readonly DW_GAME_SAVED_DIR="$DW_INSTALL_DIR/RSDragonwilds/Saved"
readonly DW_SENTRY_DIR="$DW_INSTALL_DIR/RSDragonwilds/.sentry-native"

log() {
  printf '[dragonwilds] %s\n' "$*"
}

warn() {
  printf '[dragonwilds] warning: %s\n' "$*" >&2
}

die() {
  printf '[dragonwilds] error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  (( EUID == 0 )) || die 'Run this command with sudo.'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

validate_owner_id() {
  [[ "$1" =~ ^[0-9]{17}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  local port=$((10#$1))
  (( port >= 1024 && port <= 65535 ))
}

validate_ini_value() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

ensure_arm64_host() {
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "This installer supports ARM64 hosts only; detected $(uname -m)." ;;
  esac

  if [[ "$(getconf PAGESIZE)" != 4096 ]]; then
    warn 'This host does not use 4 KiB memory pages. Box64 compatibility may be reduced.'
  fi
}

ensure_systemd() {
  require_command systemctl
  [[ -d /run/systemd/system ]] || die 'systemd is required to manage the server service.'
}

install_dependencies() {
  local build_box64=$1
  local packages=(ca-certificates curl iproute2 jq openssl unzip)

  if (( build_box64 )); then
    packages+=(build-essential cmake git)
  fi

  require_command apt-get
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${packages[@]}"
}

ensure_service_user() {
  if ! id -u "$DW_SERVER_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --user-group \
      --home-dir "$DW_STATE_DIR" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$DW_SERVER_USER"
  fi

  install -d -o "$DW_SERVER_USER" -g "$DW_SERVER_GROUP" -m 0750 "$DW_STATE_DIR"
}

ensure_mutable_directory() {
  local directory=$1
  install -d -o "$DW_SERVER_USER" -g "$DW_SERVER_GROUP" -m 0750 "$directory"
  chown -R "$DW_SERVER_USER:$DW_SERVER_GROUP" "$directory"
}

prepare_server_permissions() {
  [[ -d "$DW_INSTALL_DIR" ]] || die "Server directory is missing: $DW_INSTALL_DIR"
  [[ -f "$DW_SERVER_BINARY" ]] || die "Server binary is missing: $DW_SERVER_BINARY"

  chown -R root:root "$DW_INSTALL_DIR"
  chmod 0755 "$DW_SERVER_BINARY"

  if [[ -f "$DW_CRASHPAD_HANDLER" ]]; then
    chmod 0755 "$DW_CRASHPAD_HANDLER"
  fi

  ensure_mutable_directory "$DW_ENGINE_SAVED_DIR"
  ensure_mutable_directory "$DW_GAME_SAVED_DIR"
  ensure_mutable_directory "$DW_SENTRY_DIR"
}

generate_server_guid() {
  openssl rand -hex 16 | tr '[:lower:]' '[:upper:]'
}

existing_server_guid() {
  [[ -f "$DW_SERVER_CONFIG" ]] || return 1

  local guid
  guid="$(awk -F= '$1 == "ServerGuid" { print $2; exit }' "$DW_SERVER_CONFIG" 2>/dev/null || true)"
  [[ "$guid" =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
  printf '%s\n' "${guid^^}"
}

has_complete_server_config() {
  [[ -f "$DW_SERVER_CONFIG" ]] && grep -Eq '^OwnerId=[0-9]{17}$' "$DW_SERVER_CONFIG"
}

write_world_password() {
  local password=$1
  local temporary_file

  install -d -m 0750 "$DW_CONFIG_DIR"
  temporary_file="$(mktemp /tmp/dragonwilds-password.XXXXXX)"
  umask 077
  printf '%s\n' "$password" > "$temporary_file"
  install -o root -g root -m 0600 "$temporary_file" "$DW_PASSWORD_FILE"
  rm -f "$temporary_file"
}

write_runtime_config() {
  local port=$1
  local temporary_file

  validate_port "$port" || die "Invalid UDP port: $port"
  install -d -m 0750 "$DW_CONFIG_DIR"
  temporary_file="$(mktemp /tmp/dragonwilds-runtime-config.XXXXXX)"
  umask 077
  printf 'PORT=%s\n' "$port" > "$temporary_file"
  install -o root -g root -m 0640 "$temporary_file" "$DW_RUNTIME_CONFIG"
  rm -f "$temporary_file"
}

configured_port() {
  local port=7777
  local configured

  if [[ -f "$DW_RUNTIME_CONFIG" ]]; then
    configured="$(awk -F= '$1 == "PORT" { print $2; exit }' "$DW_RUNTIME_CONFIG" 2>/dev/null || true)"
    [[ -n "$configured" ]] && port="$configured"
  fi

  validate_port "$port" || die "Invalid port in $DW_RUNTIME_CONFIG: $port"
  printf '%s\n' "$port"
}

write_server_config() {
  local owner_id=$1
  local server_name=$2
  local world_name=$3
  local world_password=$4
  local guid
  local temporary_file

  validate_owner_id "$owner_id" || die 'OwnerId must be a 17-digit SteamID64.'
  validate_ini_value "$server_name" || die 'Server name must not be empty or contain a line break.'
  validate_ini_value "$world_name" || die 'World name must not be empty or contain a line break.'
  validate_ini_value "$world_password" || die 'World password must not be empty or contain a line break.'

  guid="$(existing_server_guid || true)"
  [[ -n "$guid" ]] || guid="$(generate_server_guid)"

  install -d -o "$DW_SERVER_USER" -g "$DW_SERVER_GROUP" -m 0750 "$(dirname "$DW_SERVER_CONFIG")"
  temporary_file="$(mktemp /tmp/dragonwilds-server-config.XXXXXX)"
  umask 077
  cat > "$temporary_file" <<EOF
;METADATA=(Diff=true, UseCommands=true)
[/Script/Dominion.DedicatedServerSettings]
OwnerId=$owner_id
ServerGuid=$guid
ServerName=$server_name
WorldPassword=$world_password
DefaultWorldName=$world_name
PlatformPolicy=Crossplay
bAllowSendingCrashDumps=True
EOF
  install -o "$DW_SERVER_USER" -g "$DW_SERVER_GROUP" -m 0600 "$temporary_file" "$DW_SERVER_CONFIG"
  rm -f "$temporary_file"
  write_world_password "$world_password"
}

install_depotdownloader() {
  if [[ -x "$DW_DOWNLOADER" ]]; then
    return
  fi

  local asset_url
  local archive
  asset_url="$(
    curl -fsSL https://api.github.com/repos/SteamRE/DepotDownloader/releases/latest |
      jq -r '[.assets[] | select(.name | test("linux-arm64"; "i")) | .browser_download_url][0] // empty'
  )"
  [[ -n "$asset_url" ]] || die 'No self-contained Linux ARM64 DepotDownloader release asset was found.'

  install -d -m 0755 "$DW_TOOLS_DIR"
  archive="$(mktemp /tmp/depotdownloader-arm64.XXXXXX.zip)"
  curl -fL --retry 3 --retry-delay 2 "$asset_url" -o "$archive"
  unzip -oq "$archive" -d "$DW_TOOLS_DIR"
  rm -f "$archive"

  [[ -f "$DW_DOWNLOADER" ]] || die 'DepotDownloader archive did not contain the expected executable.'
  chmod 0755 "$DW_DOWNLOADER"
}

download_server() {
  [[ -x "$DW_DOWNLOADER" ]] || die "DepotDownloader is missing: $DW_DOWNLOADER"

  install -d -m 0755 "$DW_INSTALL_DIR"
  "$DW_DOWNLOADER" \
    -app "$DW_APP_ID" \
    -os linux \
    -osarch 64 \
    -dir "$DW_INSTALL_DIR" \
    -max-downloads 8
}

build_box64() {
  local build_directory
  local source_directory

  build_directory="$(mktemp -d /tmp/dragonwilds-box64.XXXXXX)"
  source_directory="$build_directory/source"

  log 'Building Box64 with the ARM dynarec.'
  git clone --depth 1 https://github.com/ptitSeb/box64.git "$source_directory"
  cmake \
    -S "$source_directory" \
    -B "$build_directory/build" \
    -DARM_DYNAREC=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build "$build_directory/build" --parallel "$(nproc)"

  [[ -x "$build_directory/build/box64" ]] || die 'Box64 build did not produce an executable.'
  install -d -m 0755 "$(dirname "$DW_BOX64")"
  install -o root -g root -m 0755 "$build_directory/build/box64" "$DW_BOX64"
  rm -rf -- "$build_directory"
}

render_systemd_unit() {
  local template=$1
  local port=$2
  local temporary_file

  [[ -f "$template" ]] || die "Systemd template is missing: $template"
  validate_port "$port" || die "Invalid UDP port: $port"

  temporary_file="$(mktemp /tmp/dragonwilds-systemd.XXXXXX)"
  sed "s/@PORT@/$port/g" "$template" > "$temporary_file"
  install -o root -g root -m 0644 "$temporary_file" "$DW_SYSTEMD_UNIT"
  rm -f "$temporary_file"
}

service_is_active() {
  systemctl is-active --quiet "$DW_SERVICE_NAME"
}

show_service_failure_logs() {
  journalctl -u "$DW_SERVICE_NAME" -n 120 --no-pager || true
}

wait_for_server_listener() {
  local port=$1
  local timeout_seconds=${2:-180}
  local elapsed

  for ((elapsed = 0; elapsed < timeout_seconds; elapsed++)); do
    if service_is_active &&
      ss -H -lun | awk -v port="$port" '$4 ~ (":" port "$") { found = 1 } END { exit !found }'; then
      return 0
    fi
    sleep 1
  done

  return 1
}

safe_remove_installation() {
  [[ "$DW_INSTALL_DIR" == /opt/dragonwilds ]] || die "Refusing to remove an unexpected path: $DW_INSTALL_DIR"
  [[ -f "$DW_SERVER_BINARY" ]] || die "Refusing to remove a directory without the Dragonwilds server binary."
  rm -rf -- "$DW_INSTALL_DIR"
}
