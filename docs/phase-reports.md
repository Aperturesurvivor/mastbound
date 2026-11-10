# Phase reports

One short report per phase of `docs/rewrite-plan.md`, for Josiah's review gate.

## P1 Core — 2026-11-10

Commit `6db671c` on `rewrite`. CI run 42907245774 passed (69 tests: 52 new,
17 legacy).

### What changed

`Sources/MastboundCore/` (no root, no real system files):

| File | Content |
| --- | --- |
| `Commitment.swift` | `EngineState` with phases `idle`, `active`, `recovering`. Pure transitions: `starting`, `extending`, `requestingRecovery`, `cancellingRecovery`, `ticked`. Every transition first credits elapsed time. State encode/decode with validation. `Enforcement.blockedDomains`. |
| `Clock.swift` | `ClockReading`, `TimeCredit` (I6), `SystemClock` (`mach_continuous_time` + `kern.bootsessionuuid`). |
| `Blocklist.swift` | Canonical list format and pinned SHA-256 check (I12). Upstream hosts-source reader for the list build script. |
| `HostsSection.swift` | Ported from `HostsFileEditor` with new `MASTBOUND` markers. |
| `DomainValidator.swift` | Ported. |
| `FileStore.swift` | Ported from `SecureFileIO`, with three fixes: checks the opened file (not the path), random temp name (a crash can no longer block later writes), and folder `fsync` after rename. |

### Design changes against the plan

- **Time credit is simpler.** In one boot only monotonic time counts; the
  wall clock is ignored. The plan's `min(w, m + slack)` rule was not needed.
- **Recovery delay counts credited time,** not wall time, so a clock change
  cannot skip the 24-hour wait.
- **Lists are merged during a commitment.** `Enforcement.blockedDomains`
  blocks the union of all given lists, so a later build can add domains to an
  active commitment but never remove them.
- **No `expired` phase.** At the end the state returns to `idle` and keeps a
  `lastEnd` record (`completed` or `recovered`).

### Invariant coverage

| ID | Tests (search the test names for the ID) |
| --- | --- |
| I1 | union of lists, idle blocks nothing, 80,000-domain hosts render |
| I2 | extend adds; zero/negative/NaN refused; property test |
| I3 | `canUninstall` only when idle; property test |
| I4 | damaged hosts markers refused; damaged state JSON refused |
| I6 | forward/back jumps ignored in one boot; recovery delay not skipped; property test with random clock changes |
| I7 | reboot credits wall time; clock back across reboot credits 0; state round trip |
| I9 | state round trip (file side is P2) |
| I10 | other lines kept; removal restores the file; legacy Roaster section untouched |
| I11 | atomic write; failed write keeps old file; no temp files left |
| I12 | canonical parse; wrong hash refused; non-canonical refused |
| I5, I8 | not testable in the core; daemon and install work in P2/P3 |

### How the tests were checked

Four bugs were added on purpose, one at a time:

| Bug added | Tests failed? |
| --- | --- |
| Trust the wall clock in the same boot | yes |
| Allow a negative extension | yes |
| Block nothing while recovering | yes |
| Skip the folder `fsync` | **no** |

The folder `fsync` cannot be seen without a power cut. It stays covered only
by code review.

### Not done or not tested

- The real list file and `script/make-list.sh` are not made yet (P2).
- `Paths`, the daemon loop, `mastboundctl` and the launchd plist are P2.
- The legacy targets still build and their 17 tests still pass; they are
  removed in P4.
- Time credit across a reboot trusts the wall clock (documented limit).

## P2 Daemon and command tool — 2026-11-10

Commit `074f355` on `rewrite`. CI run 42909361462 passed (97 tests: 28 new
integration tests, 52 core, 17 legacy). The full suite also passed 3 times
in a row locally.

### What changed

| Part | Content |
| --- | --- |
| `Engine.swift` | All daemon and command logic against a `Paths` value. One `flock` around every read-change-write. State is written before `/etc/hosts`. |
| `EngineCache.swift` | Skips unchanged work. A normal tick with the full list: **0.3 ms** (was 1.5 s). The first tick after a start parses both lists once: 1.4 s locally, 2.8 s in CI. |
| `Installer.swift` | Copies `mastboundd`, `mastboundctl` and the list to `/Library/PrivilegedHelperTools/Mastbound/`, writes the plist. Checks the list hash and Mach-O headers before it changes anything. Never touches the state (I9). |
| `Paths.swift` | Real layout, and a test layout under a temp folder. |
| `mastboundd` | Root loop, every 5 s. Logs to the unified log (`com.josiahwilson.mastbound`), the same error at most once a minute. |
| `mastboundctl` | `status`, `install`, `start`, `extend`, `recover`, `uninstall`. `uninstall` checks first, so a refused uninstall never stops the daemon. |
| `Resources/adult-domains.txt` | Built by `script/make-list.sh`. **Same 76,744 domains and SHA-256 as the old reviewed snapshot**, so the new parser agrees with the old one. |

### Design decisions made in P2

- **A missing state file with a block in place is damage, not idle.** The
  block stays (fail closed). SelfControl does the opposite.
- **Two lists, union.** The list copied at start (`locked-list.txt`, hash in
  the state) and the installed list are both blocked if valid. One may be
  missing or changed and the block still holds.
- **The state is saved once a minute, not every tick.** No credit is lost:
  credit is always measured from the last saved reading.
- `mastboundctl install` was added to the §4.4 command list (upgrade without
  a new commitment).

### Bugs added on purpose to check the tests

| Bug added | Caught? |
| --- | --- |
| No file lock | **First no.** The race test did not make the daemon write. Fixed the test; now caught 3 of 3 runs. |
| Missing state treated as idle | yes |
| Cache never rechecks `/etc/hosts` | yes |
| Installer skips the list hash | yes |
| Uninstall skips the commitment check | yes |
| Locked list ignored | yes |

### What the integration tests cannot cover (P3 must test on a real Mac)

- Root: tests run as a normal user, so root ownership and `0600 root` files
  are not exercised.
- launchd: `RunAtLoad`, `KeepAlive`, restart after a kill, `bootout` and
  `bootstrap`.
- A real reboot (new `kern.bootsessionuuid`) and sleep/wake with
  `mach_continuous_time`.
- The real `/etc/hosts`, DNS cache flush, and browsers (Safari, Chrome,
  Firefox with DNS-over-HTTPS, iCloud Private Relay).
- Deleting the app (I8) and a power cut (folder `fsync`).
- `mastboundctl` itself: argument parsing and install-from-folder have no
  automated tests.

### Risks found, not fixed

- **Root runs code from the build folder.** `mastboundctl install` copies
  `mastboundd` from the folder `mastboundctl` runs in. If that folder is
  writable by a normal user (for example an app in `~/Downloads`), other
  software could replace `mastboundd` before the admin runs the command. The
  old installer bound the admin prompt to a code-signature hash. Fix with
  code signing in P5, or check that the source folder is root-owned.
- The full MIT license notices of the list sources are not in the bundle yet
  (P5).
