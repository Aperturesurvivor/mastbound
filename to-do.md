# Mastbound to-do

Status: active. Fresh rewrite of the core, then verification. Josiah designs and builds the UI himself, working with AI tools such as Claude Code. Agents must not build or ship UI without his review.

- [x] Inspect current implementation and define precise invariants, state transitions, intended duration, blocklist handling, extension, restart and deletion behavior, and explicit recovery boundary. See [docs/commitment-invariants.md](docs/commitment-invariants.md); decisions D1–D5 are open.
- [x] Study SelfControl's design and write the rewrite plan. See [docs/rewrite-plan.md](docs/rewrite-plan.md). Independent MIT implementation; do not copy SelfControl's GPL code.
- [x] Rewrite the core to the minimum needed for the commitment goal, following the plan's phases P0–P4 with a review gate after each. Remove the existing UI and out-of-scope features.
- [ ] Apply P-stack-style verification: independently inspect assumptions, write meaningful tests for key invariants and adverse cases, and verify actual system behavior rather than relying solely on success messages. Cover reboot, application deletion, clock changes, upgrades, expiry, extension, failed writes, and safe recovery where feasible. Document untested conditions and limits.
- [ ] Research Apple App Store and independent Mac distribution requirements, including signing, notarization and DMG options; do not assume App Store acceptance or rejection.
- [ ] Once core evidence is ready, hand off to Josiah to build a minimal one-screen setup for choosing a commitment duration and starting it, with a later countdown and possible extension.
- [ ] Determine portfolio artifact after concrete results exist.
