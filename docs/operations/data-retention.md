# PagePass Data Retention

This document describes the implemented MVP retention behavior. Product and
legal review must approve changes before production launch.

## Active Families

PagePass retains child profiles, device history, managed-app policy state,
Earned Time sessions and ledger entries, app requests, reading submissions,
OCR text, original report images, and parent review history while the family is
active. These records provide the parent-visible history and the accounting
source of truth. They are not removed by the operational cleanup worker.

Parents can explicitly delete drafts. Replaced report evidence is removed by
the reading flow and its private objects are deleted through the durable media
deletion queue.

## Automatic Operational Cleanup

`DataRetentionWorker` runs at API startup and then once per day. It removes only
expired or completed operational records:

| Data | Retention |
| --- | --- |
| Better Auth sessions and verification tokens | Until expiration, then deleted on the next run |
| Apple authentication challenges | 1 day after expiration |
| Pairing rate-limit attempts | 1 day |
| Pairing sessions | 30 days after expiration |
| Legacy parent sessions | 30 days after expiration or revocation |
| Revoked child credentials and parent/child push registrations | 30 days after revocation |
| Child device status reports | 30 days after receipt |
| Sent or permanently failed push outbox events | 30 days after final update |
| Completed private-media deletion jobs | 30 days after completion |

Pending push and media-deletion jobs are never removed by retention cleanup.
Worker failures are reported as structured background-worker errors and do not
terminate the API process.

## Parent Account Deletion

Deleting a parent account requires a recent sign-in. In a shared family, family
ownership transfers and the departing parent's authentication, sessions, push
registration, and membership are removed while family records remain available
to the other parent.

When the final parent deletes the account, PagePass immediately:

- revokes child credentials, push registrations, and active devices;
- invalidates open pairing sessions and denies pending app requests;
- removes managed-app token ciphertext and archives managed apps;
- removes child/family names, reading titles, author names, OCR text, review
  comments, and app-request messages;
- marks private media deleted and enqueues each object for retryable physical
  deletion from S3-compatible storage.

Unsettled Earned Time blocks final-parent deletion so apps cannot remain
unlocked or produce an ambiguous balance. Final-family scrubbing is serialized
with every child pairing, policy, credit, and reading mutation.

Completed private media is eligible for deletion immediately. A pending
presigned upload is scheduled after its stored URL expiry plus a clock-skew
buffer. Its deletion job remains as a daily tombstone after successful deletes,
so an upload that began before expiry but finishes late is removed by a later
sweep instead of becoming an untracked object.
Upload URLs also sign `If-None-Match: *`, preventing a completed object from
being overwritten while the URL remains valid.
Legacy failed uploads without a recorded expiry receive a conservative expiry
backfill and are promoted to the same continuous deletion path.

Pseudonymous transaction and review rows remain after final-family deletion for
service integrity and dispute handling. Their production maximum retention
period requires legal approval before launch.

## Infrastructure

- PostgreSQL and object-storage backups must use the production provider's
  approved expiry policy. Backup retention is not controlled by the API worker.
- Application logs must not contain OCR text, report images, bearer credentials,
  pairing codes, Screen Time tokens, or APNs tokens.
- Production monitoring should alert on retention-worker errors and failed or
  aging media-deletion jobs.

## Release Gates

Before production launch:

1. Legal review must approve the policy, backup window, and maximum retention
   for pseudonymous integrity records.
2. The deployed database and object-storage backup lifecycle must match that
   decision.
3. Account deletion must be smoke tested against production-like private media.
4. The public privacy policy must be updated if the approved policy changes.
