# Screen Time Roaster for macOS

<img src="Assets/AppIcon-1024.png" alt="Screen Time Roaster app icon" width="128">

A local-only macOS blocker with recurring schedules and a permanent
adult-content protection list. It is the Mac companion to the iPhone Screen
Time Roaster project.

## Current state

This repository is under local safety validation and is not yet a supported
public release. The implementation has no package dependencies. Normal browser
traffic is never observed; the optional Codex tool lane sends only its explicit
fetches and DNS lookups to the requested service and configured DNS-over-HTTPS
resolver.

## Architecture

- `RoasterMac`: SwiftUI configuration and status app.
- `RoasterEnforcer`: minimal root launch daemon. It never accesses the network.
- `RoasterBlocklist`: unprivileged adult-list downloader and validator.
- `RoasterInstaller`: administrator-authorized, fixed-path installer and
  uninstaller.
- `RoasterToolFetch`: a narrow Codex-only HTTPS fetch lane for domains that the
  evening schedule blocks locally.
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

The hosts file is system-wide, so it cannot distinguish Safari from a local
Codex subprocess. `RoasterToolFetch` provides that distinction without weakening
the browser block. It runs only when an ancestor belongs to OpenAI's signed
Codex app, accepts only HTTPS URLs on the exact scheduled social domains, and
does not accept cookies, uploads, custom curl flags, or cross-site redirects.
It uses Cloudflare DNS-over-HTTPS for the requested hostname; the root service
and normal browsing never use that lane.

From a Codex tool process:

```sh
roaster-tool-fetch 'https://www.youtube.com/watch?v=example'
```

The install script links that command into `~/.local/bin`, which Codex includes
in its command path. Direct browser and terminal requests remain blocked.

## Build and run

```sh
./script/build_and_run.sh --verify
./script/test.sh
```

The build script stages and ad-hoc signs `dist/Screen Time Roaster.app`.
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
- The optional tool lane is unprivileged, read-only, domain-scoped, and never
  changes enforcement state. Its ancestry check is deliberate habit friction,
  not a security boundary against the logged-in user.
- Uninstall clears both owned enforcement surfaces before removing the daemon.

See [SECURITY.md](SECURITY.md) for the privileged-boundary policy.
