# Engineering Decisions

These lightweight records describe significant choices visible in the implementation. Where the repository does not explicitly record original intent, the rationale is framed as an inference from the current structure.

## Decision: Use Explicit Wall-Clock Sessions Instead of Per-App Usage Debit

### Context

The product must let a child deliberately spend earned credit while selected applications are available. Continuous or threshold-based application-usage measurement adds platform constraints and makes the user's remaining credit depend on which foreground activity the system reports.

### Decision

Earned Time is represented as a user-started session with an absolute start and deadline. Manual stop consumes rounded-up elapsed wall-clock time; expiry consumes the requested duration. The implementation registers a Device Activity interval without per-app usage events.

### Rationale

The repository's physical-device report directly records this decision after validating manual stop and expiry behavior. The resulting model is understandable to the child, can expire while the host app is terminated, and does not depend on continuous usage callbacks.

### Trade-offs

- Credit is spent for the whole active wall-clock interval, including time outside selected applications.
- The current implementation enforces a 15-minute minimum based on observed platform behavior.
- Device Activity expiry is not an exact alarm, so host reconciliation is still required.
- The UI currently starts a maximum-duration session rather than offering multiple duration choices.

### Evidence in the Repository

- `docs/manual-tests/2026-07-17-wall-clock-earned-time-session-report.md`
- `apps/mobile-ios/App/ScreenTime/EarnedTimeScheduler.swift`
- `apps/mobile-ios/Packages/PagePassCore/Sources/PagePassCore/EarnedTimeReducer.swift`
- `apps/mobile-ios/Monitor/PagePassDeviceActivityMonitor.swift`

## Decision: Make Screen Time Transitions Fail Closed

### Context

Starting and ending a session crosses persistent state, system schedule registration, and Managed Settings policy. A failure between those operations could leave selected apps accessible without a valid session.

### Decision

The restrictive no-session policy is applied before a session is armed. The app verifies schedule registration before moving the shared state to active and relaxing the shield. Stop and expiry reapply the shield before finalizing consumption. Recovery paths use a more restrictive emergency policy if the intended policy cannot be loaded.

### Rationale

Based on the current implementation, this ordering appears designed to prefer temporary over-restriction over unintended access. Explicit arming, active, ending, and settlement phases make incomplete transitions observable and recoverable.

### Trade-offs

- A platform or storage error may restrict more applications than the saved policy intended until recovery succeeds.
- The orchestration contains more state transitions than a simple foreground timer.
- Platform authorization and App Group availability become hard runtime prerequisites.

### Evidence in the Repository

- `apps/mobile-ios/App/Features/Child/ChildSessionStore.swift`
- `apps/mobile-ios/App/ScreenTime/EarnedTimeShieldController.swift`
- `apps/mobile-ios/App/ScreenTime/EarnedTimeScheduler.swift`
- `apps/mobile-ios/Monitor/PagePassDeviceActivityMonitor.swift`
- `apps/mobile-ios/Packages/PagePassCore/Tests/PagePassCoreTests/EarnedTimeReducerTests.swift`

## Decision: Share a Reducer and Locked App Group State Across Processes

### Context

Both the host app and Device Activity monitor extension can end a session. They run in separate processes and can be activated close together after the same deadline.

### Decision

A dependency-light Swift package owns the session model and transition reducer. The host and extension persist that state in an App Group container, and an advisory file lock serializes each read-modify-write operation.

### Rationale

Based on the current implementation, this structure appears designed to keep business rules identical in both processes and to prevent a host reconciliation and extension callback from charging the same session twice. The shared package can be tested without launching the iOS application.

### Trade-offs

- App Group configuration must be correct for both targets.
- File locking serializes all session mutations; this is appropriate for one local session but would not be a general high-throughput store.
- `UserDefaults` remains a compact state store rather than a queryable event history.

### Evidence in the Repository

- `apps/mobile-ios/Packages/PagePassCore/`
- `apps/mobile-ios/Shared/AppGroupSessionStore.swift`
- `apps/mobile-ios/Shared/ManagedAppPolicyStore.swift`
- `apps/mobile-ios/App/Features/Child/ChildSessionStore.swift`
- `apps/mobile-ios/Monitor/PagePassDeviceActivityMonitor.swift`

## Decision: Keep the Server Ledger Canonical and Retry-Safe

### Context

The child device must act immediately when a session stops or expires, even when offline. At the same time, the shared family balance must survive reinstallations and API restarts and must not be double-charged by retries or concurrent requests.

### Decision

The device deducts locally and queues a settlement. The API authenticates the paired device, validates the session envelope, computes the accepted consumption itself, and commits an immutable spend record inside a database transaction. Stable idempotency keys, request fingerprints, unique constraints, and ledger revisions distinguish safe retries from conflicting reuse.

### Rationale

Based on the current implementation, this structure appears designed to combine offline-safe enforcement with one authoritative balance. Server identity and ledger revision metadata also prevent an older snapshot from silently replacing newer device state.

### Trade-offs

- The child can show a locally reduced balance before the server acknowledges it.
- A rejected settlement requires an explicit synchronization/recovery state.
- Transactional row locking and additional metadata increase persistence complexity.
- The current ledger stores credit grants and spends, but it is not yet connected to a reading-submission approval model.

### Evidence in the Repository

- `apps/mobile-ios/App/Features/Child/ChildSessionStore.swift`
- `apps/mobile-ios/App/Features/Child/ChildPairingStore.swift`
- `apps/api/src/postgres-store.ts`
- `apps/api/prisma/schema.prisma`
- `apps/api/src/postgres.integration.test.ts`
- `apps/api/src/postgres-adversarial.integration.test.ts`

## Decision: Separate Parent Sessions from Child Device Credentials

### Context

Parents need broad access to their child profiles, while a child installation should only synchronize the one profile to which it is connected. Pairing must work without entering or storing the parent's credential on the child device.

### Decision

Parents authenticate through Sign in with Apple and receive revocable application sessions. A parent-owned, short-lived pairing session can be consumed once to issue a separate child-device credential. Both credential types are stored in distinct Keychain records on iOS and as digests on the server.

### Rationale

Based on the current implementation, this structure appears designed to apply least privilege across family roles. Single-use pairing, numeric-attempt rate limiting, ownership checks, and one-active-device rules reduce replay and accidental reassignment risk.

### Trade-offs

- Families must complete an explicit connection step for the child installation.
- The one-active-device model does not yet support multiple child devices or seamless replacement.
- Pairing and credential lifecycle add failure states that the UI must explain.
- Secure device replacement and recovery are not represented as a completed user flow.

### Evidence in the Repository

- `apps/mobile-ios/App/Features/Parent/ParentAuthStore.swift`
- `apps/mobile-ios/App/Features/Child/ChildPairingStore.swift`
- `apps/mobile-ios/App/Security/`
- `apps/api/src/apple-token-verifier.ts`
- `apps/api/src/postgres-store.ts`
- `apps/api/src/postgres-auth.integration.test.ts`

## Decision: Use a Thin Native HTTP Boundary with Shared Runtime Validation

### Context

The MVP needs a small set of parent, pairing, snapshot, credit, and settlement operations. Both Swift and TypeScript clients must reject malformed responses and maintain stable request semantics.

### Decision

The API uses Node.js's native HTTP server rather than a larger web framework. Zod schemas in a shared TypeScript library validate JSON and path inputs, and the Swift client mirrors the public payload models with strict decoding. Request bodies are size-limited and redirects are not followed by the client.

### Rationale

Based on the current implementation, the API surface is small enough that a thin boundary keeps dependencies and routing behavior explicit. Shared runtime schemas make server validation and TypeScript contract types originate from one definition.

### Trade-offs

- Routing, error mapping, body parsing, and middleware-like concerns are maintained directly.
- Swift models remain manually mirrored rather than generated from the Zod contracts.
- A larger API may eventually justify framework routing or generated cross-language contracts.

### Evidence in the Repository

- `apps/api/src/main.ts`
- `libs/shared/src/index.ts`
- `apps/mobile-ios/App/Networking/PagePassAPIClient.swift`
- `apps/mobile-ios/App/Networking/PagePassAPIModels.swift`
- `package.json`
