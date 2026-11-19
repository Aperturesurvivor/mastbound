# Mastbound commitment: current behavior and target invariants

Status: historical. Written 2026-11-10 from commit `7c36c79`, before the
rewrite. For the current design see the README, `SECURITY.md` and
`docs/verification.md`. Items marked
**DECISION** need Josiah's choice before step 2.

## 1. What the code does now

Mastbound has three moving parts:

| Part | Location | Runs as | Job |
| --- | --- | --- | --- |
| App (`RoasterMac`) | `/Applications/Mastbound.app` | user | Edits `config.json`, downloads the list, calls the installer. |
| Enforcer (`RoasterEnforcer`) | `/Library/PrivilegedHelperTools/RoasterEnforcer`, started by a launch daemon with `RunAtLoad` + `KeepAlive` | root | Every 15 s, reads the user config and root state, then rewrites one marked section of `/etc/hosts` (and, for IP rules, one PF anchor). |
| Installer (`RoasterInstaller`) | inside the app bundle | root, through an admin password prompt | `install` copies the helper and plist and starts the daemon. `uninstall` runs `RoasterEnforcer --clear`, which removes all blocks. |

The block itself is the managed section of `/etc/hosts`. It stays on disk
through app quit, reboot and daemon failure. The daemon only reconciles it.

### Two block types exist. Neither is a fixed-term commitment.

1. **Scheduled rules** (`Models.swift`, `ScheduleEvaluator.swift`). Daily
   time windows, default 22:00–07:00 for social media. Once a window starts,
   its end time (`activeUntil`) is saved in root state and the rule cannot be
   shortened or removed until that time (`EnforcementPolicy.swift:19`, `:48`).
2. **Permanent protection** (`EnforcementPolicy.swift:52-61`). When enabled
   once, `permanentProtectionLocked` becomes `true` in root state and no
   config change can turn it off. It has **no end date**. The allowlist is
   frozen at lock time.

### Current state of this Mac (read-only check, 2026-11-10)

- Daemon is running (`launchctl` state `running`, never exited).
- `/etc/hosts` holds the managed section with 76,744 domains (two lines
  each, lines 11–153501).
- User config has permanent protection enabled plus the social-media rule.
- Enforcer logs show no errors in the last 2 hours.
- `/var/db/ScreenTimeRoasterMac/state.json` is root-only, so it was not read.

## 2. Gaps against `scope.md`

| # | Scope says | Code does | Where |
| --- | --- | --- | --- |
| G1 | User chooses a fixed duration. Block lasts until its end. | No duration exists. Permanent protection never ends; schedules are daily. | `Models.swift` |
| G2 | No ordinary early-unblock control. | One admin password removes everything at any time: the UI "Remove enforcement" button and `script/uninstall.sh`. Uninstall has no date check. | `ContentView.swift:144`, `RoasterInstallerCommand.swift:112-140`, `RoasterEnforcerCommand.swift:86` |
| G3 | Ships with a default list; user does not compile it. | The list is **downloaded** from `raw.githubusercontent.com` before install, and install refuses to start without it. Only one pinned snapshot (76,744 domains, fixed SHA-256) is accepted. | `AppModel.swift:69`, `AdultBlocklist.swift:4-20`, `AdultBlocklistDownloader.swift` |
| G4 | Countdown and add-time later. | No end time, so no countdown or extension. | — |
| G5 | Clear recovery boundary. | Recovery and early removal are the same action (G2). | — |
| G6 | Core only. | Extra features not in scope: social-media schedules, Jellyfin/PF IP rules, the Codex social-media fetch tool (`RoasterToolFetch`). | see §6 |

## 3. Target model

One commitment record in root state:

```
Commitment {
  startedAt:  Date      // wall clock at start
  endsAt:     Date      // wall clock end; only ever moves later
  creditedSeconds: Int  // time the daemon has accepted as passed (see I6)
  listSHA256: String    // list that was locked in
}
```

States and transitions:

```
          start(duration)                 now ≥ endsAt and
 NONE ───────────────────────► ACTIVE ─── credited ≥ duration ───► EXPIRED ──► NONE
                                │  ▲                                (blocks removed)
                     extend(d)  └──┘

                                ACTIVE ── recovery (§5) ──► NONE
```

- `start` is allowed only in `NONE`. It needs one admin password (installs
  the daemon).
- `extend` is allowed only in `ACTIVE`. It adds time and never subtracts.
- No other transition out of `ACTIVE` exists in normal use.

## 4. Invariants

Each invariant must get at least one test in step 3.

| ID | Invariant |
| --- | --- |
| I1 | While `ACTIVE`, every domain in the locked list is in the managed `/etc/hosts` section after each reconcile that succeeds. |
| I2 | `endsAt` never decreases. A config or request with an earlier end is ignored. |
| I3 | While `ACTIVE`, the installer's `uninstall` refuses to clear blocks, and the app shows no unblock control. Only the recovery path (§5) clears early. |
| I4 | Any read, parse or write failure leaves the current `/etc/hosts` section unchanged (fail closed). This is already true: `RoasterEnforcerCommand.swift:79`. |
| I5 | Deleting or editing user-owned files (`~/Library/Application Support/ScreenTimeRoasterMac/*`) cannot end or shorten an active commitment. Commitment data lives only in root state. |
| I6 | A wall-clock jump forward observed while the daemon runs is not credited. Between two ticks, credited time grows by at most the monotonic time passed plus a small slack. The commitment ends only when both `now ≥ endsAt` and `creditedSeconds ≥ duration`. **DECISION D2.** |
| I7 | Reboot does not end or reset the commitment. Root state and `/etc/hosts` survive reboot; the daemon restarts by itself. |
| I8 | Deleting `/Applications/Mastbound.app` does not stop enforcement. The daemon runs from `/Library/PrivilegedHelperTools`, not the app. |
| I9 | Installing a new build (upgrade) keeps the existing commitment and `endsAt`. |
| I10 | At expiry the daemon removes only its own section of `/etc/hosts` and leaves other lines unchanged. **DECISION D3.** |
| I11 | Every write is atomic (temp file, `fsync`, `rename`). A crash mid-write leaves either the old or the new file. |
| I12 | The locked list is in the app bundle; no network access is needed to start. |

## 5. Recovery boundary

What the code can and cannot do. These limits must be in the README in plain
words.

- **An administrator can always remove the block.** For example:
  `sudo launchctl bootout system/com.josiahwilson.screentimeroastermac.enforcer`
  then edit `/etc/hosts`. Mastbound cannot stop this and must not claim to.
- macOS Recovery can edit `/etc/hosts` on the startup disk.
- Changing the system clock needs an admin password on macOS. I6 limits
  this while the daemon runs; it cannot limit a clock change made from
  Recovery while the Mac is off.
- `/etc/hosts` blocks exact names only. It does not block subdomains not in
  the list, IP addresses, VPNs, remote proxies, or browsers that skip the
  system resolver. Which browsers skip it is **untested** (§7).

Proposed explicit recovery path (**DECISION D1**): a separate root command,
not in the app UI, for example `RoasterInstaller recover`. It needs the admin
password, prints the remaining time, needs a typed confirmation phrase, then
waits a fixed delay (for example 24 h) before it clears. This gives a safe
way out for real problems (wrong site blocked, Mac transfer) without a
one-click unblock.

## 6. Removal candidates for step 2 (all removed in P4)

These do not serve the commitment goal. Removal also removes test burden.

| Item | Files | Note |
| --- | --- | --- |
| Scheduled social-media rules | `ScheduleEvaluator.swift`, schedule parts of `Models.swift`, `EnforcementPolicy.swift` | Live on this Mac now; removal changes current behavior. |
| PF / IP endpoint rules (Jellyfin) | `PFController.swift`, `PFRuleRenderer.swift`, `TargetValidator.swift` | PF token handling has an untested reboot path (§7). |
| Codex fetch lane | `RoasterToolFetch`, `ToolAccessPolicy.swift`, `~/.local/bin/mastbound-tool-fetch` | Only exists to bypass the social schedule for Codex. |
| Network downloader | `AdultBlocklistDownloader.swift`, `RoasterBlocklist` | Replace with a bundled list file (G3). Keep the parser and SHA check. |
| Current UI | `ContentView.swift`, most of `AppModel.swift` | Josiah builds the new UI. Keep a small test harness to start, extend and read state. |

## 7. Not tested / unknown

- **The tests cannot run on this Mac.** `swift test` fails with
  `no such module 'Testing'`: only Command Line Tools are installed
  (`xcode-select -p` = `/Library/Developer/CommandLineTools`). Full Xcode is
  necessary. `swift build` works.
- Existing tests cover domain checks, hosts editing, schedule math and the
  permanent lock. None cover reboot, uninstall, clock changes, upgrade,
  failed writes or the daemon loop. No test covers the installer.
- Suspected issue, not confirmed: PF reference tokens do not survive reboot.
  If state keeps an old token, `pf.release` at `RoasterEnforcerCommand.swift:160`
  may fail on every tick. Hosts are written before that line, so domain
  blocking would continue, but the loop would log errors forever. Only
  matters while IP rules exist.
- `writeAtomically` calls `fsync` on the file but not on its directory, so a
  power cut right after `rename` may lose the rename. Low risk; note for I11.
- Browser behavior with `/etc/hosts` under DNS-over-HTTPS, iCloud Private
  Relay and VPNs: not tested.
- Effect of 153,000 hosts lines on resolver speed: not measured. It works
  on this Mac now.
- If the user deletes `config.json`, the daemon fails closed every tick and
  `/etc/hosts` stays frozen. Good for a commitment, but it also freezes
  expiry. The target model must not need user files to expire (I5).

## 8. Decisions for Josiah

- **D1 Recovery:** delayed admin `recover` command (recommended), or no
  recovery other than the manual admin steps in §5.
- **D2 Clock:** credit only monotonic time while running (recommended, I6),
  or trust the wall clock.
- **D3 Expiry:** remove blocks automatically at the end (recommended), or keep
  them until the user removes them.
- **D4 Maximum duration:** for example 1 year, or no limit.
- **D5 Migration of this Mac:** this Mac has permanent protection locked
  now. Decide if the new build converts it to a commitment with an end date,
  keeps it permanent, or needs a manual uninstall first.
