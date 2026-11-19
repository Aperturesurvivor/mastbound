#!/usr/bin/env bash
# Checks that each SafeSearch address in Sources/MastboundCore/SafeSearch.swift
# still filters explicit image results. Run before every release.
#
# Bing and DuckDuckGo: a test search through the address must come back
# filtered. Google sends scripts a page without results, so for Google the
# address must still be what forcesafesearch.google.com publishes.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/Sources/MastboundCore/SafeSearch.swift"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
addr() { /usr/bin/grep -A1 "/// $1" "$SRC" | /usr/bin/grep -oE '"[0-9.]+"' | /usr/bin/tr -d '"'; }
status=0
report() { if [[ "$1" == ok ]]; then echo "ok   $2"; else echo "FAIL $2"; status=1; fi; }

g="$(addr forcesafesearch.google.com)"
/usr/bin/dig +short forcesafesearch.google.com A | /usr/bin/grep -qx "$g" && report ok "Google $g is forcesafesearch.google.com" || report fail "Google $g is no longer forcesafesearch.google.com"

b="$(addr strict.bing.com)"
filtered=$(/usr/bin/curl -s -m 15 -A "$UA" --resolve "www.bing.com:443:$b" 'https://www.bing.com/images/search?q=nude' | /usr/bin/grep -o murl | /usr/bin/wc -l | tr -d ' ')
normal=$(/usr/bin/curl -s -m 15 -A "$UA" 'https://www.bing.com/images/search?q=nude&adlt=off' | /usr/bin/grep -o murl | /usr/bin/wc -l | tr -d ' ')
[[ "$filtered" -eq 0 && "$normal" -gt 0 ]] && report ok "Bing $b filters (0 results; $normal without it)" || report fail "Bing $b: $filtered results (unfiltered: $normal)"

d="$(addr safe.duckduckgo.com)"
/usr/bin/curl -s -m 15 -A "$UA" --resolve "duckduckgo.com:443:$d" 'https://duckduckgo.com/?q=nude&ia=images' | /usr/bin/grep -q 'kp=1' && report ok "DuckDuckGo $d filters (kp=1)" || report fail "DuckDuckGo $d does not force kp=1"
exit $status
