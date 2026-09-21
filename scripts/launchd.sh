#!/usr/bin/env bash
# Load / unload / status for the macVNC LaunchAgent.
# Usage: ./scripts/launchd.sh {load|unload|status|install|print}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="net.macvnc.server"
PLIST_SRC="${ROOT}/contrib/launchd/${LABEL}.plist"
AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_DST="${AGENT_DIR}/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

# Prefer a built app; fall back to PATH.
DEFAULT_PROG="${ROOT}/build/macVNC.app/Contents/MacOS/macVNC"
if [[ -n "${MACVNC_PROGRAM:-}" ]]; then
  PROGRAM="${MACVNC_PROGRAM}"
elif [[ -x "${DEFAULT_PROG}" ]]; then
  PROGRAM="${DEFAULT_PROG}"
elif command -v macVNC >/dev/null 2>&1; then
  PROGRAM="$(command -v macVNC)"
else
  PROGRAM="${DEFAULT_PROG}"
fi

RFBPORT="${MACVNC_RFBPORT:-5901}"
PASSWD="${MACVNC_PASSWD:-}"
SECURITY="${MACVNC_SECURITY:-vencrypt}"

render_plist() {
  local prog_xml pass_args=""
  prog_xml="${PROGRAM}"
  if [[ -n "${PASSWD}" ]]; then
    pass_args="
    <string>-passwd</string>
    <string>${PASSWD}</string>"
  fi
  sed \
    -e "s|@MACVNC_PROGRAM@|${prog_xml}|g" \
    -e "s|@MACVNC_RFBPORT@|${RFBPORT}|g" \
    -e "s|@MACVNC_SECURITY@|${SECURITY}|g" \
    -e "s|@MACVNC_PASSWD_ARGS@|${pass_args}|g" \
    "${PLIST_SRC}"
}

cmd="${1:-status}"
case "${cmd}" in
  print)
    render_plist
    ;;
  install)
    mkdir -p "${AGENT_DIR}"
    render_plist > "${PLIST_DST}"
    echo "Wrote ${PLIST_DST}"
    echo "Program: ${PROGRAM}"
    ;;
  load)
    mkdir -p "${AGENT_DIR}"
    render_plist > "${PLIST_DST}"
    if [[ ! -x "${PROGRAM}" ]]; then
      echo "macVNC binary not found at ${PROGRAM}" >&2
      echo "Build first, or set MACVNC_PROGRAM=/path/to/macVNC" >&2
      exit 1
    fi
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "${DOMAIN}" "${PLIST_DST}"
    launchctl enable "${DOMAIN}/${LABEL}" || true
    launchctl kickstart -k "${DOMAIN}/${LABEL}"
    echo "Loaded ${LABEL} (port ${RFBPORT}, security ${SECURITY})"
    ;;
  unload)
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || \
      launchctl unload "${PLIST_DST}" 2>/dev/null || true
    echo "Unloaded ${LABEL}"
    ;;
  status)
    launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null || \
      echo "${LABEL} is not loaded"
    ;;
  *)
    echo "Usage: $0 {load|unload|status|install|print}" >&2
    echo "Env: MACVNC_PROGRAM MACVNC_RFBPORT MACVNC_PASSWD MACVNC_SECURITY" >&2
    exit 2
    ;;
esac
