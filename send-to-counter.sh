#!/bin/bash
#
# Keystone invoice sender — the entry in the macOS print dialog's PDF menu.
#
# macOS runs this when someone chooses it under  File → Print → PDF ▾. It is handed three
# arguments (a "PDF Service"): the document's title, the print options, and the path of the PDF
# macOS just made. It sends that PDF to the counter and says, in a dialog, whether it went.
#
# Installed by ./install.sh into ~/Library/PDF Services/<the menu label>. It needs nothing that
# does not ship with macOS: bash, curl, plutil and osascript.
#
# The pairing (which server, and this machine's token) is ~/.keystone-invoice-sender/config.json,
# written by install.sh — never this file, so updating the sender cannot lose it.
#
# For the self-test, every tool can be replaced through the environment:
#   KIS_CONFIG, KIS_CURL, KIS_PLUTIL, KIS_OSASCRIPT, KIS_LOG
set -u

CONFIG="${KIS_CONFIG:-$HOME/.keystone-invoice-sender/config.json}"
CURL="${KIS_CURL:-/usr/bin/curl}"
PLUTIL="${KIS_PLUTIL:-/usr/bin/plutil}"
OSASCRIPT="${KIS_OSASCRIPT:-/usr/bin/osascript}"
LOG="${KIS_LOG:-$HOME/Library/Logs/keystone-invoice-sender.log}"

PDF="${3:-}"

# Fallback wording, for when the server's own answer cannot be shown.
HAND_TO_STAFF_EN="It could not be sent. Please hand your invoice to the staff."
HAND_TO_STAFF_ZH="发送失败，请把发票交给工作人员。"

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

# One dialog, English then Chinese. It closes by itself after 30 seconds so the next customer
# never finds the last one's message waiting.
say() {
  "$OSASCRIPT" - "$1" "$2" "$3" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set theTitle to item 1 of argv
  set theText to (item 2 of argv) & return & return & (item 3 of argv)
  display dialog theText with title theTitle buttons {"OK"} default button "OK" giving up after 30
end run
APPLESCRIPT
}

fail() {
  log "failed: $*"
  say "Keystone" "$HAND_TO_STAFF_EN" "$HAND_TO_STAFF_ZH"
  exit 1
}

# A value from a JSON file, or nothing.
json() { "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null; }

[ -n "$PDF" ] && [ -f "$PDF" ] || fail "no PDF was handed over (arguments: $*)"
[ -f "$CONFIG" ] || fail "not paired: $CONFIG is missing — run install.sh"

SERVER="$(json "$CONFIG" server)"
TOKEN="$(json "$CONFIG" token)"
[ -n "$SERVER" ] && [ -n "$TOKEN" ] || fail "the pairing in $CONFIG has no server or token"

BODY="$(mktemp "${TMPDIR:-/tmp}/keystone-invoice-sender.XXXXXX")" || fail "could not make a temporary file"
trap 'rm -f "$BODY"' EXIT

# The token goes in a header read from stdin, so it never appears in the process list.
STATUS="$(printf 'Authorization: Bearer %s\n' "$TOKEN" | "$CURL" -sS --max-time 90 \
  -H @- \
  -F "file=@${PDF};type=application/pdf" \
  -o "$BODY" -w '%{http_code}' \
  "${SERVER%/}/api/collection/received-invoices/intake" 2>>"$LOG")"
CODE=$?

if [ "$CODE" -ne 0 ]; then
  fail "could not reach $SERVER (curl exit $CODE)"
fi

EN="$(json "$BODY" message.en)"
ZH="$(json "$BODY" message.zh)"
OUTCOME="$(json "$BODY" outcome)"
log "HTTP $STATUS ${OUTCOME:-no-outcome}"

if [ -z "$EN" ]; then
  # A 404 / 401 / a proxy's error page: the server said nothing a customer can act on.
  fail "HTTP $STATUS with no message"
fi

case "$STATUS" in
  2??) say "Keystone" "$EN" "${ZH:-$EN}"; exit 0 ;;
  *)   say "Keystone" "$EN" "${ZH:-$EN}"; exit 1 ;;
esac
