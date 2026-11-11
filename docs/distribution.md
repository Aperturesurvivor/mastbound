# Distribution decision note (P5)

Status: for Josiah's review, 2026-11-11. Research only; nothing was
published, signed or paid for.

## Summary

| Question | Answer |
| --- | --- |
| Mac App Store? | **No.** Mastbound needs root, a launch daemon and `/etc/hosts` edits. Guideline 2.4.5 forbids those. |
| How to ship? | A Developer ID-signed, notarized **DMG** from GitHub Releases. Needs the Apple Developer Program, $99 a year. |
| Without paying? | Source build only (`script/build-cli.sh`), for people who can build it. A downloaded unsigned app is blocked by Gatekeeper; users must allow it in System Settings → Privacy & Security. Do not ask normal users to do that. |
| `SMAppService`? | **No, not for the block itself.** It runs the daemon from inside the app bundle, so deleting the app would stop the block (breaks I8). Keep the current design: root copies the helper to `/Library/PrivilegedHelperTools/Mastbound/` and writes the plist. |
| Admin prompt from the app | The app stages its Resources folder into a root-owned folder, then runs `mastboundctl` from there with one admin prompt. Done in P6 with Josiah. |

## 1. Mac App Store

App Review Guidelines 2.4.5, Mac App Store apps
([source](https://developer.apple.com/app-store/review/guidelines/)):

- (i) "They must be appropriately sandboxed". A sandboxed app cannot edit
  `/etc/hosts`.
- (ii) Apps "cannot install code or resources in shared locations".
  Mastbound installs into `/Library/PrivilegedHelperTools` and
  `/Library/LaunchDaemons`.
- (v) "They may not request escalation to root privileges".

All three apply. The App Store is not possible for this design. A version
built on Apple's Screen Time API is a different product and not in scope.

## 2. Developer ID and notarization

[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution):

- Software "distributed with Developer ID must be notarized".
- Sign with a "Developer ID" application (or installer) certificate.
- "Enable the Hardened Runtime capability for your app and command line
  targets". This applies to `mastboundd` and `mastboundctl` too.
- Disk images (UDIF) and flat installer packages can be notarized.
- Mac App Store software is not notarized.

Cost: "$99 annual membership" ([Apple Developer Program](https://developer.apple.com/programs/)).
Fee waivers are only for nonprofits, schools and government bodies, not for
"an individual, sole proprietor, or single-person business"
([fee waivers](https://developer.apple.com/help/account/membership/fee-waivers)).

Since macOS 15 the Control-click way to open an unnotarized app is gone;
users must go to System Settings → Privacy & Security
([MacRumors](https://www.macrumors.com/2024/08/06/macos-sequoia-gatekeeper-security-change/),
[Eclectic Light](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)).

**Recommendation:** pay for the Developer Program before the first public
release. Until then, keep it source-only.

## 3. Daemon registration

[`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
(macOS 13+) controls "helper executables that live inside an app's main
bundle". The daemon plist must be in the app's `Contents/Library/LaunchDaemons`
([daemon(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:))),
and its program path is relative to the bundle (`BundleProgram`)
([updating helpers](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)).
An admin must approve it before it runs
([register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register())).

Because the program stays inside the app, deleting the app removes the
program. That breaks invariant I8 ("deleting the app does not stop the
block"). This is inferred from the docs, not tested.

SelfControl's older approach (`SMJobBless`) copies the helper out of the app
into `/Library/PrivilegedHelperTools`. `SMJobBless` is deprecated. Mastbound
does the same copy with its own root installer, which needs no Apple API and
works without a paid account. Keep it.

**New limit found:** since macOS 13, System Settings → General → Login Items
→ "Allow in the Background" lists launch daemons from `/Library/LaunchDaemons`,
and switching one off stops it
([Eclectic Light](https://eclecticlight.co/2023/02/15/controlling-login-and-background-items-in-ventura/),
[Michael Tsai](https://mjtsai.com/blog/2022/10/27/venturas-open-at-login-vs-allow-in-the-background)).
This is another admin way to stop the daemon, like `launchctl bootout`. Not
tested: whether it needs an admin password, and whether `/etc/hosts` keeps
the block after the switch (it should, as after `bootout`). Added to the
P3 open checks.

## 4. Install source (security fix done in P5)

`mastboundctl install` copies `mastboundd` from its own folder, and root
then runs it. Before P5 that folder could be user-writable, so other
software could replace `mastboundd` before the admin ran the command.

Fix: `Installer.requireTrustedSource` now resolves the folder and requires it
and every folder above it to be owned by root and not writable by other
users. The files must be owned by root and not group- or world-writable. A
build in a home folder, or in `/Applications` (group `admin` can write it),
is refused. The app must first copy its Resources into a root-owned folder.
4 new tests; removing the check makes 3 of them fail.

Code signing is still useful later: with a Developer ID, `mastboundctl` could
also check that `mastboundd` has the same Team ID. Not needed for the fix.

## 5. List licenses

The bundle now has `Resources/licenses/` with the license texts that could be
found. Two sources are a problem:

| Source | License (per StevenBlack metadata) | Problem | Domains only it adds |
| --- | --- | --- | --- |
| Clefspeare13 pornhosts | MIT | GitHub blocked the repo ("Repository access blocked", ToS). The license text and copyright holder cannot be read. | about 13,300 |
| brijrajparmar27 | CC BY 4.0 | The repo has no license file. | about 160 |

Counts are from the raw source files at the pinned revision, before
validation. MIT and CC BY 4.0 both need the notice or credit to ship with
the list. **Decision for Josiah (D6):** (a) keep both and rely on
StevenBlack's metadata, or (b) drop both from `script/make-list.sh`, which
removes about 13,500 domains and changes the list hash. (b) is the safe legal
choice; ask a lawyer if the list matters more.

## 6. Not done

- No Developer ID account, so no signing or notarization was tried.
- No DMG script. Write it after the app exists (P6).
- The "Allow in the Background" switch is not tested.
- A Homebrew cask was not researched.
