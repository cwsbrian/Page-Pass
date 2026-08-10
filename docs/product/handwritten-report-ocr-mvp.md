# Handwritten Book Report OCR MVP

## Product Scope

PagePass OCR transcribes a child's handwritten book report from paper. It does
not scan pages from the book and it does not require the child to type a second
report after scanning.

The submission consists of:

1. Book title and optional author.
2. One or more ordered original images of the handwritten report.
3. A required on-device OCR attempt for every image.
4. An optional child-corrected transcript.

The original images are the source of truth. OCR helps the parent read and
review the report; it is not proof that the child read the book. Parent approval
is always required to grant Earned Time. AI scoring and auto-approval are out of
MVP scope.

## Child Flow

```text
Create draft
  -> enter book title
  -> scan handwritten pages
  -> review, reorder, retake, or delete pages
  -> run OCR on every page
  -> optionally correct the combined transcript
  -> confirm and submit
  -> wait for parent review
```

Use `VNDocumentCameraViewController` where supported for page-by-page capture,
cropping, perspective correction, and scan cleanup. Provide a normal camera or
photo-picker fallback if document scanning is unavailable.

Because the app supports iOS 17.4, the first implementation uses
`VNRecognizeTextRequest`. Use `.accurate`, language correction, and the request's
runtime-supported language list before setting Korean and English language
hints. OCR work runs off the main actor and exposes per-page progress and retry.

The in-progress capture is autosaved locally before the child submits. It
includes original pages, OCR terminal state, metadata, and corrected transcript.
Completed OCR restores without rerunning Vision. A changes-requested report can
replace its pages while preserving the existing submission identity; interrupted
replacement uploads reconcile and resume from local evidence.

## Data Rules

- Original image bytes are immutable after upload completion.
- Raw OCR is stored per page and can change only through an OCR retry while draft.
- Every retry increments `ocrRevision`; retrying the same revision is idempotent.
- Raw OCR is frozen while pending or terminal; changes-requested reopens the next revision.
- Corrected OCR is optional and mutable only while the submission is editable.
- The parent sees originals, raw OCR, final transcript, and an edited indicator.
- Page order determines both image order and raw transcript concatenation.
- No separately typed `reportBody` exists.

OCR statuses are:

```text
pending
succeeded
low_confidence
failed
```

Submission requires at least one uploaded original and no `pending` OCR pages.
`failed` is a completed attempt, so OCR failure never destroys or blocks an
otherwise valid handwritten report submission.

## Technical Proof Gate

Apple Vision supports on-device multilingual text recognition and allows the
app to query supported languages at runtime. That does not by itself guarantee
acceptable Korean or English handwriting quality. Before this slice is called
complete, run a physical-device matrix using representative child handwriting.

| Case | Required observation |
| --- | --- |
| One Korean page | Capture, OCR attempt, optional correction, submit |
| One English page | Capture, OCR attempt, optional correction, submit |
| Mixed Korean/English page | Both scripts preserved well enough for parent review |
| Three-page report | Stable order, progress, combined transcript |
| Skewed or dim page | Scanner correction works or retake guidance is clear |
| Blank/illegible page | Explicit failed/low-confidence state; submission remains possible |
| App restart during OCR | Original draft recovers and unfinished pages can retry |
| Upload failure | Local originals remain and upload can retry without rerunning OCR |

The gate passes when original pages are always recoverable and reviewable,
every page reaches a durable OCR terminal status, and the parent can approve
from the original images even when transcription quality is poor.

## Delivery Order

1. Child local capture, page management, OCR, correction, and draft recovery.
2. Media upload plus page-level immutable OCR API.
3. Parent review showing original/raw/final/edited state.
4. Atomic approval and credit reward, notification, and Journal integration.
5. Draft/processing recovery and rejected-report revision linked to its terminal
   predecessor.
6. Physical-device OCR quality gate with saved fixtures and timing/quality logs
   when representative handwritten reports are available.

## Apple References

- [Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [VNDocumentCameraViewController](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller)
