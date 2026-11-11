# Mastbound for macOS

<img src="Assets/AppIcon-1024.png" alt="Mastbound app icon" width="128">

Mastbound is a free, open-source commitment blocker for the Mac. It ships
with a list of adult websites. You choose how long the block lasts, from one
hour to one year. The block then stays on until that time is over, even if
you quit or delete the app or restart the Mac. There is no button to end it
early.

Mastbound makes the block hard to undo on impulse. **It cannot make the block
impossible to undo.** An administrator of a Mac can always remove it. Read
[What Mastbound cannot do](#what-mastbound-cannot-do) before you use it.

## Status

Pre-release. There is no app yet, only a command-line tool. The core is
tested (see [docs/verification.md](docs/verification.md)), but some checks
are still open: restart, power loss, sleep and wake, and real browsers. Do
not rely on it yet.

## How it works

- A small root service (`mastboundd`) runs under `launchd`. Every 5 seconds
  it makes one marked section of `/etc/hosts` match the commitment. If
  someone edits that section, the service puts it back.
- The service and its files live in root-owned folders, not inside the app.
  Deleting the app does not stop the block.
- Time is counted with the Mac's monotonic clock. Changing the date or time
  in System Settings does not shorten the commitment.
- Any error keeps the block in place. A missing or damaged state file is
  treated as damage, not as "no commitment".
- At the end of the commitment the service removes its block by itself.
- The service never uses the network and never runs a shell.

Files:

| Path | Content |
| --- | --- |
| `/Library/PrivilegedHelperTools/Mastbound/` | `mastboundd`, `mastboundctl`, the installed list |
| `/Library/Application Support/Mastbound/state.json` | Commitment state, root only |
| `/Library/Application Support/Mastbound/status.json` | Phase and end date, readable by everyone |
| `/Library/LaunchDaemons/com.josiahwilson.mastbound.plist` | The `launchd` job |
| `/etc/hosts` | One section between `# BEGIN MASTBOUND — MANAGED BLOCK` and `# END MASTBOUND — MANAGED BLOCK` |

## Commands

```
mastboundctl status
mastboundctl version
mastboundctl install
mastboundctl start  (--minutes N | --hours N | --days N)
mastboundctl extend (--minutes N | --hours N | --days N)
mastboundctl recover --confirm "I want to end my commitment early"
mastboundctl recover --cancel
mastboundctl uninstall
```

All commands except `status` and `version` need `sudo`.

- `start` installs the service if needed and starts a commitment. The
  minimum is 1 hour. The maximum is 365 days.
- `extend` adds time. It can never take time away. The time left can never
  pass 365 days.
- `uninstall` works only when no commitment is active.

### Early exit (recovery)

For real problems, such as a wrong site in the list or a Mac you must sell,
there is one slow way out:

1. Run `sudo mastboundctl recover --confirm "I want to end my commitment early"`.
2. Wait 24 hours. The block stays on during the wait.
3. After 24 hours the block ends.

You can cancel the wait with `sudo mastboundctl recover --cancel`. The 24
hours are counted the same way as the commitment, so a clock change does not
skip them. This command will not be in the app.

## What Mastbound cannot do

- **An administrator can remove the block at any time.** For example,
  `sudo launchctl bootout system/com.josiahwilson.mastbound` stops the
  service, and then `/etc/hosts` can be edited by hand. The "Allow in the
  Background" switch in System Settings → General → Login Items can also
  stop the service. Mastbound cannot stop this.
- macOS Recovery, or another Mac with the disk attached, can edit
  `/etc/hosts`.
- A clock change made while the Mac is off is accepted. After a restart the
  monotonic clock starts again from zero, so Mastbound uses the wall clock to
  count the time the Mac was off. If the clock went back, it counts 0.
- `/etc/hosts` blocks exact host names only. It does not block:
  - subdomains or sites that are not in the list,
  - IP addresses,
  - VPNs, remote proxies, Tor, or remote desktops,
  - apps or browsers that do not use the system resolver. DNS-over-HTTPS and
    iCloud Private Relay are not tested yet.
- The list is not complete and can block a site by mistake. No list can
  find every adult site.
- It does not work on iPhone or iPad.

## Build and test

Mastbound has no package dependencies. The Command Line Tools are enough;
full Xcode is not needed.

```sh
./script/test.sh
./script/build-cli.sh            # builds into dist/mastbound
```

`mastboundctl install` and `start` copy files that root will run, so they
refuse a build folder that is not root-owned. Copy the build first:

```sh
sudo cp -R dist/mastbound /usr/local/mastbound-install
sudo chown -R root:wheel /usr/local/mastbound-install
sudo chmod -R go-w /usr/local/mastbound-install
```

`script/make-list.sh` rebuilds `Resources/adult-domains.txt` from a pinned
upstream revision. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md).

**Do not run the real-system checks in `script/p3/` on a Mac you use.** They
install a block and change the clock. They refuse to run unless
`MASTBOUND_DISPOSABLE_MACHINE=1` is set.

## Documents

- [docs/commitment-invariants.md](docs/commitment-invariants.md): the rules
  the code must keep.
- [docs/rewrite-plan.md](docs/rewrite-plan.md): the design and phases.
- [docs/verification.md](docs/verification.md): what was tested on a real
  system, and what was not.
- [docs/distribution.md](docs/distribution.md): App Store, signing,
  notarization and daemon registration.
- [docs/migration.md](docs/migration.md): moving a Mac from the old Screen
  Time Roaster build.
- [SECURITY.md](SECURITY.md): security rules and how to report a problem.

## License

MIT. See [LICENSE](LICENSE). Mastbound uses ideas from
[SelfControl](https://github.com/SelfControlApp/selfcontrol), but no
SelfControl code.
