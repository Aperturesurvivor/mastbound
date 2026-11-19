# Mastbound to-do

Status: active. 0.1.1 (first public release) and 0.1.2 (forced SafeSearch) published 2026-11-19. Josiah designs and builds the UI himself, working with AI tools such as Claude Code. Agents must not build or ship UI without his review.

- [x] Inspect current implementation and define precise invariants, state transitions, intended duration, blocklist handling, extension, restart and deletion behavior, and explicit recovery boundary. See [docs/commitment-invariants.md](docs/commitment-invariants.md); decisions D1–D5 are open.
- [x] Study SelfControl's design and write the rewrite plan. See [docs/rewrite-plan.md](docs/rewrite-plan.md). Independent MIT implementation; do not copy SelfControl's GPL code.
- [x] Rewrite the core to the minimum needed for the commitment goal, following the plan's phases P0–P4 with a review gate after each. Remove the existing UI and out-of-scope features.
- [ ] Apply P-stack-style verification: independently inspect assumptions, write meaningful tests for key invariants and adverse cases, and verify actual system behavior rather than relying solely on success messages. Cover reboot, application deletion, clock changes, upgrades, expiry, extension, failed writes, and safe recovery where feasible. Document untested conditions and limits. Done for the core, the Safari HTTPS-record fix and SafeSearch (see docs/verification.md). Still open: sleep with the lid closed on a real Mac, VPNs, iCloud Private Relay, Intel Macs.
- [x] Research Apple App Store and independent Mac distribution requirements, including signing, notarization and DMG options; do not assume App Store acceptance or rejection.
- [ ] Once core evidence is ready, hand off to Josiah to build a minimal one-screen setup for choosing a commitment duration and starting it, with a later countdown and possible extension.
- [ ] Determine portfolio artifact after concrete results exist.
- [ ] Later, optional: Safari content blocker that blocks the image tabs of Google, Bing and DuckDuckGo during a commitment (the user can turn off a Safari extension, so it is friction only).
- [ ] Later, optional: on-device image filter in Safari with Apple's SensitiveContentAnalysis (needs Apple's entitlement).
- [ ] Before each release: run `script/check-safesearch.sh` (release.sh does) and `script/make-safesearch-list.sh` now and then for new Google domains.
