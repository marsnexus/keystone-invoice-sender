#!/bin/bash
#
# Runs send-to-counter.sh against a stubbed curl and osascript, once per answer the server can
# give, and checks what the customer would be shown. Needs macOS (plutil reads the JSON).
#
#   bash test/selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kis-selftest.XXXXXX")" || { echo "cannot make a temporary folder"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

[ -x /usr/bin/plutil ] || { echo "SKIP: plutil not found (run this on a Mac)"; exit 0; }

# --- stubs --------------------------------------------------------------------
cat >"$WORK/curl" <<'STUB'
#!/bin/bash
# Records the request; writes $STUB_BODY to the -o file; prints $STUB_STATUS for -w.
out=""; url=""
headers="$(cat)"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|-F|--max-time) [ "$1" = "-F" ] && echo "F $2" >>"$STUB_LOG"; shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "URL $url" >>"$STUB_LOG"
echo "HEADERS $headers" >>"$STUB_LOG"
[ "${STUB_EXIT:-0}" = "0" ] || exit "$STUB_EXIT"
printf '%s' "$STUB_BODY" >"$out"
printf '%s' "$STUB_STATUS"
STUB
cat >"$WORK/osascript" <<'STUB'
#!/bin/bash
cat >/dev/null
shift   # the "-" that reads the script from stdin
printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$STUB_SAID"
STUB
chmod +x "$WORK/curl" "$WORK/osascript"

printf '%%PDF-1.3 test\n' >"$WORK/invoice.pdf"
printf '{"server":"https://centre.example.com/","token":"kinv_test","label":"Send to counter"}\n' >"$WORK/config.json"

export KIS_CONFIG="$WORK/config.json" KIS_CURL="$WORK/curl" KIS_OSASCRIPT="$WORK/osascript" KIS_LOG="$WORK/sender.log"
export STUB_LOG="$WORK/curl.log" STUB_SAID="$WORK/said.log"

PASS=0; FAILS=0
run() { # name status body expect-exit expect-text [curl-exit]
  : >"$STUB_LOG"; : >"$STUB_SAID"
  STUB_STATUS="$2" STUB_BODY="$3" STUB_EXIT="${6:-0}" bash "$HERE/send-to-counter.sh" "Atomy Invoice" "" "$WORK/invoice.pdf"
  local code=$?
  if [ "$code" = "$4" ] && grep -qF -- "$5" "$STUB_SAID"; then
    PASS=$((PASS + 1)); echo "PASS $1"
  else
    FAILS=$((FAILS + 1)); echo "FAIL $1 (exit $code, shown: $(cat "$STUB_SAID"))"
  fi
}

run "sent"            200 '{"outcome":"new","message":{"en":"Sent. Please go to the counter.","zh":"已发送，请到柜台。"}}' 0 "Sent. Please go to the counter.|已发送，请到柜台。"
run "already sent"    200 '{"outcome":"already-sent","message":{"en":"Already sent. Please go to the counter.","zh":"已发送过，请到柜台。"}}' 0 "Already sent"
run "already order"   200 '{"outcome":"already-order","message":{"en":"This invoice is already an order at the counter.","zh":"这张发票已在柜台建单。"}}' 0 "already an order"
run "too many"        429 '{"outcome":"too-many","message":{"en":"Too many invoices were sent just now. Please hand your invoice to the staff.","zh":"刚才发送的发票太多，请把发票交给工作人员。"}}' 1 "Too many"
run "wrong token"     401 '{"error":"x","code":"auth","message":{"en":"It could not be sent. Please hand your invoice to the staff.","zh":"发送失败，请把发票交给工作人员。"}}' 1 "hand your invoice to the staff"
run "no sender (404)" 404 '{"error":"Not found."}' 1 "hand your invoice to the staff"
run "unreachable"     000 '' 1 "hand your invoice to the staff" 7

# The request itself: the right address, the PDF attached, the token only in the header.
: >"$STUB_LOG"
STUB_STATUS=200 STUB_BODY='{"message":{"en":"ok","zh":"ok"}}' bash "$HERE/send-to-counter.sh" "t" "" "$WORK/invoice.pdf"
if grep -qF "URL https://centre.example.com/api/collection/received-invoices/intake" "$STUB_LOG" &&
   grep -qF "F file=@$WORK/invoice.pdf;type=application/pdf" "$STUB_LOG" &&
   grep -qF "HEADERS Authorization: Bearer kinv_test" "$STUB_LOG"; then
  PASS=$((PASS + 1)); echo "PASS request shape"
else
  FAILS=$((FAILS + 1)); echo "FAIL request shape: $(cat "$STUB_LOG")"
fi
if grep -qF "kinv_test" "$KIS_LOG"; then
  FAILS=$((FAILS + 1)); echo "FAIL the token reached the log"
else
  PASS=$((PASS + 1)); echo "PASS the token is never logged"
fi

# Not paired, and no PDF handed over: the customer is told to go to the staff.
: >"$STUB_SAID"
KIS_CONFIG="$WORK/missing.json" bash "$HERE/send-to-counter.sh" "t" "" "$WORK/invoice.pdf"
if [ $? = 1 ] && grep -qF "hand your invoice to the staff" "$STUB_SAID"; then PASS=$((PASS + 1)); echo "PASS not paired"; else FAILS=$((FAILS + 1)); echo "FAIL not paired"; fi
: >"$STUB_SAID"
bash "$HERE/send-to-counter.sh" "t" "" "$WORK/nothing.pdf"
if [ $? = 1 ] && grep -qF "hand your invoice to the staff" "$STUB_SAID"; then PASS=$((PASS + 1)); echo "PASS no PDF"; else FAILS=$((FAILS + 1)); echo "FAIL no PDF"; fi

bash -n "$HERE/send-to-counter.sh" && bash -n "$HERE/install.sh" && { PASS=$((PASS + 1)); echo "PASS syntax"; } || { FAILS=$((FAILS + 1)); echo "FAIL syntax"; }

echo
echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
