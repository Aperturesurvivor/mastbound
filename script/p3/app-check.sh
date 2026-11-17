#!/usr/bin/env bash
# Checks the commands the app runs for an early end, on a real macOS install
# in a disposable Tart VM. Runs on the HOST over SSH, like vm-check.sh.
# Nothing here touches the host's /etc/hosts or launchd.
#
#   script/p3/app-check.sh <base-vm> <results.md>
#
# Uses a test build (1-minute flow minimum, 2-minute recovery delay). At the
# end it copies the test app to /Applications in the VM and keeps the VM
# running with a window, so a person can try the password dialogs.
set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-vm> <results.md>" >&2
  exit 2
fi
BASE="$1"
RESULTS="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TART="${TART:-tart}"
VM="mastbound-app"
KEY="${KEY:-$HOME/.ssh/mastbound_vm}"
SHARE="$(mktemp -d)"
FAILS=0
trap 'rm -rf "$SHARE"' EXIT

record() { # record <id> <check> <PASS|FAIL|NOTE> <detail>
  local detail="${4//|/\\|}"
  detail="${detail//$'\n'/ }"
  echo "| $1 | $2 | $3 | ${detail:0:300} |" >> "$RESULTS"
  echo "[$3] $1 $2 — ${detail:0:300}"
  [[ "$3" == "FAIL" ]] && FAILS=$((FAILS + 1))
  return 0
}
g() { # run a command in the guest as admin
  local ip; ip="$("$TART" ip "$VM" 2>/dev/null)" || return 255
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$ip" "/bin/bash -c $(printf '%q' "$1")"
}
CTL=/usr/local/mastbound-vm/build/mastboundctl
ICTL=/Library/PrivilegedHelperTools/Mastbound/mastboundctl
PHRASE="I want to end my commitment early"
status() { g "$ICTL status" 2>/dev/null; }
phase() { status | awk -F': ' '/^phase:/ {print $2}'; }
flow_open() { status | grep -q '^early-end flow open for:'; }
has_section() { g "grep -qF '# BEGIN MASTBOUND — MANAGED BLOCK' /etc/hosts"; }
wait_for() { local s="$1"; shift; local i; for i in $(seq 1 "$s"); do "$@" && return 0; sleep 1; done; return 1; }
not() { ! "$@"; }
phase_is() { [[ "$(phase)" == "$1" ]]; }
# check <id> <name> <command...>: PASS if the command succeeds.
check() { local id="$1" name="$2"; shift 2; local out; if out="$("$@" 2>&1)"; then record "$id" "$name" PASS "$out"; else record "$id" "$name" FAIL "$out"; fi; }
# refused <id> <name> <text> <command...>: PASS if it fails and prints text.
refused() { local id="$1" name="$2" text="$3"; shift 3; local out; if out="$("$@" 2>&1)"; then record "$id" "$name" FAIL "was not refused: $out"; elif grep -qiF "$text" <<<"$out"; then record "$id" "$name" PASS "$out"; else record "$id" "$name" FAIL "$out"; fi; }

{
  echo "| # | Check | Result | Detail |"
  echo "| --- | --- | --- | --- |"
} > "$RESULTS"

"$ROOT/script/build-cli.sh" --testing "$SHARE/build" >/dev/null || exit 1
"$ROOT/script/build-app.sh" --testing >/dev/null || exit 1
ditto "$ROOT/dist/Mastbound.app" "$SHARE/Mastbound.app"

"$TART" stop "$VM" >/dev/null 2>&1
"$TART" delete "$VM" >/dev/null 2>&1
"$TART" clone "$BASE" "$VM" || exit 1
"$TART" run "$VM" >/dev/null 2>&1 &
for i in $(seq 1 120); do g true >/dev/null 2>&1 && break; sleep 2; done
g true >/dev/null 2>&1 || { record A0 "VM boots and SSH works" FAIL "no SSH answer"; exit 1; }
record A0 "VM boots and SSH works" PASS "$(g 'sw_vers -productVersion; uname -m' | tr '\n' ' ')"
g "sudo -n true" >/dev/null 2>&1 || { record A0a "passwordless sudo in the guest" FAIL ""; exit 1; }

g "rm -rf /tmp/app && mkdir -p /tmp/app"
tar -C "$SHARE" -cf - build Mastbound.app | g "tar -C /tmp/app -xf -"
g "sudo rm -rf /usr/local/mastbound-vm && sudo mkdir -p /usr/local/mastbound-vm && sudo cp -R /tmp/app/build /usr/local/mastbound-vm/ && sudo chown -R root:wheel /usr/local/mastbound-vm && sudo chmod -R go-w /usr/local/mastbound-vm"

# --- Start ------------------------------------------------------------------
check A1 "start a 30-minute commitment" g "sudo $CTL start --minutes 30"
check A1a "block in /etc/hosts" has_section

# --- Gate -------------------------------------------------------------------
refused A2 "finish with no open flow is refused" "No early end" g "sudo $ICTL recover --finish '$PHRASE'"
refused A3 "begin without a password (no sudo) is refused" "administrator" g "$ICTL recover --begin"
check A4 "begin opens the flow" g "sudo $ICTL recover --begin"
check A4a "status shows the open flow; phase active; block on" bash -c "$(declare -f g status phase flow_open has_section); TART='$TART' VM='$VM' KEY='$KEY' ICTL='$ICTL'; flow_open && [[ \$(phase) == active ]] && has_section"
refused A5 "finish right away is refused (too soon)" "too soon" g "sudo $ICTL recover --finish '$PHRASE'"
sleep 65
refused A6 "finish with a wrong phrase is refused" "phrase" g "sudo $ICTL recover --finish 'let me out'"
check A7 "finish after the minimum starts the 72-hour (test: 2-minute) wait" g "sudo $ICTL recover --finish '$PHRASE'"
check A7a "phase recovering, block still on" bash -c "$(declare -f g status phase has_section); TART='$TART' VM='$VM' KEY='$KEY' ICTL='$ICTL'; [[ \$(phase) == recovering ]] && has_section"

# --- One-click cancel (no password) -----------------------------------------
check A8 "cancel without a password ends the wait" g "$ICTL recover --cancel"
check A8a "back to active, block on" bash -c "$(declare -f g status phase has_section); TART='$TART' VM='$VM' KEY='$KEY' ICTL='$ICTL'; [[ \$(phase) == active ]] && has_section"
check A9 "begin again" g "sudo $ICTL recover --begin"
check A9a "cancel without a password closes an open flow" g "$ICTL recover --cancel"
check A9b "flow closed, phase active" bash -c "$(declare -f g status phase flow_open); TART='$TART' VM='$VM' KEY='$KEY' ICTL='$ICTL'; ! flow_open && [[ \$(phase) == active ]]"
refused A9c "finish after a cancel is refused" "No early end" g "sudo $ICTL recover --finish '$PHRASE'"

# --- Full early end ---------------------------------------------------------
check A10 "begin, wait, finish" bash -c "$(declare -f g); TART='$TART' VM='$VM' KEY='$KEY'; g 'sudo $ICTL recover --begin' >/dev/null && sleep 65 && g \"sudo $ICTL recover --finish '$PHRASE'\""
for i in $(seq 1 200); do has_section || break; sleep 1; done
if has_section; then record A10a "block clears after the test delay" FAIL "$(status | tr '\n' ' ')"; else record A10a "block clears after the test delay" PASS "after about $((i)) s"; fi
check A10b "phase idle, last end recovered" bash -c "$(declare -f g status); TART='$TART' VM='$VM' KEY='$KEY' ICTL='$ICTL'; status | grep -q 'phase: idle' && status | grep -qi 'recovered'"

# --- App for a person -------------------------------------------------------
g "sudo rm -rf /Applications/Mastbound.app && sudo ditto /tmp/app/Mastbound.app /Applications/Mastbound.app && sudo chown -R root:wheel /Applications/Mastbound.app"
record A11 "test app copied to /Applications in the VM" NOTE "open it in the VM window to try the password dialogs"

echo "Failures: $FAILS"
exit 0
