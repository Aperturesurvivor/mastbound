# Security policy

Mastbound for macOS contains a root launch daemon. Treat the following as
repository-wide security rules:

1. The root daemon and `mastboundctl` must never fetch network content or
   execute a shell. The only child processes are fixed absolute paths
   (`/bin/launchctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall`).
2. All system paths come from one `Paths` value. Root files are read with
   `O_NOFOLLOW` and checked for type, owner, mode and size after opening.
3. Every domain is validated before it reaches `/etc/hosts`.
4. `/etc/hosts` edits are atomic (random temp file, `fsync`, `rename`, folder
   `fsync`) and change only the exact `MASTBOUND` marker section. Damaged
   markers stop the write.
5. The state file is root-owned, mode `0600`. Only `status.json` (phase and
   end date) is readable by other users.
6. A missing, damaged or unreadable state or list keeps the current block
   (fail closed).
7. The shipped list is checked against a pinned SHA-256 before install and
   each time the daemon sees the file change. Changing the list is a code-review action.
8. The installer refuses source files that are not Mach-O executables, and
   refuses target folders that other users can write.
9. The install source folder, every folder above it, and its files must be
   owned by root and not writable by other users, because root copies and
   runs `mastboundd` from it (`Installer.requireTrustedSource`).
10. `/Library/Application Support/Mastbound/requests/` is root-owned, mode
    `1777`. Any user may create `cancel-recovery` there. The daemon only
    checks that the name exists and `unlink`s it; it never opens or follows
    it. The request can only cancel an early end (an open app flow or the
    72-hour wait), which keeps the block on.
11. The 1-hour minimum of the app's early-end flow is checked by the root
    daemon from credited time (`EngineState.finishingQuit`), never by the
    app. The app's puzzles are friction only.
12. Public release is blocked until the open checks in
    `docs/verification.md` pass.

Report suspected vulnerabilities privately through a
[GitHub security advisory](https://github.com/Aperturesurvivor/mastbound/security/advisories/new).
