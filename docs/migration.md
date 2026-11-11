# Migration from the old Screen Time Roaster build (D5)

Status: plan for Josiah's review, 2026-11-11. Nothing on the main Mac was
changed. Do not do these steps until P3 is complete and Josiah approves.

## What is installed on the main Mac now

Checked read-only on 2026-11-11:

| Item | Path |
| --- | --- |
| Old app | `/Applications/Mastbound.app` (contains `RoasterInstaller`, `RoasterEnforcer`, `RoasterBlocklist`, `RoasterToolFetch`) |
| Root service | `/Library/PrivilegedHelperTools/RoasterEnforcer` |
| `launchd` job | `/Library/LaunchDaemons/com.josiahwilson.screentimeroastermac.enforcer.plist` |
| Root state | `/var/db/ScreenTimeRoasterMac/` (`state.json`, `adult-domains.txt`) |
| User files | `~/Library/Application Support/ScreenTimeRoasterMac/` |
| Hosts | `/etc/hosts` lines 11–153,501: `# BEGIN SCREEN TIME ROASTER MAC — MANAGED BLOCK` |
| PF anchor | `com.apple/ScreenTimeRoasterMac` (IP rules, if any) |
| Command links | `~/.local/bin/mastbound-tool-fetch`, `~/.local/bin/roaster-tool-fetch` |

Permanent adult protection is locked. The old uninstaller can still remove
it with the admin password: `RoasterInstaller uninstall` stops the job, runs
`RoasterEnforcer --clear` (removes the hosts section and the PF anchor), then
removes the helper and the plist.

The old code is no longer on the `rewrite` branch. It is still on `main`
and in git history.

## Decision: start the new block first, then uninstall the old build

The other option was to convert the old permanent lock into a new
commitment. That needs code that reads the old root state and is used once.
This plan needs no new code.

The two builds use different marker sections in `/etc/hosts`, different
`launchd` labels and different folders. The new code leaves the old section
unchanged (test "I10: the legacy Screen Time Roaster section is left
unchanged"). So the new block can start while the old one is still on, and
there is no time with no block.

## Steps

1. Build the new tool on the `rewrite` branch: `./script/build-cli.sh`.
2. Copy it to a root-owned folder (see the install-source risk in
   `SECURITY.md`):
   - `sudo cp -R dist/mastbound /usr/local/mastbound-install`
   - `sudo chown -R root:wheel /usr/local/mastbound-install`
   - `sudo chmod -R go-w /usr/local/mastbound-install`
3. Choose the commitment length.
4. Start the new commitment: `sudo /usr/local/mastbound-install/mastboundctl start --days N`.
5. Check: `mastboundctl status` shows `active`, and
   `grep -c "BEGIN MASTBOUND" /etc/hosts` prints `1`.
6. Uninstall the old build: `sudo /Applications/Mastbound.app/Contents/Resources/RoasterInstaller uninstall`.
7. Check:
   - `grep -c "SCREEN TIME ROASTER" /etc/hosts` prints `0`.
   - `grep -c "BEGIN MASTBOUND" /etc/hosts` still prints `1`.
   - `sudo launchctl print system/com.josiahwilson.screentimeroastermac.enforcer` fails.
   - `sudo pfctl -a com.apple/ScreenTimeRoasterMac -sr` prints no rules.
8. Remove the old command links: `rm ~/.local/bin/mastbound-tool-fetch ~/.local/bin/roaster-tool-fetch`.
9. Remove the old app and data: `/Applications/Mastbound.app`,
   `/var/db/ScreenTimeRoasterMac/` and
   `~/Library/Application Support/ScreenTimeRoasterMac/`. The new app will
   later use the name `/Applications/Mastbound.app`.

## Not checked

- The old uninstaller was not run for this plan, because that would remove
  the live block. Step 6 is its first run on this Mac in this work.
- That the old `--clear` removes only its own hosts section is read from the
  old code, not tested. Step 7 checks it. If the `MASTBOUND` section is gone
  after step 6, the new daemon puts it back within 5 seconds.
- If step 6 fails with "Enforcement is incomplete", the old helper or plist
  is damaged. Stop and look at it before any manual removal.
