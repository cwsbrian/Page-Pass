# Manual Test Evidence Policy

Raw physical-device captures are intentionally not stored in Git. System logs,
process dumps, plists, screenshots, and compressed capture bundles can be
hundreds of megabytes per run and make normal clones impractical.

Git keeps the durable test reports, procedures, verdicts, timings, and relevant
small excerpts. Paths under `docs/manual-tests/evidence/` in historical reports
identify the original local capture locations; they are provenance references,
not repository links.

When a raw artifact must be retained, store it outside the repository using the
run directory name from the report. Do not commit it directly. A future shared
artifact store may replace local retention when the project needs team access.
