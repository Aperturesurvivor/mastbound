#!/usr/bin/env bash
# P3 real-system checklist. Installs Mastbound as root, changes the system
# clock and /etc/hosts, kills the daemon, and uninstalls it again.
#
# Run ONLY on a disposable Mac (a CI runner or a test VM), never on a Mac
# that someone uses: it needs passwordless sudo and changes system files.
#
#   MASTBOUND_DISPOSABLE_MACHINE=1 script/p3/real-system-check.sh \
#       <test-build-dir> <upgrade-build-dir> <results.md>
#
# Both build folders come from `script/build-cli.sh --testing` (the upgrade
# one also with `--upgrade-mark`). Results are written as a Markdown table.
set -uo pipefail

if [[ "${MASTBOUND_DISPOSABLE_MACHINE:-}" != "1" ]]; then
  echo "Refusing to run: set MASTBOUND_DISPOSABLE_MACHINE=1 on a disposable Mac only." >&2
  exit 2
fi
if [[ $# -ne 3 ]]; then
  echo "usage: $0 <test-build-dir> <upgrade-build-dir> <results.md>" >&2
  exit 2
fi
BUILD="$(cd "$1" && pwd)"
UPGRADE="$(cd "$2" && pwd)"
RESULTS="$3"
sudo -n true || { echo "Passwordless sudo is required." >&2; exit 2; }
if [[ -e /Library/LaunchDaemons/com.josiahwilson.screentimeroastermac.enforcer.plist ]]; then
  echo "The legacy Roaster daemon is installed here; this is not a clean machine." >&2
  exit 2
fi

LABEL="com.josiahwilson.mastbound"
HELPER="/Library/PrivilegedHelperTools/Mastbound"
STATE_DIR="/Library/Application Support/Mastbound"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
PHRASE="I want to end my commitment early"
MARKER="# BEGIN MASTBOUND — MANAGED BLOCK"
USER_BUILD="$BUILD"
# The installer only copies from a root-owned folder (SECURITY.md rule 9), as
# an app would after it stages its Resources folder. Stage both builds.
STAGE="/usr/local/mastbound-p3"
sudo rm -rf "$STAGE"
sudo mkdir -p "$STAGE"
sudo cp -R "$BUILD" "$STAGE/build"
sudo cp -R "$UPGRADE" "$STAGE/upgrade"
sudo chown -R root:wheel "$STAGE"
sudo chmod -R go-w "$STAGE"
BUILD="$STAGE/build"
UPGRADE="$STAGE/upgrade"
CTL="$BUILD/mastboundctl"
ICTL="$HELPER/mastboundctl"
FAILS=0

{
  echo "| # | Check | Result | Detail |"
  echo "| --- | --- | --- | --- |"
} > "$RESULTS"

record() { # record <id> <check> <PASS|FAIL|NOTE> <detail>
  local detail="${4//|/\\|}"
  detail="${detail//$'\n'/ }"
  echo "| $1 | $2 | $3 | ${detail:0:300} |" >> "$RESULTS"
  echo "[$3] $1 $2 — ${detail:0:300}"
  [[ "$3" == "FAIL" ]] && FAILS=$((FAILS + 1))
  return 0
}
check() { # check <id> <check> <command...>: PASS if the command succeeds
  local id="$1" name="$2"; shift 2
  local output
  if output="$("$@" 2>&1)"; then record "$id" "$name" PASS "$output"; else record "$id" "$name" FAIL "$output"; fi
}
wait_until() { # wait_until <seconds> <command...>
  local limit="$1"; shift
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= limit )) && return 1
    sleep 1
  done
}
daemon_pid() { sudo launchctl print "system/$LABEL" 2>/dev/null | awk '/^\tpid = / {print $3}'; }
section_lines() { grep -c -E $'^(0\\.0\\.0\\.0|::)\t' /etc/hosts || true; }
has_section() { grep -qF "$MARKER" /etc/hosts; }
no_section() { ! grep -qF "$MARKER" /etc/hosts; }
hosts_sha() { /usr/bin/shasum -a 256 /etc/hosts | cut -c1-64; }
phase() { "$ICTL" status 2>/dev/null | awk -F': ' '/^phase:/ {print $2}'; }
phase_is() { [[ "$(phase)" == "$1" ]]; }
resolves_blocked() { dscacheutil -q host -a name "$1" | grep -qE '^ip(v6)?_address: (0\.0\.0\.0|::)$'; }
mode_owner() { stat -f '%Sp %Su:%Sg' "$1"; }
duration_seconds() { sudo /usr/bin/plutil -extract commitment.durationSeconds raw -o - "$STATE_DIR/state.json" 2>/dev/null; }
daemon_running() { [[ -n "$(daemon_pid)" ]]; }
daemon_stopped() { [[ -z "$(daemon_pid)" ]]; }
section_complete() { [[ "$(section_lines)" == "$EXPECTED_LINES" ]]; }
restarted() { local pid; pid="$(daemon_pid)"; [[ -n "$pid" && "$pid" != "$OLD_PID" ]]; }
recovering_and_blocked() { phase_is recovering && has_section; }
last_end_is() { "$ICTL" status 2>/dev/null | grep -q "last commitment: $1" && phase_is idle; }
not_readable() { ! cat "$1" >/dev/null 2>&1; }
hosts_not_writable() { ! (echo x >> /etc/hosts) 2>/dev/null; }
refused_with() { # refused_with <expected message part> <command...>
  local expected="$1" output; shift
  if output="$("$@" 2>&1)"; then echo "command succeeded: $output"; return 1; fi
  [[ "$output" == *"$expected"* ]] || { echo "wrong refusal: $output"; return 1; }
  echo "$output"
}
stop_if_failed() { # stop_if_failed <step>: later checks mean nothing if this failed
  if (( FAILS > 0 )); then
    record "--" "remaining checks" FAIL "not run: $1 failed"
    echo; echo "Failures: $FAILS"; echo "" >> "$RESULTS"; echo "Failures: $FAILS" >> "$RESULTS"
    exit 1
  fi
}
resolves_normally() { dscacheutil -q host -a name "$1" | grep -E '^ip(v6)?_address: ' | grep -qvE ': (0\.0\.0\.0|::|127\.)'; }
connection_fails() { ! curl -sS --max-time 5 -o /dev/null "http://$1/"; }
gone() { ! sudo test -e "$1"; }

EXPECTED_LINES=$(( $(wc -l < "$BUILD/adult-domains.txt") * 2 ))
ORIGINAL_HOSTS_SHA="$(hosts_sha)"
# A list domain that resolves to a real address now, so the block is visible.
DOMAIN=""
for line in $(seq 1000 1400); do
  candidate="$(sed -n "${line}p" "$BUILD/adult-domains.txt")"
  if resolves_normally "$candidate"; then DOMAIN="$candidate"; DOMAIN_LINE=$line; break; fi
done
record P0 "Start state" NOTE "macOS $(sw_vers -productVersion), hosts sha ${ORIGINAL_HOSTS_SHA:0:12}, test domain list line ${DOMAIN_LINE:-none}, $("$CTL" version)"
record P0a "test domain resolves normally before the block" "$([[ -n "$DOMAIN" ]] && echo PASS || echo FAIL)" "${DOMAIN:+cached in DNS}"
stop_if_failed P0a

# --- Start -----------------------------------------------------------------
check S0 "install from a user-owned build folder is refused" refused_with "is not trusted" sudo "$USER_BUILD/mastboundctl" start --minutes 30
check S0a "nothing installed after the refusal" gone "$PLIST"
check S1 "start installs and blocks" sudo "$CTL" start --minutes 30
check S1a "daemon running under launchd" wait_until 20 daemon_running
record S1b "hosts section has every domain (v4+v6)" "$(section_complete && echo PASS || echo FAIL)" "$(section_lines) of $EXPECTED_LINES lines"
check S1c "DNS cache flushed: test domain resolves to 0.0.0.0 at once" resolves_blocked "$DOMAIN"
check S1d "connection to the test domain fails" connection_fails "$DOMAIN"
check S1d2 "curl reports the block, not a DNS failure" bash -c "curl -sS --max-time 5 -o /dev/null http://$DOMAIN/ 2>&1 | grep -qv 'Could not resolve'"
details="$(for f in "$HELPER/mastboundd" "$HELPER/mastboundctl" "$HELPER/adult-domains.txt" "$PLIST" "$STATE_DIR/state.json" "$STATE_DIR/status.json" "$STATE_DIR/locked-list.txt"; do printf '%s %s; ' "$(basename "$f")" "$(sudo stat -f '%Lp %Su:%Sg' "$f")"; done)"
expected="mastboundd 755 root:wheel; mastboundctl 755 root:wheel; adult-domains.txt 644 root:wheel; $LABEL.plist 644 root:wheel; state.json 600 root:wheel; status.json 644 root:wheel; locked-list.txt 600 root:wheel; "
record S1e "file modes and owners" "$([[ "$details" == "$expected" ]] && echo PASS || echo FAIL)" "$details"
check S1f "status readable without root" phase_is active
check S1g "normal user cannot read the state" not_readable "$STATE_DIR/state.json"
check S1h "normal user cannot write /etc/hosts" hosts_not_writable
stop_if_failed S1

# --- Repair ----------------------------------------------------------------
sudo /usr/bin/sed -i '' "/$MARKER/,/# END MASTBOUND/d" /etc/hosts
record S2 "hand edit removed the section" NOTE "$(section_lines) lines left"
check S2a "daemon restores the section within 15 s" wait_until 15 has_section
check S2b "restored section is complete" section_complete

# --- Kill the daemon ------------------------------------------------------
OLD_PID="$(daemon_pid)"
sudo kill -9 "$OLD_PID"
check S3 "launchd restarts a killed daemon within 30 s" wait_until 30 restarted
check S3a "block still in place after the kill" has_section

# --- Clock change ----------------------------------------------------------
BEFORE_DURATION="$(duration_seconds)"
CLOCK_START=$SECONDS
SAVED_EPOCH="$(date -u +%s)"
sudo systemsetup -setusingnetworktime off >/dev/null 2>&1 || true
sudo date -u "$(date -u -r $(( SAVED_EPOCH + 365 * 86400 )) +%m%d%H%M%Y.%S)" >/dev/null
sleep 8
check S4 "clock one year forward: still active" phase_is active
check S4a "clock one year forward: block still in place" has_section
sudo date -u "$(date -u -r $(( SAVED_EPOCH - 30 * 86400 )) +%m%d%H%M%Y.%S)" >/dev/null
sleep 8
check S4b "clock 30 days back: still active" phase_is active
sudo date -u "$(date -u -r $(( SAVED_EPOCH + SECONDS - CLOCK_START )) +%m%d%H%M%Y.%S)" >/dev/null
sudo systemsetup -setusingnetworktime on >/dev/null 2>&1 || true
record S4c "duration not changed by clock moves" "$([[ "$(duration_seconds)" == "$BEFORE_DURATION" ]] && echo PASS || echo FAIL)" "duration $BEFORE_DURATION -> $(duration_seconds)"
record S4d "status after clock restore" NOTE "$("$ICTL" status 2>&1 | tr '\n' ';')"

# --- Refusals --------------------------------------------------------------
check S5 "uninstall is refused while active" refused_with "A commitment is running" sudo "$ICTL" uninstall
check S5a "daemon still running after refused uninstall" daemon_running
check S5b "second start is refused" refused_with "already running" sudo "$ICTL" start --minutes 5
check S5c "recovery with a wrong phrase is refused" refused_with "phrase does not match" sudo "$ICTL" recover --confirm "let me out"

# --- Delete the app --------------------------------------------------------
sudo mv "$BUILD" "$STAGE/build.moved"
sleep 6
check S6 "source build deleted: daemon still running" daemon_running
check S6a "source build deleted: block still in place" has_section
sudo mv "$STAGE/build.moved" "$BUILD"

# --- Upgrade ---------------------------------------------------------------
STARTED_BEFORE="$(sudo /usr/bin/plutil -extract commitment.startedAt raw -o - "$STATE_DIR/state.json")"
check S7 "install a newer build during the commitment" sudo "$UPGRADE/mastboundctl" install
check S7a "installed tool is the new version" bash -c "\"$ICTL\" version | grep -q upgrade"
check S7b "daemon running after upgrade" wait_until 20 daemon_running
record S7c "commitment kept by upgrade" "$([[ "$(sudo /usr/bin/plutil -extract commitment.startedAt raw -o - "$STATE_DIR/state.json")" == "$STARTED_BEFORE" ]] && phase_is active && echo PASS || echo FAIL)" "startedAt $STARTED_BEFORE, phase $(phase)"
check S7d "block in place after upgrade" has_section

# --- Extend ----------------------------------------------------------------
BEFORE_DURATION="$(duration_seconds)"
check S8 "extend by 10 minutes" sudo "$ICTL" extend --minutes 10
record S8a "duration grew by 600 s" "$(awk -v a="$BEFORE_DURATION" -v b="$(duration_seconds)" 'BEGIN { print (b - a == 600) ? "PASS" : "FAIL" }')" "$BEFORE_DURATION -> $(duration_seconds)"

# --- Admin boundary (documented bypass) -----------------------------------
sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1
sleep 3
record S9 "admin can stop the daemon with launchctl bootout" "$(daemon_stopped && echo NOTE || echo FAIL)" "documented limit: an administrator can stop enforcement"
check S9a "block stays in /etc/hosts while the daemon is stopped" has_section
check S9b "install brings the daemon back" sudo "$ICTL" install
check S9c "daemon running again" wait_until 20 daemon_running

# --- Recovery --------------------------------------------------------------
check S10 "recovery request with the exact phrase" sudo "$ICTL" recover --confirm "$PHRASE"
check S10a "phase is recovering, block in place" recovering_and_blocked
check S10b "recovery clears the block after the test delay (120 s)" wait_until 160 no_section
check S10c "phase idle, last end recovered" last_end_is recovered
record S10d "hosts file exactly as before" "$([[ "$(hosts_sha)" == "$ORIGINAL_HOSTS_SHA" ]] && echo PASS || echo FAIL)" "sha ${ORIGINAL_HOSTS_SHA:0:12} -> $(hosts_sha | cut -c1-12)"

# --- Expiry ----------------------------------------------------------------
check S11 "start a 1-minute commitment" sudo "$ICTL" start --minutes 1
check S11a "block in place" has_section
check S11b "commitment ends by itself within 90 s" wait_until 90 no_section
check S11c "phase idle, last end completed" last_end_is completed
check S11d "locked list removed" gone "$STATE_DIR/locked-list.txt"
record S11e "hosts file exactly as before" "$([[ "$(hosts_sha)" == "$ORIGINAL_HOSTS_SHA" ]] && echo PASS || echo FAIL)" "$(hosts_sha | cut -c1-12)"

# --- Uninstall ---------------------------------------------------------------
check S12 "uninstall when idle" sudo "$ICTL" uninstall
check S12a "daemon gone" daemon_stopped
check S12b "helper, state and plist removed" bash -c "! sudo test -e \"$HELPER\" && ! sudo test -e \"$STATE_DIR\" && ! sudo test -e \"$PLIST\""
record S12c "hosts file exactly as before" "$([[ "$(hosts_sha)" == "$ORIGINAL_HOSTS_SHA" ]] && echo PASS || echo FAIL)" "$(hosts_sha | cut -c1-12)"

# --- Log -------------------------------------------------------------------
ERRORS="$(log show --last 30m --predicate 'subsystem == "com.josiahwilson.mastbound"' --style compact 2>/dev/null | grep -c 'Reconcile failed' || true)"
record S13 "daemon log: reconcile failures" "$([[ "$ERRORS" == 0 ]] && echo PASS || echo FAIL)" "$ERRORS failures logged"
record S13a "daemon log: versions started" NOTE "$(log show --last 30m --predicate 'subsystem == "com.josiahwilson.mastbound"' --style compact 2>/dev/null | grep -o 'mastboundd [^ ]* started[^"]*' | sort | uniq -c | tr '\n' ';')"

sudo rm -rf "$STAGE"

echo
echo "Failures: $FAILS"
echo "" >> "$RESULTS"
echo "Failures: $FAILS" >> "$RESULTS"
exit $(( FAILS > 0 ))
