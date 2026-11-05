# Mastbound for Mac scope

## Goal

A free, open-source Mac commitment tool that ships with a default adult-site blocklist. The user chooses a fixed commitment period; the intended block continues until its end even if the app is closed, deleted, or the Mac restarts. It should be straightforward to start without the user compiling the list themselves.

## Intended interface and distribution

A single onboarding screen asks how long the user wants to quit, then starts the commitment. Later opening the app may show a countdown and allow adding time. No ordinary early-unblock control is intended. UI work belongs to Josiah after core verification. Independently distributed DMG is a possibility; research current Apple distribution, signing, notarization and App Store requirements before deciding. Do not claim the app is impossible to bypass; clearly specify recovery and limitations.

## iOS

iOS app work is out of scope for now at Josiah's direction. Do not pursue or queue iOS development unless he asks to revisit it. Focus on the Mac version.

## Evidence and open questions

The README describes a root service that persists after app closure and reboot, an adult-content list, and an administrator-authorized uninstall. It does not establish the intended fixed-term commitment behavior; this must be inspected and tested. Do not claim that the existing implementation enforces a year-long commitment or is impossible to bypass. Domain lists are incomplete and can block sites incorrectly; no filter guarantees comprehensive coverage.

Evaluate a safe, explicit recovery approach and the implications of long blocks, list updates, errors, clock changes, operating-system changes, and removal. A Mac administrator can ultimately control the device; document the actual boundaries. Compare existing free tools and determine whether the combination of local operation, a shipped list, and long fixed-term commitment fills a meaningful need.

## Portfolio

If kept active, a portfolio artifact is an end goal; determine its format after concrete work and evidence exist.

## Status

Active. First simplify and verify the core using P-stack-style verification; Josiah will then personally build the UI.
