#!/bin/bash
#
# Install the Keystone invoice sender on a Mac customers print from.
#
#   ./install.sh --token <TOKEN> --server https://your-site [--label "Send to counter"]
#   ./install.sh --check        test the pairing again (writes nothing on the server)
#   ./install.sh --uninstall    remove the menu entry (the pairing is left in place)
#
# What it does:
#   1. writes the pairing to ~/.keystone-invoice-sender/config.json (mode 600) — never into this
#      folder, so updating the sender cannot lose it and a token cannot be committed by accident;
#   2. puts a copy of send-to-counter.sh, with the pairing written into it (mode 700), in
#      ~/Library/PDF Services/<label>, which is what makes <label> appear under PDF ▾ in every
#      app's print dialog, for the account that is signed in. The copy carries the pairing because
#      macOS runs it in the print sandbox, which cannot read config.json;
#   3. checks the pairing with the server (a request that stores nothing and costs nothing).
#
# Designed for a MACHINE STRAIGHT OUT OF THE BOX: bash, curl and plutil ship with macOS.
#   * no Homebrew, no git, no Node
#   * no sudo — it installs for the account that runs it (the shared customer account)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.keystone-invoice-sender"
CONFIG="$CONFIG_DIR/config.json"
SERVICES="$HOME/Library/PDF Services"

TOKEN=""; SERVER=""; LABEL=""; MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --token)     TOKEN="${2:-}"; shift 2 ;;
    --server)    SERVER="${2:-}"; shift 2 ;;
    --label)     LABEL="${2:-}"; shift 2 ;;
    --check)     MODE="check"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

json() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

check() {
  local server token body status
  server="$(json "$CONFIG" server)"
  token="$(json "$CONFIG" token)"
  if [ -z "$server" ] || [ -z "$token" ]; then
    echo "Not paired: $CONFIG has no server or token. Run ./install.sh --token … --server …"
    return 1
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/keystone-invoice-sender.XXXXXX")"
  status="$(printf 'Authorization: Bearer %s\n' "$token" | "${KIS_CURL:-/usr/bin/curl}" -sS --max-time 20 -H @- -o "$body" -w '%{http_code}' \
    "${server%/}/api/collection/received-invoices/intake" || echo "000")"
  case "$status" in
    200) echo "✓ Paired with $server ($(json "$body" tenant))." ;;
    401) echo "✗ $server does not accept this token. Issue a new one (pnpm invoice-sender:token <slug> --rotate) and install again." ;;
    404) echo "✗ $server has no invoice sender: the address is not the site's, the collection centre is off, or no token was issued." ;;
    000) echo "✗ Could not reach $server." ;;
    *)   echo "✗ $server answered HTTP $status." ;;
  esac
  rm -f "$body"
  echo "Sender log: $(sender_log)"
  [ "$status" = "200" ]
}

# Where a send from the print dialog logs: the print agent's own temporary folder, because the
# print sandbox may not write ~/Library/Logs.
sender_log() {
  local t
  t="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  echo "${t%/}/com.apple.printtool.agent/keystone-invoice-sender.log"
}

if [ "$MODE" = "uninstall" ]; then
  label="$(json "$CONFIG" label)"
  if [ -n "$label" ] && [ -e "$SERVICES/$label" ]; then
    rm -f "$SERVICES/$label"
    echo "Removed \"$label\" from the print dialog's PDF menu."
  else
    echo "No menu entry recorded in $CONFIG; nothing removed from $SERVICES."
  fi
  echo "Left in place: $CONFIG (the pairing). Delete it to forget this machine's token."
  exit 0
fi

if [ "$MODE" = "check" ]; then
  check
  exit $?
fi

# --- install ------------------------------------------------------------------
if [ -z "$TOKEN" ] || [ -z "$SERVER" ]; then
  echo "Usage: ./install.sh --token <TOKEN> --server https://your-site [--label \"Send to counter\"]"
  exit 1
fi
case "$TOKEN" in
  kinv_*) ;;
  *) echo "That does not look like an invoice sender token (they start with kinv_)."; exit 1 ;;
esac
SERVER="${SERVER%/}"
case "$SERVER" in
  https://*) ;;
  http://localhost*|http://*.localhost*|http://*.localhost:*) ;;   # a developer's own machine
  *) echo "The server must be an https:// address (got: $SERVER)."; exit 1 ;;
esac
# They are written into a bash script between double quotes: nothing that bash would expand there.
case "$TOKEN$SERVER" in
  *'"'*|*'\'*|*'$'*|*'`'*) echo "The token and server may not contain quotes, backslashes, \$ or backticks."; exit 1 ;;
esac
LABEL="${LABEL:-Send to counter}"
case "$LABEL" in
  */*|*'"'*|*'\'*) echo "The label may not contain /, quotes or backslashes."; exit 1 ;;
esac

# A label changed since the last install: take the old entry out of the menu first.
old_label="$(json "$CONFIG" label)"
if [ -n "$old_label" ] && [ "$old_label" != "$LABEL" ] && [ -e "$SERVICES/$old_label" ]; then
  rm -f "$SERVICES/$old_label"
  echo "Removed the old menu entry \"$old_label\"."
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
umask 077
printf '{\n  "server": "%s",\n  "token": "%s",\n  "label": "%s"\n}\n' "$SERVER" "$TOKEN" "$LABEL" >"$CONFIG"
chmod 600 "$CONFIG"
echo "Pairing written to $CONFIG"

mkdir -p "$SERVICES"
# macOS runs a PDF Service in the print system's sandbox, where the pairing file above cannot be
# read — so the installed copy carries the server and token itself, readable by this account only.
# (The token and server were checked above: no quotes, backslashes, $ or backticks.)
KIS_SERVER="$SERVER" KIS_TOKEN="$TOKEN" /usr/bin/awk '
  /^PAIRED_SERVER=""$/ { print "PAIRED_SERVER=\"" ENVIRON["KIS_SERVER"] "\""; next }
  /^PAIRED_TOKEN=""$/  { print "PAIRED_TOKEN=\"" ENVIRON["KIS_TOKEN"] "\""; next }
  { print }
' "$HERE/send-to-counter.sh" >"$SERVICES/$LABEL"
chmod 700 "$SERVICES/$LABEL"
grep -qF "PAIRED_TOKEN=\"$TOKEN\"" "$SERVICES/$LABEL" || { echo "Could not write the pairing into the menu entry."; exit 1; }
# Downloaded with a browser, the copy would carry the quarantine flag and macOS would refuse it.
/usr/bin/xattr -d com.apple.quarantine "$SERVICES/$LABEL" 2>/dev/null || true
echo "Added \"$LABEL\" to the print dialog's PDF menu."

check || {
  echo
  echo "The menu entry is installed, but sending will fail until the pairing works."
  exit 1
}
echo
echo "Try it: open any page in Safari, File → Print → PDF ▾ → $LABEL."
