# Public Release Checklist

Complete this review on the exact directory and Git commit that will be published. A clean review of the private production repository does not automatically make future screenshots, edits, or Git history safe.

## Content and Accuracy

- [ ] Confirm every implemented capability is still supported by the private repository.
- [ ] Keep planned reading reports, OCR, review decisions, AI assistance, notifications, and storage clearly labeled as planned until implemented.
- [ ] Do not add user counts, revenue, performance, availability, launch, coverage, certification, or production-scale claims without publishable evidence.
- [ ] Keep engineering responsibility language neutral unless authorship can be demonstrated publicly.
- [ ] Confirm product status wording is still accurate on the publication date.
- [ ] Confirm the minimum supported iOS version and current platform limitations.

## Secrets and Credentials

- [ ] Scan all tracked files and full Git history for API keys, passwords, tokens, signing certificates, private keys, and credential values.
- [ ] Confirm no environment files, shell history, build logs, crash reports, request captures, or local secret stores are included.
- [ ] Confirm configuration examples contain placeholders only.
- [ ] Confirm no pairing QR payloads, fallback codes, parent sessions, child-device credentials, or identity assertions appear in text or images.
- [ ] Confirm no analytics, notification, or service keys are embedded in screenshots or metadata.

## Private Infrastructure and Identifiers

- [ ] Remove private URLs, internal hostnames, local IP addresses, connection strings, ports that expose internal topology, and webhook endpoints.
- [ ] Remove bundle identifiers, application-group identifiers, developer team identifiers, signing-profile names, account identifiers, project identifiers, database identifiers, and organization identifiers.
- [ ] Do not publish exact production environment values or deployment secrets.
- [ ] Keep database diagrams generalized; exclude internal IDs, indexes, digests, credential columns, and operational rate-limit details.
- [ ] Confirm architecture diagrams do not reveal internal route names or private infrastructure providers that are not intentionally public.

## Personal and User Data

- [ ] Replace real parent and child names with clearly synthetic examples.
- [ ] Remove email addresses, Apple account information, device names, installation identifiers, and family details.
- [ ] Remove handwritten reports, book-report images, OCR output, or other child-created content unless explicit publication consent exists.
- [ ] Inspect Markdown, image alt text, captions, filenames, EXIF metadata, and social-preview assets for personal information.

## Screenshots and Media

- [ ] Capture screenshots from a dedicated public-demo build and synthetic account.
- [ ] Exclude debug-only server controls, development banners, console overlays, and internal errors.
- [ ] Do not show a live pairing QR code or numeric code; use a deliberately expired synthetic flow and fully redact the payload.
- [ ] Verify app names visible in Family Controls selections are safe to publish.
- [ ] Crop system status details if they reveal personal carrier, location, notifications, or device identity.
- [ ] Remove EXIF and other image metadata before committing.
- [ ] Add accurate captions and useful alt text for every image.
- [ ] Confirm no raw physical-device test captures or local evidence directories are copied into the showcase.

## Proprietary Material

- [ ] Confirm no production source files were copied into the public repository.
- [ ] Confirm no large or distinctive source snippets, SQL migrations, schema definitions, test fixtures, internal logs, or proprietary algorithms were pasted into documentation.
- [ ] Review evidence paths to ensure filenames alone do not disclose unreleased or confidential work.
- [ ] Remove internal planning notes, pricing, market research, roadmaps, and unreleased dates.
- [ ] Confirm third-party logos, icons, fonts, screenshots, and copy can be redistributed.

## Repository Hygiene

- [ ] Copy only the self-contained `portfolio-showcase` contents into the public repository.
- [ ] Start from a new public Git history; do not push or mirror the private repository history.
- [ ] Choose and add an explicit license after confirming the desired reuse terms.
- [ ] Add a concise repository description that identifies it as a public product and architecture showcase.
- [ ] Add a social preview image that contains no private data or unsupported claims.
- [ ] Add relevant GitHub topics such as `ios`, `swiftui`, `typescript`, `postgresql`, `parental-controls`, and `portfolio`.
- [ ] Confirm generated OS files, editor settings, and image working files are ignored.
- [ ] Run a secret scanner against the final working tree and commit history.

## Documentation Quality

- [ ] Open every relative Markdown link from the public repository root.
- [ ] Render every Mermaid block on GitHub and fix any syntax or readability issues.
- [ ] Confirm no Mermaid diagram exceeds a readable node count or exposes internal identifiers.
- [ ] Preview tables, blockquotes, headings, and mobile rendering.
- [ ] Check spelling, grammar, duplicate text, and stale status language.
- [ ] Confirm the documentation is understandable without access to the private source repository.
- [ ] Verify screenshots match the current interface and documented behavior.

## Final Manual Search

Before publishing, search case-insensitively for at least:

- [ ] `password`, `secret`, `token`, `credential`, `private key`, `authorization`
- [ ] URL schemes, IP-address patterns, database connection prefixes, and email-address patterns
- [ ] environment-file names and common key suffixes
- [ ] bundle, team, account, project, database, and organization identifier labels
- [ ] real family names, device names, and internal product codenames
- [ ] `TODO`, `TBD`, `FIXME`, `localhost`, and debug-only wording

Matches may be legitimate prose in this checklist. Review each result rather than deleting terms blindly.

## Recommended GitHub Repository Settings

- **Visibility:** Public, only after this checklist passes.
- **Issues:** Disable unless public feedback and triage are desired.
- **Discussions:** Optional; enable only with a plan to moderate and respond.
- **Wiki:** Disable unless it will be maintained separately from the versioned documentation.
- **Actions and secrets:** Do not add production deployment secrets. Disable unused workflows and restrict token permissions to the minimum required.
- **Repository description:** Use a clear description such as “Public product and architecture showcase for a reading-first iOS Screen Time application.”
- **Topics:** Use a small, accurate set such as `ios`, `swiftui`, `screen-time`, `typescript`, `postgresql`, `architecture`, and `portfolio`.
- **Default branch:** Protect it if multiple contributors will publish changes; require review for public-facing content changes.
- **Security features:** Enable GitHub secret scanning and dependency alerts where available, while remembering that this documentation repository should contain no production dependencies or secrets.
