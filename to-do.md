# Mastbound to-do

Status: active. Core simplification and verification first; Josiah personally designs and builds the UI afterward. Do not build the UI autonomously.

- [ ] Inspect current implementation and define precise invariants, state transitions, intended duration, blocklist handling, extension, restart and deletion behavior, and explicit recovery boundary.
- [ ] Simplify the implementation to the minimum needed for the commitment goal; remove the existing UI from the core work after assessing dependencies and preserving the ability to test safely.
- [ ] Apply P-stack-style verification: independently inspect assumptions, write meaningful tests for key invariants and adverse cases, and verify actual system behavior rather than relying solely on success messages. Cover reboot, application deletion, clock changes, upgrades, expiry, extension, failed writes, and safe recovery where feasible. Document untested conditions and limits.
- [ ] Research Apple App Store and independent Mac distribution requirements, including signing, notarization and DMG options; do not assume App Store acceptance or rejection.
- [ ] Once core evidence is ready, hand off to Josiah to build a minimal one-screen setup for choosing a commitment duration and starting it, with a later countdown and possible extension.
- [ ] Determine portfolio artifact after concrete results exist.
