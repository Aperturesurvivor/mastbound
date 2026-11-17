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

`mastbound-base` was deleted on 2026-11-16 to free 24 GB. To make it again:
`tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest mastbound-base`,
start it once, and run `ssh-copy-id -i ~/.ssh/mastbound_vm admin@$(tart ip mastbound-base)`.

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
