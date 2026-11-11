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
9. Public release is blocked until the open checks in
   `docs/verification.md` pass and the install source is protected (known
   risk: `mastboundctl install` copies `mastboundd` from its own folder,
   which may be user-writable; fix with code signing or a root-owned source
   check).

Report suspected vulnerabilities privately through a
[GitHub security advisory](https://github.com/Aperturesurvivor/Screen-Time-Roaster/security/advisories/new).
