#!/usr/bin/env bash
# P3 checks that need a whole machine: reboot, hard power-off, sleep. Runs on
# the HOST and drives a disposable Tart macOS VM through `tart exec`. Nothing
# here touches the host's /etc/hosts or launchd.
#
#   script/p3/vm-check.sh <base-image> <results.md>
#
# Example base image: ghcr.io/cirruslabs/macos-tahoe-vanilla:latest (pulled
# first). The VM is a fresh clone named mastbound-p3; it is deleted at the
# end unless KEEP_VM=1. The full real-system checklist also runs inside it.
set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-image> <results.md>" >&2
  exit 2
fi
BASE="$1"
RESULTS="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TART="${TART:-tart}"
VM="mastbound-p3"
SHARE="$(mktemp -d)"
GUEST_SHARE="/Volumes/My Shared Files/p3"
RUN_PID=""
FAILS=0

record() { # record <id> <check> <PASS|FAIL|NOTE> <detail>
  local detail="${4//|/\\|}"
  detail="${detail//$'\n'/ }"
  echo "| $1 | $2 | $3 | ${detail:0:300} |" >> "$RESULTS"
  echo "[$3] $1 $2 — ${detail:0:300}"
  [[ "$3" == "FAIL" ]] && FAILS=$((FAILS + 1))
  return 0
}
g() { "$TART" exec "$VM" /bin/bash -c "$1"; } # run a command in the guest
boot() {
  "$TART" run --no-graphics --dir="p3:$SHARE" "$VM" >/dev/null 2>&1 &
  RUN_PID=$!
  local i
  for i in $(seq 1 120); do
    if g "test -d '$GUEST_SHARE'" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}
power_cut() { kill -9 "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null; sleep 3; }
ICTL=/Library/PrivilegedHelperTools/Mastbound/mastboundctl
field() { g "sudo /usr/bin/plutil -extract $1 raw -o - '/Library/Application Support/Mastbound/state.json'" 2>/dev/null; }
phase() { g "$ICTL status" 2>/dev/null | awk -F': ' '/^phase:/ {print $2}'; }
has_section() { g "grep -qF '# BEGIN MASTBOUND — MANAGED BLOCK' /etc/hosts"; }
daemon_running() { g "sudo launchctl print system/com.josiahwilson.mastbound | grep -q 'state = running'"; }
boot_uuid() { g "sysctl -n kern.bootsessionuuid"; }
wait_for() { local s="$1"; shift; local i; for i in $(seq 1 "$s"); do "$@" && return 0; sleep 1; done; return 1; }
cleanup() {
  [[ -n "$RUN_PID" ]] && kill "$RUN_PID" 2>/dev/null
  if [[ "${KEEP_VM:-}" != "1" ]]; then "$TART" delete "$VM" >/dev/null 2>&1; fi
  rm -rf "$SHARE"
}
trap cleanup EXIT

{
  echo "| # | Check | Result | Detail |"
  echo "| --- | --- | --- | --- |"
} > "$RESULTS"

"$ROOT/script/build-cli.sh" --testing "$SHARE/build" >/dev/null || exit 1
"$ROOT/script/build-cli.sh" --testing --upgrade-mark "$SHARE/upgrade" >/dev/null || exit 1
cp "$ROOT/script/p3/real-system-check.sh" "$SHARE/"

"$TART" delete "$VM" >/dev/null 2>&1
"$TART" clone "$BASE" "$VM" || exit 1
boot || { record V0 "VM boots and tart exec works" FAIL "no guest agent answer"; exit 1; }
record V0 "VM boots and tart exec works" PASS "$(g 'sw_vers -productVersion; uname -m' | tr '\n' ' ')"
g "sudo -n true" >/dev/null 2>&1 || { record V0a "passwordless sudo in the guest" FAIL ""; exit 1; }

# --- Full checklist inside the VM (ends with uninstall) --------------------
g "mkdir -p /tmp/p3 && cp -R '$GUEST_SHARE/build' '$GUEST_SHARE/upgrade' '$GUEST_SHARE/real-system-check.sh' /tmp/p3/"
if g "MASTBOUND_DISPOSABLE_MACHINE=1 /tmp/p3/real-system-check.sh /tmp/p3/build /tmp/p3/upgrade /tmp/p3/results.md" > "$SHARE/checklist.log" 2>&1; then
  record V1 "real-system checklist in the VM" PASS "$(tail -1 "$SHARE/checklist.log")"
else
  record V1 "real-system checklist in the VM" FAIL "$(grep '^\[FAIL\]' "$SHARE/checklist.log" | head -5)"
fi
g "cat /tmp/p3/results.md" > "${RESULTS%.md}-checklist.md" 2>/dev/null

# --- Start a commitment for the machine checks ------------------------------
g "sudo rm -rf /usr/local/mastbound-vm && sudo mkdir -p /usr/local/mastbound-vm && sudo cp -R /tmp/p3/build /usr/local/mastbound-vm/ && sudo chown -R root:wheel /usr/local/mastbound-vm && sudo chmod -R go-w /usr/local/mastbound-vm"
if g "sudo /usr/local/mastbound-vm/build/mastboundctl start --minutes 60" >/dev/null 2>&1 && wait_for 30 daemon_running; then
  record R0 "start a 60-minute commitment" PASS "$(phase)"
else
  record R0 "start a 60-minute commitment" FAIL "$(phase)"; exit 1
fi
sleep 70 # past one state save (every 60 s)

# --- Reboot -----------------------------------------------------------------
UUID_BEFORE="$(boot_uuid)"
CREDIT_BEFORE="$(field commitment.creditedSeconds)"
T0=$(date +%s)
g "sudo shutdown -r now" >/dev/null 2>&1
sleep 20
for i in $(seq 1 120); do [[ "$(boot_uuid 2>/dev/null)" != "$UUID_BEFORE" && -n "$(boot_uuid 2>/dev/null)" ]] && break; sleep 2; done
UUID_AFTER="$(boot_uuid)"
record R1 "guest rebooted (new boot session)" "$([[ -n "$UUID_AFTER" && "$UUID_AFTER" != "$UUID_BEFORE" ]] && echo PASS || echo FAIL)" "${UUID_BEFORE:0:8} -> ${UUID_AFTER:0:8}"
if wait_for 60 daemon_running; then record R2 "daemon running after reboot (RunAtLoad)" PASS ""; else record R2 "daemon running after reboot (RunAtLoad)" FAIL ""; fi
if has_section; then record R3 "block in /etc/hosts after reboot" PASS ""; else record R3 "block in /etc/hosts after reboot" FAIL ""; fi
record R4 "phase after reboot" "$([[ "$(phase)" == active ]] && echo PASS || echo FAIL)" "$(phase)"
sleep 70
ELAPSED=$(( $(date +%s) - T0 ))
CREDIT_AFTER="$(field commitment.creditedSeconds)"
GAIN="$(awk -v a="$CREDIT_BEFORE" -v b="$CREDIT_AFTER" 'BEGIN { printf "%d", b - a }')"
# Credit should cover the time off. Allow up to one save interval missing at
# each end, and never more than the wall time that passed.
if (( GAIN >= ELAPSED - 130 && GAIN <= ELAPSED + 5 )); then R5=PASS; else R5=FAIL; fi
record R5 "time across the reboot is credited" "$R5" "credit +${GAIN} s over ${ELAPSED} s wall"

# --- Hard power-off during writes -------------------------------------------
# Force a repair (a full /etc/hosts write) and a state save, then cut power
# a moment later. Repeat a few times at different delays.
for delay in 0.2 0.5 1 2; do
  g "sudo sed -i '' '/# BEGIN MASTBOUND/,/# END MASTBOUND/{/^0\.0\.0\.0/d;}' /etc/hosts" >/dev/null 2>&1
  sleep "$delay"
  power_cut
  boot || { record "P$delay" "boot after power cut (${delay} s)" FAIL "VM did not come back"; continue; }
  wait_for 60 daemon_running
  sleep 8
  STATUS="$(g "$ICTL status" 2>&1 | tr '\n' ';')"
  VALID="$(g "sudo /usr/bin/plutil -lint '/Library/Application Support/Mastbound/state.json'" 2>&1)"
  LINES="$(g "awk '/# BEGIN MASTBOUND/{f=1;next}/# END MASTBOUND/{f=0}f' /etc/hosts | grep -c ." 2>/dev/null)"
  EXPECTED=$(( $(wc -l < "$SHARE/build/adult-domains.txt") * 2 ))
  if [[ "$VALID" == *OK* && "$STATUS" == *"phase: active"* && "$LINES" == "$EXPECTED" ]]; then
    record "P$delay" "power cut ${delay} s into a repair: state valid, block complete" PASS "$LINES lines"
  else
    record "P$delay" "power cut ${delay} s into a repair: state valid, block complete" FAIL "lint: $VALID; $STATUS; $LINES of $EXPECTED lines"
  fi
done

# --- Sleep ------------------------------------------------------------------
CREDIT_BEFORE="$(field commitment.creditedSeconds)"
SLEEP_OUT="$(g "sudo pmset sleepnow" 2>&1)"
sleep 90
g "true" >/dev/null 2>&1
record S1 "sleep request in the VM" NOTE "$SLEEP_OUT; a VM may not really sleep, so this does not prove sleep is counted"
sleep 65
record S2 "commitment still active after the sleep request" "$([[ "$(phase)" == active ]] && has_section && echo PASS || echo FAIL)" "credit $CREDIT_BEFORE -> $(field commitment.creditedSeconds)"

# --- Clean up inside the VM: end by recovery is too slow; leave it ----------
echo
echo "Failures: $FAILS"
echo "" >> "$RESULTS"
echo "Failures: $FAILS" >> "$RESULTS"
exit $(( FAILS > 0 ))
