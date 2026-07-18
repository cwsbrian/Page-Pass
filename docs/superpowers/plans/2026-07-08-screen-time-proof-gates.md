# Screen Time Proof Gates Implementation Plan

> **Archive location:** This historical plan now lives outside the spike. All
> `PagePassControl*` paths and shell commands below are relative to
> `spikes/screen-time/`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing Screen Time spike into a physical-device proof for child `.child` authorization, zero-credit re-lock, conditional quantized debit, and the limited-app selection architecture decision.

**Architecture:** Keep the current native iOS spike and add only the state needed to prove the next gate. The child device remains the enforcement agent; the parent/device setup decision is captured by manual evidence before any backend or Nx migration work. Automatic deduction has two accepted paths: quantized repeated threshold debit if proven, otherwise single remaining-balance threshold fallback.

**Tech Stack:** SwiftUI, FamilyControls, ManagedSettings, DeviceActivity, XCTest, physical iPhone with child/teen Apple ID in Family Sharing.

---

## Scope

This plan covers only Phase 0 and Phase 1 from `docs/superpowers/specs/2026-07-08-pagepass-nx-mvp-architecture-design.md`.

Skipped for this plan:

* Nx monorepo migration
* backend
* OCR
* parent app shell
* subscriptions

Add those only after the Screen Time proof gates survive real devices.

The current workspace is not a git repository, so this plan has no commit steps.

## File Map

Modify:

* `PagePassControlSpike/Shared/SpikeConstants.swift` - proof credit and threshold constants.
* `PagePassControlSpike/Shared/SpikeState.swift` - automatic deduction path and threshold proof state.
* `PagePassControlSpike/Shared/SpikeReducer.swift` - pure credit decrement behavior.
* `PagePassControlSpikeTests/SpikeReducerTests.swift` - reducer checks for quantized and fallback paths.
* `PagePassControlSpike/ActivityMonitorService.swift` - configurable threshold when starting monitoring.
* `PagePassControlSpike/Shared/SpikeStateStore.swift` - base64 debug export/import for `FamilyActivitySelection`.
* `PagePassControlSpike/SpikeViewModel.swift` - proof run entry points.
* `PagePassControlSpike/ContentView.swift` - proof buttons and state labels.
* `PagePassControlMonitor/PagePassDeviceActivityMonitor.swift` - extension-side repeated threshold scheduling.
* `docs/manual-tests/screen-time-control-loop-checklist.md` - physical proof checklist for Gate 0, Gate 0b, and Gate 1.

Do not create new abstractions unless a target-membership issue forces it. The lazy path is reusing the current spike and a couple of reducer fields.

## Commands

List project:

```bash
xcodebuild -list -project PagePassControlSpike.xcodeproj
```

Run reducer tests:

```bash
xcodebuild test \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:PagePassControlSpikeTests/SpikeReducerTests
```

Build for the iOS Simulator:

```bash
xcodebuild build \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Physical-device install is done from Xcode with a signed team profile. The generic iOS CLI build currently depends on local keychain signing state and is not a reliable automated check.

## Task 1: Add Deduction State And Reducer Tests

**Files:**

* Modify: `PagePassControlSpike/Shared/SpikeConstants.swift`
* Modify: `PagePassControlSpike/Shared/SpikeState.swift`
* Modify: `PagePassControlSpike/Shared/SpikeReducer.swift`
* Modify: `PagePassControlSpikeTests/SpikeReducerTests.swift`

- [ ] **Step 1: Write failing reducer tests**

Append these tests to `PagePassControlSpikeTests/SpikeReducerTests.swift`:

```swift
func testQuantizedThresholdDebitsOneQuantumAndKeepsUnlockedWhenCreditRemains() {
    var state = SpikeState()
    SpikeReducer.apply(
        .monitoringStarted(
            runID: "run-1",
            activityName: "PagePassCreditRun-run-1",
            eventName: "limitedAppCredit-run-1",
            deductionPath: .quantized,
            creditGrantSeconds: 120,
            thresholdSeconds: 60
        ),
        to: &state
    )
    SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
    SpikeReducer.apply(.creditAdded, to: &state)

    SpikeReducer.apply(
        .thresholdReached(
            runID: "run-1",
            activityName: "PagePassCreditRun-run-1",
            eventName: "limitedAppCredit-run-1"
        ),
        to: &state
    )

    XCTAssertEqual(state.creditSeconds, 60)
    XCTAssertFalse(state.isShielded)
    XCTAssertEqual(state.thresholdReachedCount, 1)
    XCTAssertEqual(state.eventThresholdSeconds, 60)
}

func testSecondQuantizedThresholdLocksAtZero() {
    var state = SpikeState()
    SpikeReducer.apply(
        .monitoringStarted(
            runID: "run-1",
            activityName: "PagePassCreditRun-run-1",
            eventName: "limitedAppCredit-run-1",
            deductionPath: .quantized,
            creditGrantSeconds: 120,
            thresholdSeconds: 60
        ),
        to: &state
    )
    SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
    SpikeReducer.apply(.creditAdded, to: &state)
    SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)
    SpikeReducer.apply(.monitoringStarted(runID: "run-2", activityName: "PagePassCreditRun-run-2", eventName: "limitedAppCredit-run-2", deductionPath: .quantized, creditGrantSeconds: state.creditGrantSeconds, thresholdSeconds: state.eventThresholdSeconds), to: &state)
    SpikeReducer.apply(.intervalDidStart(runID: "run-2"), to: &state)
    SpikeReducer.apply(.thresholdReached(runID: "run-2", activityName: "PagePassCreditRun-run-2", eventName: "limitedAppCredit-run-2"), to: &state)

    XCTAssertEqual(state.creditSeconds, 0)
    XCTAssertTrue(state.isShielded)
    XCTAssertEqual(state.thresholdReachedCount, 2)
}

func testSingleThresholdFallbackConsumesAllCreditAtOnce() {
    var state = SpikeState()
    SpikeReducer.apply(
        .monitoringStarted(
            runID: "run-1",
            activityName: "PagePassCreditRun-run-1",
            eventName: "limitedAppCredit-run-1",
            deductionPath: .singleThresholdFallback,
            creditGrantSeconds: 120,
            thresholdSeconds: 120
        ),
        to: &state
    )
    SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
    SpikeReducer.apply(.creditAdded, to: &state)
    SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)

    XCTAssertEqual(state.creditSeconds, 0)
    XCTAssertTrue(state.isShielded)
    XCTAssertEqual(state.thresholdReachedCount, 1)
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:PagePassControlSpikeTests/SpikeReducerTests
```

Expected: FAIL with errors for missing `AutomaticDeductionPath`, new `monitoringStarted` parameters, and `.creditAdded` without seconds.

- [ ] **Step 3: Add constants**

Replace `PagePassControlSpike/Shared/SpikeConstants.swift` with:

```swift
enum SpikeConstants {
    static let appGroupID = "group.com.pagepass.controlspike"
    static let storeName = "PagePassControlSpike"
    static let activityPrefix = "PagePassCreditRun"
    static let eventPrefix = "limitedAppCredit"
    static let fallbackProofCreditSeconds = 120
    static let quantizedProofCreditSeconds = 120
    static let debitQuantumSeconds = 60
    static let eventThresholdSeconds = 60

    struct RunNames: Equatable {
        let activity: String
        let event: String
    }

    static func names(for runID: String) -> RunNames {
        RunNames(
            activity: "\(activityPrefix)-\(runID)",
            event: "\(eventPrefix)-\(runID)"
        )
    }
}
```

- [ ] **Step 4: Add deduction state**

Replace `PagePassControlSpike/Shared/SpikeState.swift` with:

```swift
import Foundation

enum AutomaticDeductionPath: String, Codable, Equatable {
    case quantized
    case singleThresholdFallback
}

struct SpikeState: Codable, Equatable {
    var creditSeconds: Int = 0
    var isShielded: Bool = false
    var activeRunID: String?
    var activeActivityName: String?
    var activeEventName: String?
    var intervalDidStart: Bool = false
    var monitoringIntervalStart: Date?
    var monitoringIntervalEnd: Date?
    var eventThresholdSeconds: Int = 0
    var creditGrantSeconds: Int = 0
    var debitQuantumSeconds: Int = SpikeConstants.debitQuantumSeconds
    var deductionPath: AutomaticDeductionPath = .singleThresholdFallback
    var thresholdReachedCount: Int = 0
    var scheduleIntervalDescription: String = ""
    var includesPastActivityEvidence: String = ""
}

enum SpikeAction: Equatable {
    case monitoringStarted(
        runID: String,
        activityName: String,
        eventName: String,
        deductionPath: AutomaticDeductionPath,
        creditGrantSeconds: Int,
        thresholdSeconds: Int
    )
    case intervalDidStart(runID: String)
    case creditAdded
    case thresholdReached(runID: String, activityName: String, eventName: String)
    case creditConsumed
    case cleanupReset
}
```

- [ ] **Step 5: Update reducer**

Replace `PagePassControlSpike/Shared/SpikeReducer.swift` with:

```swift
enum SpikeReducer {
    static func apply(_ action: SpikeAction, to state: inout SpikeState) {
        switch action {
        case let .monitoringStarted(runID, activityName, eventName, deductionPath, creditGrantSeconds, thresholdSeconds):
            state.activeRunID = runID
            state.activeActivityName = activityName
            state.activeEventName = eventName
            state.intervalDidStart = false
            state.deductionPath = deductionPath
            state.creditGrantSeconds = creditGrantSeconds
            state.eventThresholdSeconds = thresholdSeconds
            state.isShielded = state.creditSeconds == 0

        case let .intervalDidStart(runID):
            guard state.activeRunID == runID else { return }
            state.intervalDidStart = true

        case .creditAdded:
            guard state.intervalDidStart else { return }
            state.creditSeconds = state.creditGrantSeconds
            state.eventThresholdSeconds = threshold(for: state)
            state.isShielded = false

        case let .thresholdReached(runID, activityName, eventName):
            guard state.activeRunID == runID,
                  state.activeActivityName == activityName,
                  state.activeEventName == eventName else { return }
            let debitSeconds = min(state.creditSeconds, state.eventThresholdSeconds)
            state.creditSeconds = max(0, state.creditSeconds - debitSeconds)
            state.thresholdReachedCount += 1
            state.eventThresholdSeconds = threshold(for: state)
            state.isShielded = state.creditSeconds == 0

        case .creditConsumed:
            state.creditSeconds = 0
            state.isShielded = true

        case .cleanupReset:
            state = SpikeState(creditSeconds: 0, isShielded: false)
        }
    }

    private static func threshold(for state: SpikeState) -> Int {
        switch state.deductionPath {
        case .quantized:
            return min(state.creditSeconds, state.debitQuantumSeconds)
        case .singleThresholdFallback:
            return state.creditSeconds
        }
    }
}
```

- [ ] **Step 6: Update existing reducer tests for new action signatures**

In `PagePassControlSpikeTests/SpikeReducerTests.swift`, replace every old monitoring start call:

```swift
SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)
```

with:

```swift
SpikeReducer.apply(
    .monitoringStarted(
        runID: "run-1",
        activityName: "PagePassCreditRun-run-1",
        eventName: "limitedAppCredit-run-1",
        deductionPath: .singleThresholdFallback,
        creditGrantSeconds: 60,
        thresholdSeconds: 60
    ),
    to: &state
)
```

Replace every old credit add call:

```swift
SpikeReducer.apply(.creditAdded(seconds: 60), to: &state)
```

with:

```swift
SpikeReducer.apply(.creditAdded, to: &state)
```

- [ ] **Step 7: Run reducer tests**

Run:

```bash
xcodebuild test \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:PagePassControlSpikeTests/SpikeReducerTests
```

Expected: PASS for `SpikeReducerTests`.

## Task 2: Make Monitoring Start With The Selected Deduction Path

**Files:**

* Modify: `PagePassControlSpike/ActivityMonitorService.swift`
* Modify: `PagePassControlSpike/SpikeViewModel.swift`
* Modify: `PagePassControlSpike/ContentView.swift`

- [ ] **Step 1: Make monitor thresholds configurable**

In `PagePassControlSpike/ActivityMonitorService.swift`, change:

```swift
func prepareRun(runID: String, selection: FamilyActivitySelection) -> PreparedRun {
```

to:

```swift
func prepareRun(runID: String, selection: FamilyActivitySelection, thresholdSeconds: Int) -> PreparedRun {
```

In the same method, replace both uses of:

```swift
DateComponents(second: SpikeConstants.eventThresholdSeconds)
```

with:

```swift
DateComponents(second: thresholdSeconds)
```

- [ ] **Step 2: Add proof run methods to the view model**

In `PagePassControlSpike/SpikeViewModel.swift`, replace `startCreditedRun()` with:

```swift
func startQuantizedProofRun() {
    startProofRun(
        deductionPath: .quantized,
        creditGrantSeconds: SpikeConstants.quantizedProofCreditSeconds,
        thresholdSeconds: SpikeConstants.debitQuantumSeconds,
        messagePrefix: "Quantized proof"
    )
}

func startFallbackProofRun() {
    startProofRun(
        deductionPath: .singleThresholdFallback,
        creditGrantSeconds: SpikeConstants.fallbackProofCreditSeconds,
        thresholdSeconds: SpikeConstants.fallbackProofCreditSeconds,
        messagePrefix: "Fallback proof"
    )
}

private func startProofRun(
    deductionPath: AutomaticDeductionPath,
    creditGrantSeconds: Int,
    thresholdSeconds: Int,
    messagePrefix: String
) {
    guard !selection.applicationTokens.isEmpty else {
        message = "Select at least one app"
        return
    }
    guard selection.categoryTokens.isEmpty, selection.webDomainTokens.isEmpty else {
        message = "This spike supports app tokens only"
        return
    }

    lockSelectedApps()
    let runID = UUID().uuidString
    let names = SpikeConstants.names(for: runID)
    let monitor = ActivityMonitorService()
    let prepared = monitor.prepareRun(runID: runID, selection: selection, thresholdSeconds: thresholdSeconds)

    SpikeReducer.apply(
        .monitoringStarted(
            runID: runID,
            activityName: names.activity,
            eventName: names.event,
            deductionPath: deductionPath,
            creditGrantSeconds: creditGrantSeconds,
            thresholdSeconds: thresholdSeconds
        ),
        to: &state
    )
    state.monitoringIntervalStart = prepared.intervalStart
    state.monitoringIntervalEnd = prepared.intervalEnd
    state.scheduleIntervalDescription = prepared.scheduleDescription
    state.includesPastActivityEvidence = prepared.includesPastActivityEvidence

    do {
        try store.saveSelection(selection)
        try store.save(state)
        try store.append(SpikeEvent(name: "\(messagePrefix) monitoring armed", activityName: names.activity, eventName: names.event, runID: runID, source: "app", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "\(prepared.scheduleDescription); threshold=\(thresholdSeconds)s; path=\(deductionPath.rawValue); \(prepared.includesPastActivityEvidence)"))
    } catch {
        message = "App Group write failed before monitoring: \(error.localizedDescription)"
        return
    }

    do {
        try monitor.startRun(prepared)
        message = "\(messagePrefix) started. Wait for intervalDidStart before unlocking."
    } catch {
        shield.apply(selection: selection)
        try? store.append(SpikeEvent(name: "monitoring failed", activityName: names.activity, eventName: names.event, runID: runID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: error.localizedDescription))
        message = "Monitoring failed: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 3: Update credit grant method**

In `PagePassControlSpike/SpikeViewModel.swift`, replace `addCreditAfterIntervalStart()` with:

```swift
func addProofCreditAfterIntervalStart() {
    refreshFromStore()
    guard state.intervalDidStart else {
        message = "intervalDidStart not observed yet"
        return
    }
    let creditBefore = state.creditSeconds
    SpikeReducer.apply(.creditAdded, to: &state)
    shield.clear()
    try? store.save(state)
    try? store.append(SpikeEvent(name: "proof credit added", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "path=\(state.deductionPath.rawValue); next threshold=\(state.eventThresholdSeconds)s"))
    message = "Proof credit added and shield cleared"
}
```

- [ ] **Step 4: Update UI buttons and state labels**

In `PagePassControlSpike/ContentView.swift`, replace:

```swift
controlButton("Start Credited Run") {
    model.startCreditedRun()
}
```

with:

```swift
controlButton("Start Quantized Proof Run") {
    model.startQuantizedProofRun()
}
controlButton("Start Fallback Proof Run") {
    model.startFallbackProofRun()
}
```

Replace:

```swift
controlButton("Add Credit After intervalDidStart") {
    model.addCreditAfterIntervalStart()
}
```

with:

```swift
controlButton("Add Proof Credit After intervalDidStart") {
    model.addProofCreditAfterIntervalStart()
}
```

Add these state lines under the existing threshold line:

```swift
Text("Deduction path: \(model.state.deductionPath.rawValue)")
Text("Credit grant: \(model.state.creditGrantSeconds)s")
Text("Threshold hits: \(model.state.thresholdReachedCount)")
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild build \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `BUILD SUCCEEDED`.

## Task 3: Chain Quantized Thresholds In The Extension

**Files:**

* Modify: `PagePassControlMonitor/PagePassDeviceActivityMonitor.swift`

- [ ] **Step 1: Update imports**

At the top of `PagePassControlMonitor/PagePassDeviceActivityMonitor.swift`, replace:

```swift
import DeviceActivity
import FamilyControls
import ManagedSettings
```

with:

```swift
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
```

- [ ] **Step 2: Replace threshold handling**

Inside `eventDidReachThreshold(_:activity:)`, replace everything after the matching-active-run guard with:

```swift
let creditBefore = state.creditSeconds
SpikeReducer.apply(.thresholdReached(runID: runID, activityName: activity.rawValue, eventName: event.rawValue), to: &state)
let creditAfter = state.creditSeconds
try? store.save(state)

try? store.append(
    SpikeEvent(
        name: "threshold reached",
        activityName: activity.rawValue,
        eventName: event.rawValue,
        runID: runID,
        source: "extension",
        creditBefore: creditBefore,
        creditAfter: creditAfter,
        selectedApplicationTokenCount: selectedTokenCount(store: store),
        detail: "path=\(state.deductionPath.rawValue); threshold hits=\(state.thresholdReachedCount); next threshold=\(state.eventThresholdSeconds)s"
    )
)

if state.creditSeconds == 0 {
    if let selection = try? store.loadSelection() {
        managedStore.shield.applications = selection.applicationTokens
    }
    return
}

guard state.deductionPath == .quantized,
      let selection = try? store.loadSelection() else {
    return
}

scheduleNextQuantizedRun(selection: selection, store: store, state: &state)
```

- [ ] **Step 3: Add extension-side scheduling helpers**

Add these methods before `selectedTokenCount(store:)`:

```swift
private func scheduleNextQuantizedRun(selection: FamilyActivitySelection, store: SpikeStateStore, state: inout SpikeState) {
    let runID = UUID().uuidString
    let names = SpikeConstants.names(for: runID)
    let activity = DeviceActivityName(names.activity)
    let eventName = DeviceActivityEvent.Name(names.event)
    let thresholdSeconds = state.eventThresholdSeconds
    let now = Date()
    let start = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
    let endDate = Calendar.current.date(byAdding: .minute, value: 15, to: now)!
    let end = Calendar.current.dateComponents([.hour, .minute, .second], from: endDate)
    let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
    let event = makeEvent(selection: selection, thresholdSeconds: thresholdSeconds)

    SpikeReducer.apply(
        .monitoringStarted(
            runID: runID,
            activityName: names.activity,
            eventName: names.event,
            deductionPath: state.deductionPath,
            creditGrantSeconds: state.creditGrantSeconds,
            thresholdSeconds: thresholdSeconds
        ),
        to: &state
    )
    state.intervalDidStart = true
    state.monitoringIntervalStart = now
    state.monitoringIntervalEnd = endDate
    state.scheduleIntervalDescription = "extension scheduled next 15 minute non-repeating interval from \(now.formatted()) to \(endDate.formatted())"

    do {
        try store.save(state)
        try DeviceActivityCenter().startMonitoring(activity, during: schedule, events: [eventName: event])
        try? store.append(
            SpikeEvent(
                name: "next quantized threshold armed",
                activityName: names.activity,
                eventName: names.event,
                runID: runID,
                source: "extension",
                creditBefore: state.creditSeconds,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: "threshold=\(thresholdSeconds)s"
            )
        )
    } catch {
        managedStore.shield.applications = selection.applicationTokens
        state.isShielded = true
        try? store.save(state)
        try? store.append(
            SpikeEvent(
                name: "next quantized threshold failed",
                activityName: names.activity,
                eventName: names.event,
                runID: runID,
                source: "extension",
                creditBefore: state.creditSeconds,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: error.localizedDescription
            )
        )
    }
}

private func makeEvent(selection: FamilyActivitySelection, thresholdSeconds: Int) -> DeviceActivityEvent {
    if #available(iOS 17.4, *) {
        return DeviceActivityEvent(
            applications: selection.applicationTokens,
            threshold: DateComponents(second: thresholdSeconds),
            includesPastActivity: false
        )
    } else {
        return DeviceActivityEvent(
            applications: selection.applicationTokens,
            threshold: DateComponents(second: thresholdSeconds)
        )
    }
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild build \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `BUILD SUCCEEDED`.

## Task 4: Add Debug Selection Payload Transfer

**Files:**

* Modify: `PagePassControlSpike/Shared/SpikeStateStore.swift`
* Modify: `PagePassControlSpike/SpikeViewModel.swift`
* Modify: `PagePassControlSpike/ContentView.swift`
* Test: `PagePassControlSpikeTests/SpikeReducerTests.swift`

- [ ] **Step 1: Add selection payload round-trip test**

Append this test to `PagePassControlSpikeTests/SpikeReducerTests.swift`:

```swift
func testSelectionPayloadExportImportRoundTripsEmptySelection() throws {
    let suite = "SpikeStateStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SpikeStateStore(defaults: defaults)
    let selection = FamilyActivitySelection()

    let payload = try store.exportSelectionPayload(selection)
    let imported = try store.importSelectionPayload(payload)

    XCTAssertEqual(imported.applicationTokens.count, 0)
    XCTAssertEqual(imported.categoryTokens.count, 0)
    XCTAssertEqual(imported.webDomainTokens.count, 0)
}
```

At the top of `PagePassControlSpikeTests/SpikeReducerTests.swift`, add:

```swift
import FamilyControls
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
xcodebuild test \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:PagePassControlSpikeTests/SpikeReducerTests/testSelectionPayloadExportImportRoundTripsEmptySelection
```

Expected: FAIL with missing `exportSelectionPayload` and `importSelectionPayload`.

- [ ] **Step 3: Add store export/import methods**

In `PagePassControlSpike/Shared/SpikeStateStore.swift`, add these methods after `loadSelection()`:

```swift
func exportSelectionPayload(_ selection: FamilyActivitySelection) throws -> String {
    let data = try encoder.encode(selection)
    return data.base64EncodedString()
}

func importSelectionPayload(_ payload: String) throws -> FamilyActivitySelection {
    let cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: cleaned) else {
        throw StoreError.invalidSelectionPayload
    }
    return try decoder.decode(FamilyActivitySelection.self, from: data)
}
```

In `StoreError`, replace:

```swift
case appGroupUnavailable
```

with:

```swift
case appGroupUnavailable
case invalidSelectionPayload
```

- [ ] **Step 4: Add view model transfer helpers**

In `PagePassControlSpike/SpikeViewModel.swift`, add this published property near `message`:

```swift
@Published var selectionTransferPayload = ""
```

Add these methods after `refreshFromStore()`:

```swift
func exportSelectionPayload() {
    do {
        selectionTransferPayload = try store.exportSelectionPayload(selection)
        message = "Selection payload exported"
    } catch {
        message = "Selection export failed: \(error.localizedDescription)"
    }
}

func importSelectionPayload() {
    do {
        selection = try store.importSelectionPayload(selectionTransferPayload)
        try store.saveSelection(selection)
        message = "Selection payload imported"
    } catch {
        message = "Selection import failed: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 5: Add transfer UI**

In `PagePassControlSpike/ContentView.swift`, add these controls after `Pick Limited Apps`:

```swift
controlButton("Export Selection Payload") {
    model.exportSelectionPayload()
}
controlButton("Import Selection Payload") {
    model.importSelectionPayload()
}
TextEditor(text: $model.selectionTransferPayload)
    .frame(minHeight: 96)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
```

- [ ] **Step 6: Run reducer/store tests**

Run:

```bash
xcodebuild test \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:PagePassControlSpikeTests/SpikeReducerTests
```

Expected: PASS for `SpikeReducerTests`.

- [ ] **Step 7: Build**

Run:

```bash
xcodebuild build \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `BUILD SUCCEEDED`.

## Task 5: Update Manual Proof Checklist

**Files:**

* Modify: `docs/manual-tests/screen-time-control-loop-checklist.md`

- [ ] **Step 1: Add Gate 0 required proof section**

Insert this section after `## Device Setup`:

```markdown
## Gate 0 Required Proof

- [ ] Device is signed into child/teen Apple ID in Family Sharing.
- [ ] Parent/guardian device is available for approval.
- [ ] Tap "Request Child Authorization".
- [ ] Record exact result text:
- [ ] Confirm `.child` authorization succeeds.
- [ ] Select exactly one app token.
- [ ] Tap "Start Fallback Proof Run".
- [ ] Wait for `intervalDidStart`.
- [ ] Tap "Add Proof Credit After intervalDidStart".
- [ ] Confirm selected app unlocks.
- [ ] Background PagePass.
- [ ] Use selected app until threshold.
- [ ] Confirm selected app re-shields before reopening PagePass.
- [ ] Reopen PagePass.
- [ ] Confirm event log shows `threshold reached` from `extension`.
- [ ] Confirm credit reaches `0`.
- [ ] Cleanup reset run.
- [ ] Select the same app token.
- [ ] Tap "Start Fallback Proof Run".
- [ ] Wait for `intervalDidStart`.
- [ ] Tap "Add Proof Credit After intervalDidStart".
- [ ] Force quit PagePass.
- [ ] Use selected app until threshold.
- [ ] Confirm selected app re-shields before reopening PagePass.
- [ ] Reopen PagePass.
- [ ] Confirm event log shows `threshold reached` from `extension`.
- [ ] Confirm credit reaches `0`.
```

- [ ] **Step 2: Add Gate 0b conditional proof section**

Insert this section after the Gate 0 section:

```markdown
## Gate 0b Conditional Quantized Debit Proof

- [ ] Cleanup reset run.
- [ ] Select exactly one app token.
- [ ] Tap "Start Quantized Proof Run".
- [ ] Wait for `intervalDidStart`.
- [ ] Tap "Add Proof Credit After intervalDidStart".
- [ ] Confirm credit starts at `120s`.
- [ ] Force quit PagePass.
- [ ] Use selected app until first threshold.
- [ ] Keep using the selected app after the first threshold would have elapsed.
- [ ] Confirm selected app re-shields after second threshold.
- [ ] Reopen PagePass.
- [ ] Confirm event log shows the first `threshold reached`.
- [ ] Confirm event log shows `next quantized threshold armed`.
- [ ] Confirm event log shows the second `threshold reached`.
- [ ] Confirm the first threshold event has credit after `60s`.
- [ ] Confirm credit reaches `0`.
- [ ] If this fails, mark quantized debit rejected and use the single-threshold fallback.
```

- [ ] **Step 3: Add Gate 1 selection architecture section**

Insert this section after Gate 0b:

```markdown
## Gate 1 Limited App Selection Architecture

- [ ] On parent iPhone, use FamilyActivityPicker while parent is in the same Family Sharing group.
- [ ] Record whether child apps appear in the parent picker:
- [ ] Record whether selected app tokens can be persisted:
- [ ] Tap "Export Selection Payload" on the parent iPhone.
- [ ] Send the base64 payload text to the child iPhone by AirDrop, Messages, or Notes.
- [ ] Paste the payload into the PagePass selection payload text box on the child iPhone.
- [ ] Tap "Import Selection Payload" on the child iPhone.
- [ ] Confirm the child device can apply ManagedSettings shield from the transferred selection.
- [ ] Confirm the child device can monitor DeviceActivity for the transferred selection.
- [ ] Decision:
  - [ ] Remote parent picker accepted.
  - [ ] Remote parent picker rejected; fallback requires a follow-up Parent Setup Mode proof before backend or policy work.
```

- [ ] **Step 4: Check for stale button names**

Run:

```bash
rg -n "Start Credited Run|Add Credit After intervalDidStart|Run Negative-Control Test" docs/manual-tests/screen-time-control-loop-checklist.md PagePassControlSpike
```

Expected: no matches.

## Task 6: Physical Device Proof Run

**Files:**

* Modify: `docs/manual-tests/screen-time-control-loop-checklist.md`

- [ ] **Step 1: Build and install on child test iPhone**

Use Xcode or:

```bash
xcodebuild build \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

Expected: `BUILD SUCCEEDED`.

Then install on the child test iPhone from Xcode with the signed development team/profile.

- [ ] **Step 2: Run Gate 0 checklist**

Open `docs/manual-tests/screen-time-control-loop-checklist.md` and complete every item in `Gate 0 Required Proof`.

Expected: `.child` authorization succeeds, one threshold fires, zero-credit re-lock works once with PagePass backgrounded and once with PagePass force quit.

- [ ] **Step 3: Run Gate 0b checklist**

Open `docs/manual-tests/screen-time-control-loop-checklist.md` and complete every item in `Gate 0b Conditional Quantized Debit Proof`.

Expected if accepted: two threshold hits occur without reopening PagePass, and credit reaches zero after the second hit.

Expected if rejected: first hit works, second scheduling does not; record fallback decision.

- [ ] **Step 4: Run Gate 1 checklist**

Open `docs/manual-tests/screen-time-control-loop-checklist.md` and complete every item in `Gate 1 Limited App Selection Architecture`.

Expected: either remote parent picker is accepted with proof, or remote parent picker is rejected and a follow-up Parent Setup Mode proof is required before backend/policy work.

## Self-Review

Spec coverage:

* Gate 0 child `.child` proof: Task 6.
* Gate 0b repeated quantized debit proof: Tasks 1, 3, 6.
* Single-threshold fallback: Tasks 1, 2, 5, 6.
* Gate 1 limited app selection architecture: Tasks 4, 5, 6.
* Parent controls / child enforces: documented in checklist decisions; no backend added.
* Nx/backend/OCR: intentionally skipped until proof gates pass.

Placeholder scan:

```bash
rg -n "TBD|TODO|implement later|fill in|Add appropriate|handle edge cases|Similar to Task|by debit quantum|simplest available|temporary method" docs/superpowers/plans/2026-07-08-screen-time-proof-gates.md
```

Expected: no matches, except this command line itself may match the quoted search terms.

Type consistency:

* `AutomaticDeductionPath` is defined before use.
* `.monitoringStarted` has one signature everywhere.
* `.creditAdded` has no associated value everywhere.
* `selected automatic deduction path` wording matches the PRD/spec fallback model.
