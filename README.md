# Mastbound for macOS

<img src="Assets/AppIcon-1024.png" alt="Mastbound app icon" width="128">

A local-only macOS blocker with recurring schedules and a permanent
adult-content protection list. It is the Mac companion to the iPhone Mastbound
project.

## Current state

This is an early public source release for macOS 14 and later. The
implementation has no package dependencies. Normal browser traffic is never
observed; the optional Codex tool lane sends only its explicit fetches and DNS
lookups to the requested service and configured DNS-over-HTTPS resolver.

The initial public build passed 17 Swift tests, deep code-signature
verification, a real-machine install and path-migration check, launch-daemon
and permanent-block checks, and a complete security review with no reportable
findings. It is still intentionally a source-first release rather than a
notarized downloadable package.

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
mastbound-tool-fetch 'https://www.youtube.com/watch?v=example'
```

The install script links that command into `~/.local/bin`, which Codex includes
in its command path, and preserves `roaster-tool-fetch` as a compatibility
alias. Direct browser and terminal requests remain blocked.

## Build and run

```sh
./script/build_and_run.sh --verify
./script/test.sh
```

The build script stages and ad-hoc signs `dist/Mastbound.app`. Command-Q hides
the configuration interface. Even if the interface process is deliberately
terminated, the separately installed root service continues enforcing the
rules. The local install flow requires an administrator prompt because only an
administrator-authorized removal may stop enforcement, and enforcement must
survive app closure and reboot.

To install the built app and start enforcement:

```sh
./script/install.sh
```

To remove the app and its owned enforcement state:

```sh
./script/uninstall.sh
```

## Release packaging

`script/package_release.sh` creates a universal arm64 and x86_64 release app
and ZIP archive without installing or publishing either artifact. It never
selects a signing identity or notarization credentials implicitly.

For a local unsigned packaging check:

```sh
./script/package_release.sh --unsigned
```

For a Developer ID release build, pass the exact identity explicitly:

```sh
./script/package_release.sh \
  --sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --version 1.0.0 \
  --build-number 1
```

That path applies the hardened runtime and a secure timestamp, then performs a
deep strict code-signature verification. It does not contact Apple's notary
service. To notarize, first create a `notarytool` keychain profile outside this
repository, then opt in with its profile name:

```sh
./script/package_release.sh \
  --sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile "screen-time-roaster-release"
```

Only `--notary-profile` initiates notarization. The script does not accept or
store raw Apple credentials. After acceptance it staples and validates the app,
requires Gatekeeper assessment to pass, and recreates the ZIP with the stapled
bundle. Release artifacts remain under ignored `dist/release/` until a separate,
explicit publication step.

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
