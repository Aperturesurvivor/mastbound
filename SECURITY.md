# Security policy

Mastbound for macOS contains a root launch daemon. Treat the
following as repository-wide security invariants:

1. The root daemon must never fetch network content or execute a shell.
2. Unprivileged configuration must be a regular file owned by the configured
   user, not writable by group or others, bounded in size, and strictly parsed.
3. Domain and endpoint strings must never reach a privileged file or process
   invocation before grammar validation.
4. `/etc/hosts` edits must be atomic and modify only the exact managed marker
   section while preserving unrelated content and metadata.
5. PF changes must remain inside `com.apple/ScreenTimeRoasterMac`; the global
   ruleset must never be flushed or replaced.
6. Installer and uninstaller targets must be fixed absolute paths, must reject
   symlink or non-regular-file substitutions, and must remove enforcement
   before removing the helper.
7. A failed or malformed list update must preserve the last validated cache.
8. Once permanent protection is locked, unprivileged cache or configuration
   changes must not remove previously accepted domains.
9. Public release is blocked until tests, real-machine install/uninstall, and
   a repository security scan pass.
10. Network blocklist inputs must use the fixed HTTPS host and a reviewed,
    immutable upstream revision; advancing that revision requires a security
    review.
11. App-bundle verification and helper extraction must occur only in a
    root-owned directory that is not writable by group or others.
12. Internal enforcement state containing domains, endpoints, or PF tokens
    must be root-readable only; user-visible status must not expose it.
13. The unprivileged Codex fetch lane must accept only normalized HTTPS URLs on
    the scheduled domain allowlist, disable curl configuration and proxy
    inheritance, refuse redirect following, and never modify blocker state.

Report suspected vulnerabilities privately through a
[GitHub security advisory](https://github.com/Aperturesurvivor/Screen-Time-Roaster/security/advisories/new).
