#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/common.sh"

require_root
if [[ ! -x "$DW_DOWNLOADER" ]]; then
  warn 'DepotDownloader is missing; restoring the private ARM64 downloader.'
  install_depotdownloader
fi
[[ -x "$DW_DOWNLOADER" ]] || die "DepotDownloader could not be restored: $DW_DOWNLOADER"
[[ -x "$DW_BOX64" ]] || die "Box64 is missing. Re-run $SCRIPT_DIR/install.sh --rebuild-box64."
port="$(configured_port)"

was_active=0
if service_is_active; then
  was_active=1
  log 'Stopping the server before updating.'
  systemctl stop "$DW_SERVICE_NAME"
fi

if ! download_server; then
  warn 'Game update failed.'
  if (( was_active )); then
    systemctl start "$DW_SERVICE_NAME" || warn 'The previous server could not be restarted automatically.'
  fi
  exit 1
fi

prepare_server_permissions

if (( was_active )); then
  systemctl start "$DW_SERVICE_NAME"
  if ! wait_for_server_listener "$port"; then
    show_service_failure_logs
    die "The updated service did not reopen UDP port $port."
  fi
fi

log 'Server files are up to date.'
