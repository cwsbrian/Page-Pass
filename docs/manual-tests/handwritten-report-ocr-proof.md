# Handwritten Report OCR Physical-Device Proof

## Build

Use a Debug build of the main `PagePass` app on the child device. Open:

```text
Child -> Verification -> Handwritten Report OCR
```

The Console category is `HandwrittenReportOCR`. Each page emits:

```text
ocr_page_start
ocr_page_complete
ocr_page_failed
```

Do not infer OCR duration from manual taps or screenshots. Use the emitted
`elapsed_ms` value and the system log timestamp.

## Required Matrix

Run each case with a fresh scan and record the visible metrics.

| Case | Pages | Expected result |
| --- | ---: | --- |
| Korean handwriting | 1 | Korean reports Supported; text is reviewable or correction is possible |
| English handwriting | 1 | English reports Supported; text is reviewable or correction is possible |
| Mixed Korean and English | 1 | Both scripts appear without losing the original image |
| Multi-page report | 3 | Page order and combined transcript order match |
| Skewed or dim page | 1 | Document Camera corrects it or OCR clearly reports low/failed |
| Blank or illegible page | 1 | Failed or low-confidence terminal state; original remains visible |
| OCR retry | 1 | OCR Revision increments and the app remains responsive |
| App relaunch during OCR | 3 | Record current behavior; durable draft recovery is Phase 2 |

## Record For Every Run

```text
Device model:
iOS version:
Case:
Page count:
Korean supported:
English supported:
Vision revision:
Configured languages:
Per-page status:
Per-page line count:
Per-page character count:
Per-page confidence:
Per-page elapsed_ms:
Original image retained: yes/no
Correction usable: yes/no
Notes:
```

## Gate

This technical spike passes when:

1. Original images remain visible even for empty or failed OCR.
2. Every page reaches succeeded, low confidence, or failed without a crash.
3. Korean and English are reported as runtime-supported on both target devices.
4. Three pages process in order without the UI becoming unresponsive.
5. A parent could understand the report from the originals plus transcript.

Accuracy is recorded, not silently treated as guaranteed. Durable draft recovery,
API upload, and Parent review are separate implementation phases.
