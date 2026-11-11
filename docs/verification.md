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
| Reboot keeps the block; time off is counted | Runner cannot reboot | VM: start, `sudo shutdown -r now`, check status and credit |
| Hard power-off mid-write | Needs a VM to cut power | VM: stop the VM process during a tick, boot, check state is valid |
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
