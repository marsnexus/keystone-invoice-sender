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
# ⚠️ macOS runs a PDF Service inside the print system's sandbox (com.apple.printtool.agent). There
# it may read the PDF, this file and the network, and write its own temporary folder — but NOT read
# anything else in the home folder (so not ~/.keystone-invoice-sender/config.json) nor write
# ~/Library/Logs. So install.sh writes the pairing INTO the installed copy (the two lines below,
# mode 700), and the log falls back to the print agent's temporary folder.
#
# For the self-test, every tool can be replaced through the environment:
#   KIS_CONFIG, KIS_CURL, KIS_PLUTIL, KIS_OSASCRIPT, KIS_LOG
set -u

# Filled in by install.sh in the installed copy. Empty here, in the downloaded file.
PAIRED_SERVER=""
PAIRED_TOKEN=""

CONFIG="${KIS_CONFIG:-$HOME/.keystone-invoice-sender/config.json}"
CURL="${KIS_CURL:-/usr/bin/curl}"
PLUTIL="${KIS_PLUTIL:-/usr/bin/plutil}"
OSASCRIPT="${KIS_OSASCRIPT:-/usr/bin/osascript}"
LOG="${KIS_LOG:-$HOME/Library/Logs/keystone-invoice-sender.log}"

# The log is chosen ONCE, where it can be written: a redirect to a file that cannot be opened
# makes bash skip the command it is on, so curl's `2>>"$LOG"` would never send at all.
{ mkdir -p "$(dirname "$LOG")" && : >>"$LOG"; } 2>/dev/null || LOG="${TMPDIR:-/tmp}/keystone-invoice-sender.log"
{ : >>"$LOG"; } 2>/dev/null || LOG=/dev/null

PDF="${3:-}"

# Fallback wording, for when the server's own answer cannot be shown.
HAND_TO_STAFF_EN="It could not be sent. Please hand your invoice to the staff."
HAND_TO_STAFF_ZH="发送失败，请把发票交给工作人员。"

log() {
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
SERVER="$PAIRED_SERVER"
TOKEN="$PAIRED_TOKEN"
if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then
  # Not written into this copy (run by hand from the download): the pairing file, where readable.
  [ -r "$CONFIG" ] || fail "not paired: this copy carries no pairing and $CONFIG cannot be read — run install.sh again"
  SERVER="$(json "$CONFIG" server)"
  TOKEN="$(json "$CONFIG" token)"
fi
[ -n "$SERVER" ] && [ -n "$TOKEN" ] || fail "no server or token in the pairing — run install.sh again"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/keystone-invoice-sender.XXXXXX")" || fail "could not make a temporary folder"
trap 'rm -rf "$WORK"' EXIT
BODY="$WORK/answer.json"
# macOS names the PDF after the page's TITLE, and curl's -F reads ";" and "," in a file name as
# its own syntax — a title with either would break the upload. A copy with a plain name cannot.
cp "$PDF" "$WORK/invoice.pdf" || fail "could not copy the PDF"

# The token goes in a header read from stdin, so it never appears in the process list. The
# server answers as soon as it has stored the PDF (it reads it afterwards); 60 s covers a slow line.
STATUS="$(printf 'Authorization: Bearer %s\n' "$TOKEN" | "$CURL" -sS --max-time 60 \
  -H @- \
  -F "file=@${WORK}/invoice.pdf;type=application/pdf" \
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
