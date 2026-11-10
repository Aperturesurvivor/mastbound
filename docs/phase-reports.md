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
