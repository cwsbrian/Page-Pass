# Product Screenshot Guide

This directory is reserved for reviewed product screenshots. Do not copy private test captures or fabricate interface images.

## Recommended Captures

| Filename | UI state | Suggested caption | Suggested alt text |
| -------- | -------- | ----------------- | ------------------ |
| `role-selection.png` | Initial role chooser | Choose the parent or child experience for this installation. | PagePass screen with Parent and Child role options. |
| `parent-family-dashboard.png` | Parent family list with synthetic child data | View child profiles, connected-device state, and Earned Time balance. | Parent dashboard listing synthetic child profiles and balances. |
| `child-connection.png` | Child connection choices before pairing | Connect a child device by QR scan or numeric fallback. | Child setup screen offering QR scan and six-digit connection options. |
| `child-policy-setup.png` | Screen Time authorization and local policy setup | Authorize Screen Time and choose apps used during Earned Time. | Child Screen Time setup showing authorization and app-selection controls. |
| `child-earned-time.png` | Paired child with canonical balance and locked state | Sync earned credit and deliberately start an Earned Time session. | Child dashboard showing a synthetic balance and locked session status. |
| `earned-time-active.png` | Active session with remaining time | Track a wall-clock Earned Time session and stop it early when needed. | Active Earned Time screen with a countdown, progress bar, and Stop button. |

The parent pairing sheet is visually useful but contains an active QR payload and numeric code. If it is included, use a dedicated non-production environment, allow the proof to expire, fully obscure both representations, and save it as `pairing-options-redacted.png`.

## Capture Dimensions and Format

- Prefer lossless PNG for interface screenshots.
- Capture at the simulator or device's native scale; for portrait images, use at least 1179 pixels of width when available.
- Keep a consistent iPhone model, display scale, appearance, locale, text size, and status-bar treatment across the set.
- Use the full portrait frame for setup screens. Crop only when the surrounding device frame adds no context.
- Keep source captures outside the public repository; commit only the reviewed export.
- Optimize final files for web delivery after removing metadata, but do not resize text until it becomes hard to read.

## Best Explanatory States

1. **Role selection** establishes that the same native app supports parent and child experiences.
2. **Parent family dashboard** shows the account-to-child relationship and canonical balance without revealing technical internals.
3. **Child policy setup** shows the Apple Screen Time dependency and deliberate app selection.
4. **Locked child dashboard** communicates the default restrictive state and available credit.
5. **Active session** demonstrates the central wall-clock control loop and manual-stop affordance.

Use synthetic balances and generic names. Do not imply that reading reports, OCR, AI review, or notifications are available by showing mock screens for those planned features.

## Required Redaction Review

Remove or replace all:

- real parent or child names, emails, profile information, and handwritten content;
- device names, installation identifiers, Apple account details, and notification previews;
- server URLs, IP addresses, ports, environment values, and debug-only controls;
- QR payloads, pairing codes, session tokens, credentials, or other connection material;
- bundle, app-group, developer-team, account, project, database, and organization identifiers;
- real app selections that reveal personal usage, unless intentionally approved for publication;
- crash banners, logs, internal error details, timestamps tied to private testing, and unreleased version information;
- image metadata, including EXIF location, device, author, and creation details.

After redaction, inspect the image at 100% zoom. Cropping is preferable to blur when the private element is not needed to explain the product.

## Publication Check

- Confirm each image matches a currently implemented screen.
- Confirm the synthetic demo account cannot access production data.
- Confirm no live connection material remains valid.
- Confirm captions and alt text describe what is visible without making unsupported product claims.
- Confirm every image is referenced with a relative path from the main README.
