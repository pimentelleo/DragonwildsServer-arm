#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./uninstall.sh [options]

Remove the Dragonwilds systemd service and local runtime configuration.

Options:
  --purge           Also remove /opt/dragonwilds
  --delete-world    Required with --purge because it deletes saved worlds
  --yes             Skip the interactive DELETE confirmation for --purge
  -h, --help        Show this help text

Without --purge, game files and saved worlds remain in /opt/dragonwilds.
This script never removes apt packages or host/cloud firewall rules.
EOF
}

purge=0
delete_world=0
assume_yes=0

while (($#)); do
  case "$1" in
    --purge)
      purge=1
      shift
      ;;
    --delete-world)
      delete_world=1
      shift
      ;;
    --yes)
      assume_yes=1
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

systemctl disable --now "$DW_SERVICE_NAME" 2>/dev/null || true
rm -f "$DW_SYSTEMD_UNIT"
systemctl daemon-reload
rm -rf -- "$DW_CONFIG_DIR" "$DW_STATE_DIR"

if (( ! purge )); then
  log "Service removed. Game files and worlds remain in $DW_INSTALL_DIR."
  log 'Use --purge --delete-world only after making a backup.'
  exit 0
fi

(( delete_world )) || die '--purge requires --delete-world because saved worlds are inside the installation directory.'

if (( ! assume_yes )); then
  read -r -p "Type DELETE to permanently remove $DW_INSTALL_DIR and all worlds: " confirmation
  [[ "$confirmation" == DELETE ]] || die 'Purge cancelled.'
fi

safe_remove_installation
log 'Service, runtime files, and worlds were removed.'
