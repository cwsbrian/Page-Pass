# Screen Time Control Loop Spike Implementation Plan

> **Archive location:** This historical plan now lives outside the spike. All
> `PagePassControl*` paths and shell commands below are relative to
> `spikes/screen-time/`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the smallest physical-device iOS spike that proves selected apps lock, unlock after earned credit, consume credit through actual selected-app usage, and re-lock at zero credit.

**Architecture:** A single SwiftUI iOS app owns authorization, app selection, cleanup, manual controls, and visible logs. A Device Activity Monitor extension writes interval/threshold events into App Group storage and reapplies shields through the same named `ManagedSettingsStore`. Pure state transitions stay in testable Swift files; Screen Time APIs are verified manually on a physical child device.

**Tech Stack:** SwiftUI, XCTest, FamilyControls, ManagedSettings, DeviceActivity, App Groups, physical iPhone, Xcode 26.5, minimum deployment iOS 17.4.

---

## Source Spec

Implement only this spec:

`docs/superpowers/specs/2026-07-08-screen-time-control-loop-spike-design.md`

Do not build backend, auth service, OCR, AI, subscription, parent app, or App Store polish.

## File Structure

Create these files through Xcode and normal file edits:

```text
PagePassControlSpike.xcodeproj
PagePassControlSpike/PagePassControlSpikeApp.swift
PagePassControlSpike/ContentView.swift
PagePassControlSpike/SpikeViewModel.swift
PagePassControlSpike/AuthorizationService.swift
PagePassControlSpike/ActivityMonitorService.swift
PagePassControlSpike/ShieldController.swift
PagePassControlSpike/Shared/SpikeConstants.swift
PagePassControlSpike/Shared/SpikeEvent.swift
PagePassControlSpike/Shared/SpikeState.swift
PagePassControlSpike/Shared/SpikeReducer.swift
PagePassControlSpike/Shared/SpikeStateStore.swift
PagePassControlSpike/PagePassControlSpike.entitlements
PagePassControlMonitor/PagePassDeviceActivityMonitor.swift
PagePassControlMonitor/PagePassControlMonitor.entitlements
PagePassControlSpikeTests/SpikeReducerTests.swift
PagePassControlSpikeTests/RunNameTests.swift
docs/manual-tests/screen-time-control-loop-checklist.md
```

Target setup:

```text
App target: PagePassControlSpike
Monitor extension target: PagePassControlMonitor
Unit test target: PagePassControlSpikeTests
App bundle id: com.pagepass.controlspike
Monitor bundle id: com.pagepass.controlspike.DeviceActivityMonitor
App Group id: group.com.pagepass.controlspike
Minimum deployment: iOS 17.4
```

Because this workspace is not a git repository, skip commit steps until the project is initialized as git.

---

### Task 1: Create Xcode Project And Capabilities

**Files:**
- Create: `PagePassControlSpike.xcodeproj`
- Create: `PagePassControlSpike/PagePassControlSpike.entitlements`
- Create: `PagePassControlMonitor/PagePassControlMonitor.entitlements`
- Create: `PagePassControlMonitor/Info.plist`

- [ ] **Step 1: Create app project**

In Xcode:

```text
File -> New -> Project -> iOS -> App
Product Name: PagePassControlSpike
Interface: SwiftUI
Language: Swift
Include Tests: checked
Organization Identifier: com.pagepass
Bundle Identifier: com.pagepass.controlspike
Save in: /Users/brianchoi/Documents/work/personal/page-pass
```

- [ ] **Step 2: Add Device Activity Monitor extension**

In Xcode:

```text
File -> New -> Target -> iOS -> Device Activity Monitor Extension
Product Name: PagePassControlMonitor
Bundle Identifier: com.pagepass.controlspike.DeviceActivityMonitor
Embed in Application: PagePassControlSpike
```

- [ ] **Step 3: Set deployment target**

Set both targets to:

```text
iOS Deployment Target: 17.4
```

- [ ] **Step 4: Configure app entitlements**

In Xcode, select the `PagePassControlSpike` app target, open Signing & Capabilities, and add:

```text
Family Controls
App Groups -> group.com.pagepass.controlspike
```

Then set `PagePassControlSpike/PagePassControlSpike.entitlements` to:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.family-controls</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.pagepass.controlspike</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 5: Configure monitor extension entitlements**

In Xcode, select the `PagePassControlMonitor` extension target, open Signing & Capabilities, and add:

```text
Family Controls
App Groups -> group.com.pagepass.controlspike
```

Then set `PagePassControlMonitor/PagePassControlMonitor.entitlements` to:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.family-controls</key>
  <true/>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.pagepass.controlspike</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 6: Verify monitor extension point**

Open `PagePassControlMonitor/Info.plist` and confirm:

```xml
<key>NSExtensionPointIdentifier</key>
<string>com.apple.deviceactivity.monitor-extension</string>
<key>NSExtensionPrincipalClass</key>
<string>$(PRODUCT_MODULE_NAME).PagePassDeviceActivityMonitor</string>
```

If Xcode generated a different principal class, rename the generated Swift class to `PagePassDeviceActivityMonitor` and update `NSExtensionPrincipalClass` to match the snippet above.

- [ ] **Step 7: Verify schemes exist**

Run:

```bash
xcodebuild -list -project PagePassControlSpike.xcodeproj
```

Expected: output lists `PagePassControlSpike` and `PagePassControlMonitor` targets.

- [ ] **Step 8: Verify entitlements are attached to build settings**

Run:

```bash
xcodebuild -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -showBuildSettings | rg 'CODE_SIGN_ENTITLEMENTS|PRODUCT_BUNDLE_IDENTIFIER'
```

Expected output includes:

```text
CODE_SIGN_ENTITLEMENTS = PagePassControlSpike/PagePassControlSpike.entitlements
PRODUCT_BUNDLE_IDENTIFIER = com.pagepass.controlspike
```

Then inspect the extension target in Xcode Build Settings and confirm:

```text
CODE_SIGN_ENTITLEMENTS = PagePassControlMonitor/PagePassControlMonitor.entitlements
PRODUCT_BUNDLE_IDENTIFIER = com.pagepass.controlspike.DeviceActivityMonitor
```

---

### Task 2: Add Pure State Tests First

**Files:**
- Create: `PagePassControlSpikeTests/SpikeReducerTests.swift`
- Create: `PagePassControlSpike/Shared/SpikeState.swift`
- Create: `PagePassControlSpike/Shared/SpikeReducer.swift`

- [ ] **Step 1: Write failing reducer tests**

Create `PagePassControlSpikeTests/SpikeReducerTests.swift`:

```swift
import XCTest
@testable import PagePassControlSpike

final class SpikeReducerTests: XCTestCase {
    func testZeroCreditLocks() {
        var state = SpikeState()
        SpikeReducer.apply(.creditConsumed, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)
    }

    func testIntervalMustStartBeforeUnlock() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)
        SpikeReducer.apply(.creditAdded(seconds: 60), to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)

        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded(seconds: 60), to: &state)
        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
    }

    func testStaleCallbackDoesNotMutateState() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded(seconds: 60), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "old-run", activityName: "PagePassCreditRun-old-run", eventName: "limitedAppCredit-old-run"), to: &state)

        XCTAssertEqual(state.creditSeconds, 60)
        XCTAssertFalse(state.isShielded)
    }

    func testMatchingThresholdConsumesCreditAndLocks() {
        var state = SpikeState()
        SpikeReducer.apply(.monitoringStarted(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)
        SpikeReducer.apply(.intervalDidStart(runID: "run-1"), to: &state)
        SpikeReducer.apply(.creditAdded(seconds: 60), to: &state)

        SpikeReducer.apply(.thresholdReached(runID: "run-1", activityName: "PagePassCreditRun-run-1", eventName: "limitedAppCredit-run-1"), to: &state)

        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertTrue(state.isShielded)
    }

    func testCleanupOverrideUnlocksOnlyForCleanup() {
        var state = SpikeState(creditSeconds: 0, isShielded: true)
        SpikeReducer.apply(.cleanupReset, to: &state)
        XCTAssertEqual(state.creditSeconds, 0)
        XCTAssertFalse(state.isShielded)
        XCTAssertNil(state.activeRunID)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: fails because `SpikeState` and `SpikeReducer` do not exist.

- [ ] **Step 3: Add minimal state model**

Create `PagePassControlSpike/Shared/SpikeState.swift`:

```swift
import Foundation

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
    var scheduleIntervalDescription: String = ""
    var includesPastActivityEvidence: String = ""
}

enum SpikeAction: Equatable {
    case monitoringStarted(runID: String, activityName: String, eventName: String)
    case intervalDidStart(runID: String)
    case creditAdded(seconds: Int)
    case thresholdReached(runID: String, activityName: String, eventName: String)
    case creditConsumed
    case cleanupReset
}
```

- [ ] **Step 4: Add reducer**

Create `PagePassControlSpike/Shared/SpikeReducer.swift`:

```swift
enum SpikeReducer {
    static func apply(_ action: SpikeAction, to state: inout SpikeState) {
        switch action {
        case let .monitoringStarted(runID, activityName, eventName):
            state.activeRunID = runID
            state.activeActivityName = activityName
            state.activeEventName = eventName
            state.intervalDidStart = false
            state.creditSeconds = 0
            state.isShielded = true

        case let .intervalDidStart(runID):
            guard state.activeRunID == runID else { return }
            state.intervalDidStart = true

        case let .creditAdded(seconds):
            guard state.intervalDidStart else { return }
            state.creditSeconds = seconds
            state.isShielded = false

        case let .thresholdReached(runID, activityName, eventName):
            guard state.activeRunID == runID,
                  state.activeActivityName == activityName,
                  state.activeEventName == eventName else { return }
            state.creditSeconds = 0
            state.isShielded = true

        case .creditConsumed:
            state.creditSeconds = 0
            state.isShielded = true

        case .cleanupReset:
            state = SpikeState(creditSeconds: 0, isShielded: false)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: reducer tests pass.

---

### Task 3: Add Constants, Run Names, And Event Log Tests

**Files:**
- Create: `PagePassControlSpike/Shared/SpikeConstants.swift`
- Create: `PagePassControlSpike/Shared/SpikeEvent.swift`
- Create: `PagePassControlSpikeTests/RunNameTests.swift`

- [ ] **Step 1: Write run-name tests**

Create `PagePassControlSpikeTests/RunNameTests.swift`:

```swift
import XCTest
@testable import PagePassControlSpike

final class RunNameTests: XCTestCase {
    func testRunSpecificNamesIncludeRunID() {
        let names = SpikeConstants.names(for: "abc123")
        XCTAssertEqual(names.activity, "PagePassCreditRun-abc123")
        XCTAssertEqual(names.event, "limitedAppCredit-abc123")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: fails because `SpikeConstants` does not exist.

- [ ] **Step 3: Add constants**

Create `PagePassControlSpike/Shared/SpikeConstants.swift`:

```swift
enum SpikeConstants {
    static let appGroupID = "group.com.pagepass.controlspike"
    static let storeName = "PagePassControlSpike"
    static let activityPrefix = "PagePassCreditRun"
    static let eventPrefix = "limitedAppCredit"
    static let testCreditSeconds = 60
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

- [ ] **Step 4: Add event model**

Create `PagePassControlSpike/Shared/SpikeEvent.swift`:

```swift
import Foundation

struct SpikeEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let activityName: String?
    let eventName: String?
    let runID: String?
    let timestamp: Date
    let source: String
    let creditBefore: Int
    let creditAfter: Int
    let selectedApplicationTokenCount: Int
    let detail: String

    init(
        id: UUID = UUID(),
        name: String,
        activityName: String? = nil,
        eventName: String? = nil,
        runID: String? = nil,
        timestamp: Date = Date(),
        source: String,
        creditBefore: Int,
        creditAfter: Int,
        selectedApplicationTokenCount: Int,
        detail: String = ""
    ) {
        self.id = id
        self.name = name
        self.activityName = activityName
        self.eventName = eventName
        self.runID = runID
        self.timestamp = timestamp
        self.source = source
        self.creditBefore = creditBefore
        self.creditAfter = creditAfter
        self.selectedApplicationTokenCount = selectedApplicationTokenCount
        self.detail = detail
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: reducer and run-name tests pass.

---

### Task 4: Add App Group State Store

**Files:**
- Create: `PagePassControlSpike/Shared/SpikeStateStore.swift`
- Modify: `PagePassControlSpikeTests/SpikeReducerTests.swift`

- [ ] **Step 1: Add persistence self-check test**

Insert this method inside `final class SpikeReducerTests`, before the class's final `}`:

```swift
func testStoreRoundTrip() throws {
    let suite = "SpikeStateStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SpikeStateStore(defaults: defaults)
    let state = SpikeState(creditSeconds: 60, isShielded: false, activeRunID: "run-1")

    try store.save(state)
    let loaded = try store.loadState()

    XCTAssertEqual(loaded, state)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: fails because `SpikeStateStore` does not exist.

- [ ] **Step 3: Add state store**

Create `PagePassControlSpike/Shared/SpikeStateStore.swift`:

```swift
import Foundation
import FamilyControls

struct SpikeStateStore {
    enum StoreError: Error {
        case appGroupUnavailable
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func appGroup() throws -> SpikeStateStore {
        guard let defaults = UserDefaults(suiteName: SpikeConstants.appGroupID) else {
            throw StoreError.appGroupUnavailable
        }
        return SpikeStateStore(defaults: defaults)
    }

    func loadState() throws -> SpikeState {
        guard let data = defaults.data(forKey: "state") else { return SpikeState() }
        return try decoder.decode(SpikeState.self, from: data)
    }

    func save(_ state: SpikeState) throws {
        let data = try encoder.encode(state)
        defaults.set(data, forKey: "state")
    }

    func append(_ event: SpikeEvent) throws {
        var events = try loadEvents()
        events.append(event)
        let data = try encoder.encode(events)
        defaults.set(data, forKey: "events")
    }

    func loadEvents() throws -> [SpikeEvent] {
        guard let data = defaults.data(forKey: "events") else { return [] }
        return try decoder.decode([SpikeEvent].self, from: data)
    }

    func saveSelection(_ selection: FamilyActivitySelection) throws {
        let data = try encoder.encode(selection)
        defaults.set(data, forKey: "selection")
    }

    func loadSelection() throws -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: "selection") else { return FamilyActivitySelection() }
        return try decoder.decode(FamilyActivitySelection.self, from: data)
    }

    func reset() {
        defaults.removeObject(forKey: "state")
        defaults.removeObject(forKey: "events")
        defaults.removeObject(forKey: "selection")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: tests pass.

---

### Task 5: Add Shield And Cleanup Controllers

**Files:**
- Create: `PagePassControlSpike/ShieldController.swift`
- Modify: `PagePassControlSpike/SpikeViewModel.swift`

- [ ] **Step 1: Add shield controller**

Create `PagePassControlSpike/ShieldController.swift`:

```swift
import FamilyControls
import ManagedSettings

struct ShieldController {
    private let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(SpikeConstants.storeName))

    func apply(selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens
    }

    func clear() {
        store.shield.applications = nil
    }
}
```

- [ ] **Step 2: Add cleanup reset behavior to view model**

Create `PagePassControlSpike/SpikeViewModel.swift`:

```swift
import DeviceActivity
import FamilyControls
import Foundation

@MainActor
final class SpikeViewModel: ObservableObject {
    @Published var selection = FamilyActivitySelection()
    @Published var state = SpikeState()
    @Published var events: [SpikeEvent] = []
    @Published var message = "Ready"

    private let shield = ShieldController()
    private let center = DeviceActivityCenter()
    private let store: SpikeStateStore

    init(store: SpikeStateStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try .appGroup()
            } catch {
                fatalError("App Group unavailable. Fix group.com.pagepass.controlspike entitlements before running the spike.")
            }
        }
        self.state = (try? self.store.loadState()) ?? SpikeState()
        self.events = (try? self.store.loadEvents()) ?? []
    }

    func cleanupReset() {
        let activityNames = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        center.stopMonitoring(activityNames)
        shield.clear()
        store.reset()
        state = SpikeState(creditSeconds: 0, isShielded: false)
        events = []
        message = "Cleanup reset complete"
    }

    func lockSelectedApps() {
        guard !selection.applicationTokens.isEmpty else {
            message = "Select at least one app"
            return
        }
        shield.apply(selection: selection)
        state.isShielded = true
        try? store.saveSelection(selection)
        try? store.save(state)
        message = "Shield applied"
    }
}
```

- [ ] **Step 3: Build for simulator**

Run:

```bash
xcodebuild build -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

---

### Task 6: Add Authorization, Picker, And Minimal UI

**Files:**
- Create: `PagePassControlSpike/AuthorizationService.swift`
- Modify: `PagePassControlSpike/ContentView.swift`
- Modify: `PagePassControlSpike/SpikeViewModel.swift`

- [ ] **Step 1: Add child authorization service**

Create `PagePassControlSpike/AuthorizationService.swift`:

```swift
import FamilyControls

struct AuthorizationService {
    func requestChildAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .child)
    }
}
```

- [ ] **Step 2: Add authorization method to view model**

Insert this method inside `final class SpikeViewModel`, before the class's final `}`:

```swift
func requestAuthorization() async {
    do {
        try await AuthorizationService().requestChildAuthorization()
        message = "Child authorization granted"
    } catch {
        message = "Authorization failed: \(error.localizedDescription)"
    }
}

func refreshFromStore() {
    state = (try? store.loadState()) ?? state
    events = (try? store.loadEvents()) ?? events
}
```

- [ ] **Step 3: Replace content view**

Set `PagePassControlSpike/ContentView.swift` to:

```swift
import FamilyControls
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SpikeViewModel()
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Controls") {
                    Button("Request Screen Time Authorization") {
                        Task { await model.requestAuthorization() }
                    }
                    Button("Pick Limited Apps") {
                        showingPicker = true
                    }
                    Button("Lock Selected Apps") {
                        model.lockSelectedApps()
                    }
                    Button("Cleanup Reset") {
                        model.cleanupReset()
                    }
                }

                Section("State") {
                    Text(model.message)
                    Text("Credit: \(model.state.creditSeconds)s")
                    Text("Shielded: \(model.state.isShielded ? "yes" : "no")")
                    Text("Apps selected: \(model.selection.applicationTokens.count)")
                    Text("Run: \(model.state.activeRunID ?? "-")")
                    Text("Activity: \(model.state.activeActivityName ?? "-")")
                    Text("Event: \(model.state.activeEventName ?? "-")")
                    Text("intervalDidStart: \(model.state.intervalDidStart ? "yes" : "no")")
                    Text("Threshold: \(model.state.eventThresholdSeconds)s")
                    Text("Schedule: \(model.state.scheduleIntervalDescription)")
                    Text("Past activity: \(model.state.includesPastActivityEvidence)")
                }

                Section("Events") {
                    ForEach(model.events) { event in
                        VStack(alignment: .leading) {
                            Text(event.name)
                            Text(event.timestamp.formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("run: \(event.runID ?? "-")")
                            Text("activity: \(event.activityName ?? "-")")
                            Text("event: \(event.eventName ?? "-")")
                            Text("credit: \(event.creditBefore) -> \(event.creditAfter)")
                            Text("tokens: \(event.selectedApplicationTokenCount)")
                            if !event.detail.isEmpty {
                                Text(event.detail)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PagePass Spike")
            .familyActivityPicker(isPresented: $showingPicker, selection: $model.selection)
            .onAppear {
                model.refreshFromStore()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshFromStore()
                }
            }
        }
    }
}
```

- [ ] **Step 4: Build for simulator**

Run:

```bash
xcodebuild build -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

---

### Task 7: Add DeviceActivity Run Start Gate

**Files:**
- Create: `PagePassControlSpike/ActivityMonitorService.swift`
- Modify: `PagePassControlSpike/SpikeViewModel.swift`

- [ ] **Step 1: Add monitor service**

Create `PagePassControlSpike/ActivityMonitorService.swift`:

```swift
import DeviceActivity
import FamilyControls
import Foundation

struct ActivityMonitorService {
    private let center = DeviceActivityCenter()

    struct PreparedRun {
        let names: SpikeConstants.RunNames
        let activity: DeviceActivityName
        let eventName: DeviceActivityEvent.Name
        let schedule: DeviceActivitySchedule
        let event: DeviceActivityEvent
        let intervalStart: Date
        let intervalEnd: Date
        let scheduleDescription: String
        let includesPastActivityEvidence: String
    }

    func prepareRun(runID: String, selection: FamilyActivitySelection) -> PreparedRun {
        let names = SpikeConstants.names(for: runID)
        let activity = DeviceActivityName(names.activity)
        let eventName = DeviceActivityEvent.Name(names.event)

        let now = Date()
        let start = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let endDate = Calendar.current.date(byAdding: .minute, value: 15, to: now)!
        let end = Calendar.current.dateComponents([.hour, .minute, .second], from: endDate)
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)

        let event: DeviceActivityEvent
        let pastActivityEvidence: String
        if #available(iOS 17.4, *) {
            event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                threshold: DateComponents(second: SpikeConstants.eventThresholdSeconds),
                includesPastActivity: false
            )
            pastActivityEvidence = "includesPastActivity=false"
        } else {
            event = DeviceActivityEvent(
                applications: selection.applicationTokens,
                threshold: DateComponents(second: SpikeConstants.eventThresholdSeconds)
            )
            pastActivityEvidence = "includesPastActivity unavailable; require fresh intervalDidStart evidence"
        }

        return PreparedRun(
            names: names,
            activity: activity,
            eventName: eventName,
            schedule: schedule,
            event: event,
            intervalStart: now,
            intervalEnd: endDate,
            scheduleDescription: "15 minute non-repeating schedule from \(now.formatted()) to \(endDate.formatted())",
            includesPastActivityEvidence: pastActivityEvidence
        )
    }

    func startRun(_ run: PreparedRun) throws {
        let staleActivities = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        center.stopMonitoring(staleActivities)
        center.stopMonitoring([run.activity])
        try center.startMonitoring(run.activity, during: run.schedule, events: [run.eventName: run.event])
    }
}
```

- [ ] **Step 2: Add credited run start to view model**

Insert these methods inside `final class SpikeViewModel`, before the class's final `}`:

```swift
func startCreditedRun() {
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
    let prepared = monitor.prepareRun(runID: runID, selection: selection)

    SpikeReducer.apply(.monitoringStarted(runID: runID, activityName: names.activity, eventName: names.event), to: &state)
    state.eventThresholdSeconds = SpikeConstants.eventThresholdSeconds
    state.monitoringIntervalStart = prepared.intervalStart
    state.monitoringIntervalEnd = prepared.intervalEnd
    state.scheduleIntervalDescription = prepared.scheduleDescription
    state.includesPastActivityEvidence = prepared.includesPastActivityEvidence

    do {
        try store.saveSelection(selection)
        try store.save(state)
        try store.append(SpikeEvent(name: "monitoring start armed", activityName: names.activity, eventName: names.event, runID: runID, source: "app", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "\(prepared.scheduleDescription); \(prepared.includesPastActivityEvidence); active run metadata persisted before startMonitoring"))
    } catch {
        message = "App Group write failed before monitoring: \(error.localizedDescription)"
        return
    }

    do {
        try monitor.startRun(prepared)
        message = "Monitoring started. Wait for intervalDidStart before unlocking."
    } catch {
        shield.apply(selection: selection)
        try? store.append(SpikeEvent(name: "monitoring failed", activityName: names.activity, eventName: names.event, runID: runID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: error.localizedDescription))
        message = "Monitoring failed: \(error.localizedDescription)"
    }
}

func addCreditAfterIntervalStart() {
    refreshFromStore()
    guard state.intervalDidStart else {
        message = "intervalDidStart not observed yet"
        return
    }
    SpikeReducer.apply(.creditAdded(seconds: SpikeConstants.testCreditSeconds), to: &state)
    shield.clear()
    try? store.save(state)
    try? store.append(SpikeEvent(name: "credit added", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: 0, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count))
    message = "Credit added and shield cleared"
}

func recordNegativeControlPassed() {
    refreshFromStore()
    try? store.append(SpikeEvent(name: "negative control passed", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "tester used non-selected app longer than threshold and credit stayed unchanged"))
    refreshFromStore()
    message = "Negative control pass recorded"
}

func recordNegativeControlFailed() {
    refreshFromStore()
    try? store.append(SpikeEvent(name: "negative control failed", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "tester observed non-selected app usage affected credit or threshold"))
    refreshFromStore()
    message = "Negative control failure recorded"
}
```

- [ ] **Step 3: Add buttons to ContentView**

Insert these buttons in `ContentView` inside the `Section("Controls")` block, directly below the `Lock Selected Apps` button:

```swift
Button("Start Credited Run") {
    model.startCreditedRun()
}
Button("Refresh Extension Events") {
    model.refreshFromStore()
}
Button("Add Credit After intervalDidStart") {
    model.addCreditAfterIntervalStart()
}
Button("Run Negative-Control Test") {
    model.recordNegativeControlPassed()
}
Button("Record Negative-Control Failed") {
    model.recordNegativeControlFailed()
}
```

- [ ] **Step 4: Build for simulator**

Run:

```bash
xcodebuild build -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

---

### Task 8: Add Monitor Extension Callback

**Files:**
- Modify: `PagePassControlMonitor/PagePassDeviceActivityMonitor.swift`

- [ ] **Step 1: Replace monitor extension implementation**

Set `PagePassControlMonitor/PagePassDeviceActivityMonitor.swift` to:

```swift
import DeviceActivity
import FamilyControls
import ManagedSettings

final class PagePassDeviceActivityMonitor: DeviceActivityMonitor {
    private let managedStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(SpikeConstants.storeName))

    override func intervalDidStart(for activity: DeviceActivityName) {
        guard let store = try? SpikeStateStore.appGroup(),
              var state = try? store.loadState() else { return }
        guard state.activeActivityName == activity.rawValue,
              let runID = state.activeRunID else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: nil, runID: state.activeRunID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "intervalDidStart did not match active activity"))
            return
        }

        SpikeReducer.apply(.intervalDidStart(runID: runID), to: &state)
        try? store.save(state)
        try? store.append(SpikeEvent(name: "interval did start", activityName: activity.rawValue, eventName: state.activeEventName, runID: runID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "active run interval started"))
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard let store = try? SpikeStateStore.appGroup(),
              var state = try? store.loadState() else {
            return
        }
        guard let runID = state.activeRunID,
              state.activeActivityName == activity.rawValue,
              state.activeEventName == event.rawValue else {
            try? store.append(SpikeEvent(name: "stale callback ignored", activityName: activity.rawValue, eventName: event.rawValue, runID: state.activeRunID, source: "extension", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "threshold callback did not match active run"))
            return
        }

        let creditBefore = state.creditSeconds
        try? store.append(SpikeEvent(name: "threshold reached", activityName: activity.rawValue, eventName: event.rawValue, runID: runID, source: "extension", creditBefore: creditBefore, creditAfter: 0, selectedApplicationTokenCount: selectedTokenCount(store: store), detail: "matched active run and consumed credit"))
        SpikeReducer.apply(.thresholdReached(runID: runID, activityName: activity.rawValue, eventName: event.rawValue), to: &state)
        try? store.save(state)

        if let selection = try? store.loadSelection() {
            managedStore.shield.applications = selection.applicationTokens
        }
    }

    private func selectedTokenCount(store: SpikeStateStore) -> Int {
        ((try? store.loadSelection().applicationTokens.count) ?? 0)
    }
}
```

- [ ] **Step 2: Add shared files to extension target**

In Xcode File Inspector, add these files to both targets:

```text
PagePassControlSpike/Shared/SpikeConstants.swift
PagePassControlSpike/Shared/SpikeEvent.swift
PagePassControlSpike/Shared/SpikeState.swift
PagePassControlSpike/Shared/SpikeReducer.swift
PagePassControlSpike/Shared/SpikeStateStore.swift
```

- [ ] **Step 3: Build for physical device compile**

Run:

```bash
xcodebuild build -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'generic/platform=iOS'
```

Expected: build succeeds or fails only on provisioning entitlement availability. Any Swift compile error must be fixed before physical-device testing.

---

### Task 9: Physical Device Verification Checklist

**Files:**
- Create: `docs/manual-tests/screen-time-control-loop-checklist.md`

- [ ] **Step 1: Create manual test checklist**

Create `docs/manual-tests/screen-time-control-loop-checklist.md`:

```markdown
# Screen Time Control Loop Physical Test Checklist

## Device Setup

- [ ] Physical iPhone model:
- [ ] iOS version:
- [ ] Build number:
- [ ] App signing profile includes Family Controls and App Group.
- [ ] Monitor signing profile includes Family Controls and App Group.
- [ ] Device is signed into child Apple ID in Family Sharing.
- [ ] Guardian approval for `.child` authorization is available.
- [ ] Tap "Request Screen Time Authorization" in PagePass.
- [ ] Record authorization result text from PagePass:
- [ ] Authorization result says child authorization was granted.
- [ ] Downtime disabled.
- [ ] App Limits disabled for selected app.
- [ ] Always Allowed does not include selected app.

## Positive Foreground Run

- [ ] Cleanup reset run.
- [ ] Select exactly one application token.
- [ ] Record selected app name:
- [ ] Lock selected app and capture screenshot/video of the shield.
- [ ] Start credited run.
- [ ] Confirm run-specific activity name:
- [ ] Confirm run-specific event name:
- [ ] Record schedule interval shown in PagePass:
- [ ] Record event threshold seconds shown in PagePass:
- [ ] Record includesPastActivity evidence shown in PagePass:
- [ ] Wait for `intervalDidStart` event in PagePass log.
- [ ] Confirm intervalDidStart log shows matching run id, activity name, event name, credit before/after, and token count.
- [ ] Add credit after `intervalDidStart`.
- [ ] Confirm selected app unlocks and capture screenshot/video of the selected app opening.
- [ ] Use selected app until threshold.
- [ ] Confirm selected app re-shields before reopening PagePass and capture screenshot/video.
- [ ] Reopen PagePass; the event log refreshes automatically.
- [ ] Confirm extension event log has matching run id, activity name, event name, credit before/after, and token count.

## Negative Control Same Run Shape

- [ ] Cleanup reset run.
- [ ] Select exactly one application token.
- [ ] Record selected app name:
- [ ] Record non-selected app name:
- [ ] Start credited run.
- [ ] Wait for `intervalDidStart`.
- [ ] Add credit and unlock.
- [ ] Use non-selected app longer than threshold.
- [ ] Confirm credit unchanged.
- [ ] Record unchanged credit value:
- [ ] Tap "Run Negative-Control Test" in PagePass.
- [ ] Confirm event log includes `negative control passed`.
- [ ] If credit changed or threshold fired, tap "Record Negative-Control Failed" and stop the spike.
- [ ] Use selected app in same run.
- [ ] Confirm threshold fires and credit reaches zero; capture screenshot/video of re-shield.
- [ ] Confirm threshold event log has matching run id, activity name, event name, credit before/after, and token count.

## Background Variant

- [ ] Cleanup reset run.
- [ ] Select exactly one application token.
- [ ] Record selected app name:
- [ ] Start credited run.
- [ ] Wait for `intervalDidStart`.
- [ ] Add credit and unlock.
- [ ] Background PagePass before selected-app usage.
- [ ] Use selected app until threshold.
- [ ] Confirm re-shield before reopening PagePass and capture screenshot/video.
- [ ] Reopen PagePass; the event log refreshes automatically.
- [ ] Confirm extension-written event has matching run id, activity name, event name, credit before/after, and token count.

## Force-Quit Variant

- [ ] Cleanup reset run.
- [ ] Select exactly one application token.
- [ ] Record selected app name:
- [ ] Start credited run.
- [ ] Wait for `intervalDidStart`.
- [ ] Add credit and unlock.
- [ ] Force quit PagePass before selected-app usage.
- [ ] Use selected app until threshold.
- [ ] Confirm re-shield before reopening PagePass and capture screenshot/video.
- [ ] Reopen PagePass; the event log refreshes automatically.
- [ ] Confirm extension-written event has matching run id, activity name, event name, credit before/after, and token count.
```

- [ ] **Step 2: Build, install, and launch on connected device**

Run:

```bash
xcrun devicectl list devices
```

Copy the `Identifier` for the connected physical iPhone, then set:

```bash
export DEVICE_ID='<connected iPhone Identifier>'
```

Build into a deterministic DerivedData folder:

```bash
xcodebuild \
  -project PagePassControlSpike.xcodeproj \
  -scheme PagePassControlSpike \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/DerivedData \
  build
```

Expected: app builds and signs for the connected iPhone. If entitlement approval is missing, stop and request Family Controls entitlement before continuing.

Find the built app:

```bash
APP_PATH=$(find build/DerivedData/Build/Products -path '*Debug-iphoneos/PagePassControlSpike.app' -type d | head -1)
test -d "$APP_PATH"
echo "$APP_PATH"
```

Install the app:

```bash
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
```

Launch the app:

```bash
xcrun devicectl device process launch --device "$DEVICE_ID" com.pagepass.controlspike
```

Expected: `PagePassControlSpike` opens on the physical iPhone.

- [ ] **Step 3: Run checklist**

Open the app on the physical child device and complete:

```text
docs/manual-tests/screen-time-control-loop-checklist.md
```

Expected: every checkbox in Positive Foreground Run, Negative Control, Background Variant, and Force-Quit Variant is checked with evidence.

---

## Final Verification

Run automated checks:

```bash
xcodebuild test -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'platform=iOS Simulator,name=iPhone 16'
```

Run compile check:

```bash
xcodebuild build -project PagePassControlSpike.xcodeproj -scheme PagePassControlSpike -destination 'generic/platform=iOS'
```

Run physical verification:

```text
Complete docs/manual-tests/screen-time-control-loop-checklist.md on the child iPhone.
```

Pass condition:

```text
Automated tests pass.
Physical iOS build signs successfully.
Manual checklist proves foreground, background, force-quit, and negative-control flows.
```

Stop condition:

```text
Family Controls entitlement unavailable.
`.child` authorization unavailable.
DeviceActivity interval never starts.
Selected-app threshold never fires.
Re-shield can only be observed after reopening PagePass.
Non-selected app usage consumes credit.
```

## Self-Review

- Spec coverage: Covers entitlement setup, app-only selection, App Group state, named ManagedSettings store, run-specific monitor names, intervalDidStart gate, stale callback guard, threshold callback, negative control, background, and force-quit checks.
- Empty-marker scan: clear. Signing team is selected in Xcode because it is account-specific.
- Scope check: Backend, OCR, AI, parent app, subscriptions, and polish remain out of scope.
