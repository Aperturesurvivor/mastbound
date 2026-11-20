# Real-system verification (P3)

Checklist: `script/p3/real-system-check.sh`. It runs as root on a disposable
Mac and refuses to run unless `MASTBOUND_DISPOSABLE_MACHINE=1`. It uses a
test build (`script/build-cli.sh --testing`: 1-minute minimum, 2-minute
recovery delay, daemon tick 2 s). Every other rule is the same as a release
build.

## Run 2 — 2026-11-10, GitHub runner — 0 failures

Workflow `real-system`, run 42918789113, commit `9080326`.
macOS 26.7.2 on Apple silicon (GitHub `macos-26` runner), clean machine.

| # | Check | Result |
| --- | --- | --- |
| P0a | Test domain (list line 1001) resolves normally before the block | PASS |
| S1 | `sudo mastboundctl start --minutes 30` installs and blocks | PASS |
| S1a | Daemon running under launchd | PASS |
| S1b | Hosts section complete: 153,488 of 153,488 lines (IPv4 + IPv6) | PASS |
| S1c | DNS cache flushed: test domain resolves to `0.0.0.0` at once | PASS |
| S1d | Connection to the test domain fails ("Couldn't connect", not a DNS error) | PASS |
| S1e | Modes and owners: binaries 755, list and plist 644, `state.json` 600, `status.json` 644, `locked-list.txt` 600, all `root:wheel` | PASS |
| S1f–h | Status readable without root; state not readable; `/etc/hosts` not writable by the user | PASS |
| S2 | Section removed by hand; restored within 15 s (took about 1 s) and complete | PASS |
| S3 | `kill -9` of the daemon: launchd restarts it (about 8 s); block stays | PASS |
| S4 | Clock one year forward, then 30 days back: still active, block stays, duration unchanged (1800 → 1800 s) | PASS |
| S5 | Uninstall, second start, and wrong recovery phrase are refused with the right message; daemon keeps running | PASS |
| S6 | Source build folder deleted (stands in for deleting the app): daemon runs, block stays | PASS |
| S7 | Newer build installed during the commitment: new version runs, `startedAt` unchanged, block stays | PASS |
| S8 | Extend by 10 minutes: duration 1800 → 2400 s | PASS |
| S9 | `sudo launchctl bootout` stops the daemon (documented admin limit); block stays in `/etc/hosts`; `install` brings the daemon back | PASS / NOTE |
| S10 | Recovery with the exact phrase: block stays for the delay, then clears; last end `recovered`; hosts file byte-identical to the start | PASS |
| S11 | 1-minute commitment ends by itself; last end `completed`; locked list removed; hosts file byte-identical | PASS |
| S12 | Uninstall when idle: daemon, helper folder, state folder and plist removed; hosts file byte-identical | PASS |
| S13 | Daemon log: 0 reconcile failures | PASS |

## Run 1 — 2026-11-10 — failed, bug found

Run 42918112134, commit `cc71ecf`. **`start` failed on a clean Mac** with
"No such file or directory": `/Library/PrivilegedHelperTools` did not exist
and the installer's `mkdir` was not recursive. The developer Mac has that
folder, so unit and integration tests did not find it. Fixed in `9080326`
(installer creates missing parents, refuses a parent writable by others;
errors now name the file).

The run also showed that the checklist was too weak: with nothing installed,
"refused" checks passed because the command did not exist, and the first test
domain did not exist in DNS. The checklist now stops if install fails,
requires the expected refusal text, and picks a domain that resolves before
the block.

## Not yet verified

These need a local macOS VM (GitHub runners cannot reboot), or a person.

| Item | Why not yet | How |
| --- | --- | --- |
| Sleep and wake | Not supported in CI | VM or real Mac |
| "Allow in the Background" switch in Login Items stops the daemon; admin password needed?; block stays in `/etc/hosts`? | Needs a GUI | Manual in a VM |
| Browsers: Safari, Chrome, Firefox (DNS-over-HTTPS), iCloud Private Relay, VPN | Needs a GUI and accounts | Manual in a VM |
| Real `.app` bundle, admin password prompt, Gatekeeper and notarization | No app yet (P5/P6) | After P5 |
| Intel Macs | Runner is Apple silicon only | Optional |

A local VM needs about 45 GB free (24 GB image plus room for its 50 GB
sparse disk to grow). On 2026-11-11, after a cleanup, this Mac had about
35 GB free. These checks stay open until a Mac or an external APFS drive
with enough space is available. They must pass before a public release.

## Run 3 — 2026-11-11 (P5)

CI run 43111667292 on a GitHub macOS runner. 0 failures. New checks S0 and
S0a pass: `sudo mastboundctl start` from a user-owned build folder is refused
with "Install source … is not trusted", and nothing is installed. All
earlier checks still pass with both builds staged in a root-owned folder.

## Runs 4–7 — 2026-11-16 (early-end changes)

| Run | Commit | Result |
| --- | --- | --- |
| 43… (run 4) | `5f6ae05` | 3 failures. New password-free cancel checks (S10c1–S10c3) pass. **Hosts repair after a hand edit was slow** (S2a, S2b, S3a). |
| run 5 | `556ddd0` | Same 3 failures. Diagnostics: section still missing after 136 s, daemon running, nothing in its log. |
| run 6 | `dc88ad3` | Repair passed (fault is intermittent). S11d failed: a test race, the check ran before the daemon removed the locked list. |
| run 7 | `969e2a3` | **0 failures.** Repair checked 6 times, each within 1 s. |

**Cause (likely, not proven):** the daemon waited with no time limit for
`dscacheutil -flushcache` and `killall -HUP mDNSResponder`. A hung flush
stops the whole loop, which fits "running, no error, no repair". Fix:
every system command now has a time limit and is killed after it (5 s for
the flush), with a unit test. The stack sample (S2w) was added but did not
trigger in run 7, so the cause is not confirmed. The repeated repair check
(S2r1–S2r5) stays in the checklist to catch it.

## Local VM — 2026-11-16

`script/p3/vm-check.sh` on this Mac, Tart VM (macOS 26.6.2, arm64), cloned
from `mastbound-base` (the Cirrus `macos-tahoe-vanilla` image with a test
SSH key added by Josiah once; the image has no Tart guest agent). Test build.

`mastbound-base` and `mastbound-release` were deleted on 2026-11-20 to free
52 GB. To make the base again, run `script/p3/make-base-vm.sh` (it downloads
the image, about 25 GB, and asks once for the VM's password).

| # | Check | Result |
| --- | --- | --- |
| R1–R4 | Restart during a commitment: new boot session, daemon back (RunAtLoad), block in place, phase active | PASS |
| R5 | Time across the restart is credited | PASS: +85 s over 92 s wall (the rest is the gap since the last save, by design) |
| P0.2, P0.5, P1, P2 | Hard power-off (VM process killed) 0.2–2 s after a hand edit of the block | PASS: state valid, block complete each time |
| S1, S2 | Sleep | Not testable: the VM cannot sleep (`0xe00002e2`). Commitment stays active. |
| V1 | Full checklist inside the VM | Not run: its first check needs a list domain that resolves to IPv4, and the VM's DNS returned only IPv6. The same checklist passes on the CI runner. |

**Found:** the first check after a cold start reads both lists and took up
to 19 s in the VM (1.4 s on this Mac when warm). The block written before
the restart stays in `/etc/hosts` during that time; only a block that was
damaged right before the power cut waits that long for repair. The first
run of this script also failed for test reasons only: it looked after 8 s,
and `plutil -lint` does not read JSON. Both fixed.

Still open: real sleep and wake (needs a real Mac), browsers.

## App early-end commands — 2026-11-17

`script/p3/app-check.sh mastbound-base`, Tart VM `mastbound-app` (macOS
26.6.2, arm64) cloned from `mastbound-base`. Test build (1-minute flow
minimum, 2-minute recovery delay). These are the commands the app runs.
0 failures.

| # | Check | Result |
| --- | --- | --- |
| A0 | VM boots, SSH and passwordless sudo work | PASS |
| A1, A1a | Start a 30-minute commitment; block in `/etc/hosts` | PASS |
| A2 | `recover --finish` with no open flow | Refused: "No early end is in progress" |
| A3 | `recover --begin` without sudo | Refused: needs administrator rights |
| A4, A4a | `recover --begin` opens the flow; phase active; block on | PASS |
| A5 | Finish right away | Refused: "too soon" |
| A6 | Finish after 65 s with a wrong phrase | Refused: phrase does not match |
| A7, A7a | Finish after the minimum | PASS: phase recovering, block still on |
| A8, A8a | `recover --cancel` without sudo during the wait | PASS: back to active, block on |
| A9–A9c | Begin, then cancel without sudo; finish after cancel | PASS: flow closed; finish refused |
| A10, A10a | Full early end | PASS: block cleared about 108 s after finish |
| A10b | Phase idle, last end "recovered" | PASS |
| A11 | Test app copied to `/Applications` in the VM | For the GUI check by a person |

Still open from this run: the app's own password dialogs and the flow UI,
by a person in the VM window.

### GUI check of the app — 2026-11-17

Claude drove the test app in the VM over Screen Sharing, and the demo app
on this Mac. Josiah typed the VM password at each macOS dialog.

| Check | Result |
| --- | --- |
| Start (1 day) asks for the password, then the block is on (63,312 domains) | PASS (VM) |
| End early → Begin asks for the password, then the daemon shows the open flow | PASS (VM) |
| Terms intro fades in; 12 terms; every third must be typed exactly; a wrong one locks for 20 s | PASS (VM) |
| Three quick answers show "Slow down"; the slider resists; holding it at the end for 10 s goes back to the same step | PASS (demo, twice: terms and codes) |
| Codes, Sums, Grids, Write, Wait, Hold, Facts, Last step | PASS (demo) |
| End early, then "Keep my commitment" during the wait goes back to the normal countdown | PASS (demo) |
| Slow down in the VM: three quick sums show the slider; holding it at the end goes back to the same step | PASS (VM, twice) |
| Full flow in the VM: terms, codes, sums, grids, write, 1-minute wait, hold, facts, last step | PASS (VM) |
| End early on the last step asks for the password, then the daemon is in recovery and the block stays on | PASS (VM) |
| The app shows the recovery countdown with Keep my commitment and Add time | PASS (VM) |
| After the 2-minute test recovery the block clears (0 lines left), phase idle, the app shows the start screen | PASS (VM) |
| An open flow that is not finished lapses; the app goes back to the countdown | PASS (VM) |

**Found and fixed:**

- While one command waited for the password, the other button also showed
  "Keeping it…". Each button now shows busy text only for its own command.
- A test build of the app used the real 15-minute wait, but the test daemon
  lets an open flow lapse after 10 minutes, so the flow could not finish.
  `build-app.sh --testing` now builds the app with the test limits too
  (1-minute wait, 15-second hold, 10-second written answers).
- The intro said "1 minutes" in test builds. It now says "a minute".
- The first full VM run lapsed after 10 minutes: typing 450 characters over
  Screen Sharing is slow. The test daemon now lets an open flow stay open
  for 20 minutes. Release limits are not changed (1 hour minimum, 4 hours).

**Note:** Screen Sharing typing sends every letter as "a" (the text is sent
as Unicode with key code 0). Single key presses work, so text was sent one
key at a time.

**Note:** When an open flow lapses, the app goes back to the countdown with no
message. This is safe, but a short line ("The early end timed out") may help.

### Suspend, reboot and browsers — 2026-11-17

Tart VM `mastbound-app`, test build, a 30-minute commitment started with
`mastboundctl start`.

**Sleep.** The VM cannot sleep: `pmset sleepnow` does nothing, and macOS
reports 0 sleeps since boot. Real sleep is still to be checked on a spare
Mac (never on the main Mac). The code counts time with
`mach_continuous_time`, which keeps counting during sleep, so sleep should
take time off the commitment.

| Check | Result |
| --- | --- |
| Reboot: commitment still active, block on (63,312 lines) | PASS |
| Reboot: 75 s credited for 75 s of real time | PASS |
| VM suspend for about 2 minutes, then resume: same boot session | PASS |
| After the resume: still active, block on | PASS |
| The frozen time is not credited: the end moved about 2 minutes later | PASS (safe direction) |

**Browsers.** `script/p3/browser-check.sh` runs in the VM. It loads a
blocked site headless and looks for the site's real address in the
browser's own network log (Chrome `--log-net-log`, Firefox `MOZ_LOG`). It
never prints the domain or a page. A control run with `example.com` found
the real address in every case, so the check can see a bypass.

| Case | Blocked site |
| --- | --- |
| curl (system resolver; Safari uses the same) | BLOCKED |
| Chrome, default settings | BLOCKED |
| Chrome, secure DNS on, Cloudflare (`secure_dns_mode` 2, 340 DoH requests) | BLOCKED |
| Firefox, default settings | BLOCKED |
| Firefox, DNS over HTTPS first (`network.trr.mode` 2) | BLOCKED |
| Firefox, DNS over HTTPS only (`network.trr.mode` 3) | BLOCKED |

Chrome and Firefox both read `/etc/hosts` before DNS over HTTPS, so their
secure DNS settings do not get around the block.

**Not covered:** Safari itself (no network log; it uses the system resolver,
which returns `0.0.0.0`), a VPN, iCloud Private Relay, and other browsers.

## Login Items switch — 2026-11-18

macOS lists the daemon as `mastboundd` under System Settings > General >
Login Items & Extensions > App Background Activity. Tested in the VM with a
30-minute test commitment.

| Check | Result |
| --- | --- |
| Turning the switch off asks for an administrator password | PASS |
| After it is off: launchd removes the job at once; the block stays (63,312 lines) | PASS |
| Reboot with the switch off: the daemon stays off; the block stays | PASS |
| The app shows "Mastbound's background service is off" (new) | PASS |
| "Open Login Items" opens the right page | PASS |
| `mastboundctl status` prints the same warning (new) | PASS |
| Switch on again: the daemon runs; the off time (about 8 minutes, with a reboot) is credited; the end time did not move | PASS |
| `mastboundctl install` 8 times in a row during a commitment (fix below) | PASS, 8/8 |

**Result.** The switch does not remove the block. While it is off, nothing can
end the commitment, so the block stays until the switch is on again. An
administrator who turns it off can then edit `/etc/hosts` by hand; this is
the same documented limit as `launchctl bootout` (S9), with an easier way in.

**Fixes.**
- The app shows the service-off screen when a commitment runs and
  `status.json` is more than 3 minutes old for at least 20 seconds (the
  daemon saves at least once a minute). The grace time stops a flash after a
  wake. Snapshot: `docs/ui-draft/5b-service-off.png`.
- `mastboundctl install` (also run by `start`) did a `bootstrap` right after
  `bootout`. launchd had not removed the job yet, and the bootstrap failed
  with error 5, which left the daemon off. It now waits for the job to go and
  tries the bootstrap up to 5 times. The last error names the Login Items
  switch.

**Not verified:** the new error text when the switch is off during `start`.

## Release 0.1.0 DMG — 2026-11-18

`script/release.sh` built `dist/Mastbound-0.1.0.dmg` (SHA-256
`c57c1ca1b41cee62b1f0aa3bb2c3cdee1a9eda3c577de70efa842b419dea7187`).
Apple notarization: Accepted (submission f62b9386-d5bd-4ff6-af02-cbe336634507),
ticket stapled. Tested in a fresh clone of the clean base VM (macOS 26.6.2,
no Mastbound before), with the DMG marked as downloaded by Safari
(`com.apple.quarantine`).

| Check | Result |
| --- | --- |
| `spctl` on the downloaded DMG: accepted, "Notarized Developer ID" | PASS |
| `spctl` on the app copied to /Applications (quarantine kept): accepted | PASS |
| `mastboundd`, `mastboundctl`: Developer ID, hardened runtime, team TXWB2TUKP2 | PASS |
| The app's start steps (root-owned stage, then `start --minutes 60`) | PASS |
| Daemon running under launchd; block in `/etc/hosts` (63,312 lines) | PASS |
| A listed site resolves to `0.0.0.0` | PASS |
| Login Items shows the developer as "Josiah Wilson" | PASS |
| The app opens | PASS |

The admin password prompt itself was not shown in this run (it was tested
with the ad-hoc test build on 2026-11-17).

## Safari HTTPS-record bypass — 2026-11-18

**Found on the main Mac** with the 0.1.0 DMG: a Safari private window loaded
`4chan.org` while `/etc/hosts` blocked it. A connection monitor saw Safari's
WebKit network process connect to the site's real address. Cause: Safari asks
for DNS HTTPS records (type 65). `/etc/hosts` only answers A and AAAA, so
`mDNSResponder` asks the real DNS server, and the answer carries the
addresses as `ipv4hint`/`ipv6hint`.

**Fix:** files in `/etc/resolver/` (resolver(5)) for the most visited listed
domains send every DNS question for them to `127.0.0.1` port 9, where
nothing answers. `ResolverFiles` manages only files that start with its
marker and removes them at the end. The ranking is the Tranco list `V38GN`
(`Resources/resolver-domains.txt`, `script/make-resolver-list.sh`): 6,593
of 44,001 root domains are in the top million.

**Limit (VM, macOS 26.6.2):** `configd` publishes up to 6,000 resolver files
(5,500 and 6,000 pass, also after a reboot); from 6,500 it publishes no DNS
setup at all ("No DNS configuration available"). Mastbound uses 4,000.

| Check (VM, release commitment running) | Result |
| --- | --- |
| `mastboundctl install` of the new daemon keeps the commitment | PASS |
| 4,000 files written, root:wheel 0644; `scutil --dns` lists 4,008 resolvers | PASS |
| `dns-sd -Q 4chan.org 65`: no answer; `boards.4chan.org` too | PASS |
| `4chan.org` A lookup still `0.0.0.0` | PASS |
| `cloudflare.com` HTTPS record still answered; github.com loads | PASS |
| Reboot: 4,000 files, 4,008 resolvers, HTTPS record still blocked | PASS |
| 116 unit and integration tests (13 new for resolver files) | PASS |

**Not covered:** the ~40,000 listed domains outside the top 4,000 can still
load in Safari through the HTTPS hint.

## Forced SafeSearch (0.1.2) — 2026-11-19

Change: during a commitment the hosts section sends Google's 187 search
domains (bare and `www.`), `bing.com`, `www.bing.com` and five DuckDuckGo
search names to each provider's filtering server. IPv6 is `::`. The search
host names (not the bare domains) also get resolver files.

Address checks on the host Mac (`script/check-safesearch.sh` and by hand):

| Address | Result |
| --- | --- |
| 216.239.38.120 (forcesafesearch.google.com) | Published A record; Google sends scripts a page with no results, so it is checked in Safari below |
| 150.171.28.16, 150.171.27.16 (strict.bing.com) | Filtered: 0 image results for an explicit search |
| 150.171.29.16, 150.171.30.16 (strict.bing.com's DNS answer at the time) | **Not filtered**: 35 image results |
| 2620:1ec:33:2::16, 2620:1ec:33:3::16 (strict.bing.com IPv6) | **Not filtered**: 35 image results |
| 52.149.247.1 (safe.duckduckgo.com) | Filtered: `kp=1` forced |

So the addresses are fixed in the app, not looked up, and IPv6 is always `::`.

VM `mastbound-release`, release build 0.1.2 (5b6b525), real 90-minute commitment:

| Check | Result |
| --- | --- |
| Hosts: 374 SafeSearch rows; block rows unchanged | PASS |
| Resolver files: 4,193 (4,000 top sites, 187 `www.google.*`, 5 Bing and DuckDuckGo, 1 foreign file kept) | PASS |
| `dscacheutil`: www.google.com, google.de, www.bing.com, duckduckgo.com resolve to the filtering addresses, IPv6 `::` | PASS |
| Safari, Bing Images, explicit search: "has been filtered", "requires a strict Bing SafeSearch setting", no images | PASS |
| Safari, DuckDuckGo Images, explicit search: "No images found" | PASS |
| Safari, google.com/safesearch: "Filtering on", "someone else … controls settings on the network" | PASS |
| Safari, Google search: Google showed its unusual-traffic check (also for a harmless search), after many scripted test requests from the same network | NOT TESTED |
| mail, maps, accounts.google.com and YouTube resolve normally, no resolver files | PASS |
| Josiah's Mac, notarized 0.1.2 DMG (SHA-256 b4706e5d…), Safari, Google Images, explicit search: no explicit nudity; suggestive results (lingerie, implied nudity, art, medical drawings) still shown. This is the limit of Google's SafeSearch | PASS |
| VM restart: block, files and SafeSearch rows stay | PASS |

Tests: 148 pass, 12 of them new SafeSearch tests (rows, resolver files,
repair of edited rows and deleted files, the block wins over a redirect,
removal at the end and at uninstall, bad addresses refused, default on).
