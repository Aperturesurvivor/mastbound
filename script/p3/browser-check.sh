#!/bin/bash
# Runs INSIDE a test VM with an active commitment and Chrome and Firefox in
# /Applications. For each browser setting it loads a blocked site headless and
# checks the browser's own network log for the site's real address.
# Never prints the domain or any page.
#   CONTROL=example.com bash browser-check.sh   # every case must say REACHED
#   bash browser-check.sh                       # every case must say BLOCKED
LIST=/Library/Application\ Support/Mastbound/locked-list.txt
D=""; IPS=""
if [[ -n "$CONTROL" ]]; then D=$CONTROL; IPS=$( (dig +short @1.1.1.1 "$D" A; dig +short @1.1.1.1 "$D" AAAA) | grep -E "^[0-9a-f.:]+$" | tr "\n" " "); fi
[[ -z "$D" ]] && for n in $(seq 1000 1400); do
  c=$(sudo sed -n "${n}p" "$LIST" 2>/dev/null)
  [[ -z "$c" ]] && continue
  ips=$( (dig +short +time=2 @1.1.1.1 "$c" A; dig +short +time=2 @1.1.1.1 "$c" AAAA) | grep -E '^[0-9a-f.:]+$' | tr '\n' ' ')
  if [[ -n "$ips" ]]; then D=$c; IPS=$ips; echo "test domain: list line $n, ${#IPS} chars of real IPs"; break; fi
done
[[ -z "$D" ]] && { echo "no test domain"; exit 1; }
echo "system resolver: $(dscacheutil -q host -a name "$D" | awk '/ip_address/ {print $2}' | sort -u | tr '\n' ' ')"

run_case() { # run_case <name> <log file> <command...>
  local name="$1" log="$2"; shift 2
  rm -f "$log"
  "$@" >/dev/null 2>&1 &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && (( t < 40 )); do sleep 0.5; t=$((t+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  pkill -f "Google Chrome" 2>/dev/null; pkill -f firefox 2>/dev/null; sleep 1
  local hit=0 ip
  for ip in $IPS; do grep -qF "$ip" "$log"* 2>/dev/null && hit=1; done
  local size; size=$(cat "$log"* 2>/dev/null | wc -c | tr -d ' ')
  if [[ $size -lt 100 ]]; then echo "NONE $name: no log ($size bytes)"
  elif [[ $hit == 0 ]]; then echo "BLOCKED $name: real address not in the log ($size bytes)"
  else echo "REACHED $name: real address in the log"; fi
}
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FF=/Applications/Firefox.app/Contents/MacOS/firefox
rm -rf /tmp/chp* /tmp/ffp*; mkdir -p /tmp/chp1 /tmp/chp2 /tmp/ffp1 /tmp/ffp2
echo '{"dns_over_https":{"mode":"secure","templates":"https://cloudflare-dns.com/dns-query"}}' > "/tmp/chp2/Local State"

run_case "curl (system resolver)" /tmp/curl.log curl -sv --max-time 12 -o /dev/null "https://$D/" --stderr /tmp/curl.log
run_case "Chrome, default settings" /tmp/ch1.json "$CH" --log-net-log=/tmp/ch1.json --headless=new --no-first-run --user-data-dir=/tmp/chp1 --dump-dom "https://$D/"
# Chrome secure DNS forced on (as a user could set it): DoH to Cloudflare.
run_case "Chrome, secure DNS forced (Cloudflare)" /tmp/ch2.json "$CH" --log-net-log=/tmp/ch2.json --headless=new --no-first-run --user-data-dir=/tmp/chp2 \
  --enable-features="DnsOverHttps<DoHTrial" --force-fieldtrials="DoHTrial/Group1" \
  --force-fieldtrial-params="DoHTrial.Group1:Fallback/false/Templates/https%3A%2F%2Fcloudflare-dns.com%2Fdns-query" \
  --dump-dom "https://$D/"
run_case "Firefox, default settings" /tmp/ff1.log env MOZ_LOG=nsHostResolver:5,nsSocketTransport:5 MOZ_LOG_FILE=/tmp/ff1.log "$FF" --headless --no-remote --profile /tmp/ffp1 --screenshot /tmp/ff1.png "https://$D/"
cat > /tmp/ffp2/user.js <<'U'
user_pref("network.trr.mode", 3);
user_pref("network.trr.uri", "https://mozilla.cloudflare-dns.com/dns-query");
U
run_case "Firefox, DNS over HTTPS only (mode 3)" /tmp/ff2.log env MOZ_LOG=nsHostResolver:5,nsSocketTransport:5 MOZ_LOG_FILE=/tmp/ff2.log "$FF" --headless --no-remote --profile /tmp/ffp2 --screenshot /tmp/ff2.png "https://$D/"
cat > /tmp/ffp1/user.js <<'U'
user_pref("network.trr.mode", 2);
user_pref("network.trr.uri", "https://mozilla.cloudflare-dns.com/dns-query");
U
run_case "Firefox, DNS over HTTPS first (mode 2)" /tmp/ff3.log env MOZ_LOG=nsHostResolver:5,nsSocketTransport:5 MOZ_LOG_FILE=/tmp/ff3.log "$FF" --headless --no-remote --profile /tmp/ffp1 --screenshot /tmp/ff3.png "https://$D/"
rm -f /tmp/ff*.png
