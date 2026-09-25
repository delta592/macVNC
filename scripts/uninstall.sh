#!/usr/bin/env bash
# Uninstall macVNC installed by the distribution .pkg.
#
# Removes:
#   - LaunchAgent net.macvnc.server (if loaded / present)
#   - /Applications/macVNC.app (override with MACVNC_APP)
#   - installer package receipt (pkgutil --forget)
#
# Does NOT remove ~/.macvnc (certs/keys). Delete that directory yourself if desired.
#
# Usage:
#   ./Uninstall\ macVNC.command
#   sudo ./scripts/uninstall.sh
set -euo pipefail

APP="${MACVNC_APP:-/Applications/macVNC.app}"
PKG_ID="${MACVNC_PKG_ID:-net.macvnc.app}"
LABEL="net.macvnc.server"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "macVNC uninstall"
echo "  app:    ${APP}"
echo "  pkg id: ${PKG_ID}"
echo

# Stop a background agent first so the .app is not busy.
if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  echo "Unloading LaunchAgent ${LABEL}…"
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || \
    launchctl unload "${AGENT_PLIST}" 2>/dev/null || true
fi
if [[ -f "${AGENT_PLIST}" ]]; then
  echo "Removing ${AGENT_PLIST}"
  rm -f "${AGENT_PLIST}"
fi

remove_app() {
  if [[ ! -e "${APP}" ]]; then
    echo "App not found at ${APP} (already removed?)"
    return 0
  fi
  echo "Removing ${APP}"
  if [[ -w "$(dirname "${APP}")" ]] || [[ -w "${APP}" ]]; then
    rm -rf "${APP}"
  else
    echo "Need administrator privileges to remove ${APP}"
    sudo rm -rf "${APP}"
  fi
}

forget_pkg() {
  if pkgutil --pkg-info "${PKG_ID}" >/dev/null 2>&1; then
    echo "Forgetting package receipt ${PKG_ID}"
    if [[ "$(id -u)" -eq 0 ]]; then
      pkgutil --forget "${PKG_ID}" >/dev/null
    else
      sudo pkgutil --forget "${PKG_ID}" >/dev/null
    fi
  else
    echo "No package receipt for ${PKG_ID}"
  fi
}

remove_app
forget_pkg

echo
if [[ -d "${HOME}/.macvnc" ]]; then
  echo "Left ${HOME}/.macvnc in place (certificates/keys)."
  echo "Remove it manually if you want a clean slate:  rm -rf ~/.macvnc"
fi
echo "Done."

# Keep the Terminal window open when launched via double-click (.command).
if [[ "${0}" == *.command ]] || [[ -t 0 && -t 1 ]]; then
  if [[ "${KEEP_OPEN:-1}" == "1" && "${0}" == *.command ]]; then
    echo
    read -r -p "Press Return to close…" _
  fi
fi
