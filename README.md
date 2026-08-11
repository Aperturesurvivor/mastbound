# Screen Time Roaster Mac

A local-only macOS blocker with recurring schedules and a permanent
adult-content protection list. It is the Mac companion to the iPhone Screen
Time Roaster project.

## Current state

This repository is under local safety validation and is not yet a supported
public release. The implementation has no package dependencies and does not
send browsing data anywhere.

## Architecture

- `RoasterMac`: SwiftUI configuration and status app.
- `RoasterEnforcer`: minimal root launch daemon. It never accesses the network.
- `RoasterBlocklist`: unprivileged adult-list downloader and validator.
- `RoasterInstaller`: administrator-authorized, fixed-path installer and
  uninstaller.
- `RoasterCore`: schedule, validation, policy, hosts editing, and PF rendering.

Exact domains are blocked through one clearly marked `/etc/hosts` section.
Literal IP-and-port targets are blocked through the isolated
`com.apple/ScreenTimeRoasterMac` PF anchor. Active scheduled rules are
additive-only until their original end time. Once permanent adult protection
is enabled, its root-owned snapshot is also additive-only and can be removed
only through the administrator-authorized uninstall path.

The adult-domain sources are pinned to a reviewed StevenBlack repository
revision. Updating that revision is deliberately a code-review and release
action; a routine in-app refresh cannot silently switch to newer upstream data.
Both the downloader and root service require the reviewed domain count and
SHA-256 before accepting that cache.

## Build and run

```sh
./script/build_and_run.sh --verify
swift test
```

The build script stages and ad-hoc signs `dist/Screen Time Roaster Mac.app`.
The local install flow requires an administrator prompt because enforcement
must survive app closure and reboot.

## Safety properties

- The root service accepts only strict domains and literal IP addresses.
- It executes no user-controlled shell commands and never downloads data.
- Privileged installation stages and verifies the app only in a root-owned,
  non-group-writable directory before copying the helper.
- Hosts-file edits are atomic and preserve every line outside its markers.
- PF rules are loaded into one isolated anchor; the global ruleset is not
  replaced.
- Invalid configuration preserves existing enforcement instead of rewriting
  system files from ambiguous input.
- Internal enforcement state, including private endpoints, is root-readable
  only.
- Uninstall clears both owned enforcement surfaces before removing the daemon.

See [SECURITY.md](SECURITY.md) for the privileged-boundary policy.
