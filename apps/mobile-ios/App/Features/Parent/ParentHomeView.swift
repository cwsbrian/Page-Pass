import CoreImage.CIFilterBuiltins
import FamilyControls
import ManagedSettings
import SwiftUI
import UIKit

struct ParentHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    var onSignOut: (() async -> Void)?

    @State private var store: ParentHomeStore
    @State private var push = PagePassPushCoordinator.shared
    @State private var showingAddChild = false
    @State private var showingLegacyImport = false
    @State private var childName = ""
    @State private var legacyParentToken = ""
    @State private var readingDeepLink: ParentReadingDeepLink?
    @State private var creditTarget: ParentHomeChildResponse?

    init(
        store: ParentHomeStore? = nil,
        onSignOut: (() async -> Void)? = nil
    ) {
        self.onSignOut = onSignOut
        _store = State(
            initialValue: store ?? ParentHomeStore(onUnauthorized: onSignOut)
        )
    }

    var body: some View {
        NavigationStack {
            List {
#if DEBUG
                if ProcessInfo.processInfo.environment["PAGEPASS_UI_TEST_ROLE"] == nil {
                    Section("Server") {
                    TextField("Server URL", text: $store.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isWorking)
                    }
                }
#endif

                if store.pendingRequestCount > 0 || store.deviceAttentionCount > 0 {
                    Section {
                        if store.pendingRequestCount > 0 {
                            PagePassActionLabel(
                                title: "\(store.pendingRequestCount) requests waiting",
                                systemImage: "tray.full"
                            )
                        }
                        if store.deviceAttentionCount > 0 {
                            PagePassActionLabel(
                                title: store.deviceAttentionCount == 1
                                    ? "1 device needs attention"
                                    : "\(store.deviceAttentionCount) devices need attention",
                                systemImage: "exclamationmark.shield"
                            )
                            .foregroundStyle(PagePassTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Family")
                            .foregroundStyle(PagePassTheme.secondaryText)
                    }
                }

                Section {
                    if store.homeChildren.isEmpty {
                        ContentUnavailableView(
                            "No Child Profiles",
                            systemImage: "person.2"
                        )
                    } else {
                        ForEach(store.homeChildren) { child in
                            VStack(alignment: .leading, spacing: 10) {
                                NavigationLink {
                                    ParentChildAppAccessView(
                                        child: child.summary,
                                        store: store
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(child.name)
                                            .font(.headline)
                                            .lineLimit(nil)
                                        Text(balanceDescription(child.balanceSeconds))
                                            .monospacedDigit()
                                            .lineLimit(nil)
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Image(systemName: childStatusSymbol(child))
                                                .accessibilityHidden(true)
                                            Text(childStatus(child))
                                                .lineLimit(nil)
                                        }
                                        .font(.caption)
                                        .foregroundStyle(
                                            child.setupStatus == "ready"
                                                ? PagePassTheme.secondaryText
                                                : PagePassTheme.warning
                                        )
                                        .fixedSize(horizontal: false, vertical: true)
                                        if child.pendingAppRequestCount +
                                            child.pendingReadingCount > 0 {
                                            Text(
                                                "\(child.pendingAppRequestCount + child.pendingReadingCount) pending requests"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(PagePassTheme.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let lastSyncedAt = child.lastSyncedAt {
                                            Text("Last sync \(formattedDate(lastSyncedAt))")
                                                .font(.caption)
                                                .foregroundStyle(PagePassTheme.secondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }

                                childActions(child)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("Children")
                        .foregroundStyle(PagePassTheme.secondaryText)
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .contentMargins(.bottom, 72, for: .scrollContent)
            .navigationTitle("Family")
            .navigationDestination(item: $readingDeepLink) { target in
                if let submission = store.readingSubmissionsByChild[target.childID]?
                    .first(where: { $0.id == target.submissionID }) {
                    ParentReadingReviewView(
                        childID: target.childID,
                        submission: submission,
                        store: store,
                        isReadOnly: !store.children.contains {
                            $0.id == target.childID
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Report Unavailable",
                        systemImage: "book.closed"
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddChild = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add child")
                }
                if let onSignOut {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) {
                            Task { await onSignOut() }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            showingLegacyImport = true
                        } label: {
                            Label("Import Previous Family", systemImage: "arrow.down.doc")
                        }
                    }
                }
            }
            .task {
                await store.refresh()
                if let token = push.deviceToken {
                    await store.registerPushDevice(token: token)
                }
                await push.requestRegistration()
                openReadingDeepLink()
            }
            .refreshable {
                await store.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await store.refresh() }
            }
            .onChange(of: push.deviceToken) { _, token in
                guard let token else { return }
                Task { await store.registerPushDevice(token: token) }
            }
            .onChange(of: push.eventRevision) {
                Task {
                    await store.refresh()
                    openReadingDeepLink()
                }
            }
            .sheet(isPresented: $showingAddChild) {
                NavigationStack {
                    Form {
                        TextField("Child name", text: $childName)
                    }
                    .navigationTitle("New Child")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingAddChild = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                Task {
                                    if await store.createChild(name: childName) {
                                        childName = ""
                                        showingAddChild = false
                                    }
                                }
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $store.pairingSession) { session in
                PairingSessionView(session: session)
            }
            .sheet(item: $creditTarget) { child in
                ParentAddTimeSheet(child: child.summary, store: store)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingLegacyImport) {
                NavigationStack {
                    Form {
                        SecureField("Previous parent token", text: $legacyParentToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let message = store.errorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        }
                    }
                    .navigationTitle("Import Family")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingLegacyImport = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") {
                                Task {
                                    if await store.claimLocalData(
                                        localParentToken: legacyParentToken
                                    ) {
                                        legacyParentToken = ""
                                        showingLegacyImport = false
                                    }
                                }
                            }
                            .disabled(legacyParentToken.isEmpty || store.isWorking)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func balanceDescription(_ seconds: Int) -> String {
        Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    @ViewBuilder
    private func childActions(_ child: ParentHomeChildResponse) -> some View {
        let connect = Button {
            Task { await store.createPairingSession(childID: child.id) }
        } label: {
            PagePassActionLabel(title: "Connect", systemImage: "link")
        }
        let addTime = Button {
            creditTarget = child
        } label: {
            PagePassActionLabel(title: "Add Time", systemImage: "plus.circle")
        }

        VStack(alignment: .leading, spacing: 12) {
            connect
            addTime
        }
    }

    private func childStatus(_ child: ParentHomeChildResponse) -> String {
        if child.setupStatus == "no_device" { return String(localized: "Not connected") }
        if child.setupStatus == "pending_setup" {
            return String(localized: "Setup required")
        }
        if let session = child.activeSession {
            return String(localized: "Active until \(formattedDate(session.expiresAt))")
        }
        return String(localized: "Locked")
    }

    private func childStatusSymbol(_ child: ParentHomeChildResponse) -> String {
        if child.setupStatus != "ready" { return "exclamationmark.shield" }
        return child.activeSession == nil ? "lock.fill" : "timer"
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func openReadingDeepLink() {
        guard push.eventType == "reading_submission_submitted",
              let childID = push.childProfileID,
              let submissionID = push.readingSubmissionID,
              store.children.contains(where: { $0.id == childID }),
              store.readingSubmissionsByChild[childID]?
                .contains(where: { $0.id == submissionID }) == true else {
            return
        }
        readingDeepLink = ParentReadingDeepLink(
            childID: childID,
            submissionID: submissionID
        )
        push.clearReadingDeepLink()
    }
}

private struct ParentReadingDeepLink: Identifiable, Hashable {
    let childID: String
    let submissionID: String

    var id: String { submissionID }
}

private struct ParentAddTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let child: ChildSummary
    @Bindable var store: ParentHomeStore
    @State private var selectedPreset = "900"
    @State private var customMinutes = "45"
    @State private var reason = String(localized: "Parent added time")

    private var selectedSeconds: Int? {
        if selectedPreset != "custom" {
            return Int(selectedPreset)
        }
        guard let minutes = Int(customMinutes), (1...1_440).contains(minutes) else {
            return nil
        }
        return minutes * 60
    }

    private var currentBalance: Int {
        store.homeChildren.first(where: { $0.id == child.id })?.balanceSeconds
            ?? child.balanceSeconds
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Time") {
                    Picker("Amount", selection: $selectedPreset) {
                        Text("15m").tag("900")
                        Text("30m").tag("1800")
                        Text("1h").tag("3600")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)

                    if selectedPreset == "custom" {
                        TextField("Minutes", text: $customMinutes)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Reason") {
                    TextField("Why are you adding time?", text: $reason)
                }

                if let selectedSeconds {
                    Section("Summary") {
                        LabeledContent(
                            "Add",
                            value: parentDuration(selectedSeconds)
                        )
                        LabeledContent(
                            "New balance",
                            value: parentDuration(currentBalance + selectedSeconds)
                        )
                    }
                }

                Section {
                    Button {
                        guard let selectedSeconds else { return }
                        Task {
                            if await store.grantCredit(
                                childID: child.id,
                                seconds: selectedSeconds,
                                reason: reason
                            ) {
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Add Time", systemImage: "plus.circle.fill")
                    }
                    .disabled(
                        selectedSeconds == nil ||
                        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        store.isWorking
                    )
                }

                if let message = store.errorMessage {
                    Section("Needs Attention") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Time for \(child.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func parentDuration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }
}

struct ParentChildAppAccessView: View {
    let child: ChildSummary
    @Bindable var store: ParentHomeStore
    @State private var push = PagePassPushCoordinator.shared
    @State private var devicePendingRevoke: ParentChildDeviceResponse?
    @State private var showingAddTime = false

    private var access: AppAccessResponse? {
        store.appAccessByChild[child.id]
    }

    private var pendingRequests: [AppRequestResponse] {
        access?.requests.filter { $0.status == "pending" } ?? []
    }

    private var pendingReading: [ReadingSubmissionResponse] {
        store.readingSubmissionsByChild[child.id]?
            .filter { $0.status == "pending" } ?? []
    }

    private var devices: [ParentChildDeviceResponse] {
        store.devicesByChild[child.id] ?? []
    }

    private var ledger: [CreditLedgerEntryResponse] {
        store.ledgerByChild[child.id] ?? []
    }

    var body: some View {
        List {
            Section("Devices") {
                if devices.isEmpty {
                    ContentUnavailableView(
                        "No Connected Devices",
                        systemImage: "iphone.slash"
                    )
                } else {
                    ForEach(devices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(device.deviceName, systemImage: "iphone")
                                    .font(.headline)
                                Spacer()
                                Text(deviceStatus(device.status))
                                    .font(.caption)
                                    .foregroundStyle(
                                        device.status == "active"
                                            ? Color.green
                                            : Color.secondary
                                    )
                            }
                            Text("PagePass \(device.appVersion) (\(device.appBuild))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let lastSeenAt = device.lastSeenAt {
                                Text("Last sync \(formattedDate(lastSeenAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let report = device.latestStatus {
                                LabeledContent(
                                    "Screen Time",
                                    value: authorizationStatus(
                                        report.authorizationStatus
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    report.authorizationStatus == "approved"
                                        ? Color.secondary
                                        : PagePassTheme.error
                                )
                                LabeledContent(
                                    "App Control",
                                    value: controlStatus(report.controlStatus)
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    isControlStatusHealthy(report.controlStatus)
                                        ? Color.secondary
                                        : PagePassTheme.error
                                )
                                Text(
                                    "Observed \(formattedDate(report.observedAt))"
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    isStatusStale(report.observedAt)
                                        ? PagePassTheme.warning
                                        : Color.secondary
                                )
                                if isStatusStale(report.observedAt) {
                                    Label(
                                        "Device status is out of date",
                                        systemImage: "clock.badge.exclamationmark"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(PagePassTheme.warning)
                                }
                                if report.pendingSettlementCount > 0 {
                                    Label(
                                        "\(report.pendingSettlementCount) pending time sync",
                                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(PagePassTheme.warning)
                                }
                            } else if device.status == "active" {
                                Label(
                                    "No device status received",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(PagePassTheme.warning)
                            }
                            if device.canRevoke {
                                Button(role: .destructive) {
                                    devicePendingRevoke = device
                                } label: {
                                    Label("Revoke Device", systemImage: "iphone.slash")
                                }
                                .disabled(store.isWorking)
                            }
                        }
                    }
                }

                Button {
                    Task { await store.createPairingSession(childID: child.id) }
                } label: {
                    Label("Connect Replacement", systemImage: "link.badge.plus")
                }
                .disabled(store.isWorking)
            }

            Section("Balance History") {
                Button {
                    showingAddTime = true
                } label: {
                    Label("Add Time", systemImage: "plus.circle")
                }
                .disabled(store.isWorking)

                if ledger.isEmpty {
                    ContentUnavailableView(
                        "No Balance Activity",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    ForEach(ledger) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(ledgerTitle(entry.entryType))
                                    .font(.headline)
                                Spacer()
                                Text(signedDuration(entry.amountSeconds))
                                    .font(.headline)
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        entry.amountSeconds > 0
                                            ? Color.green
                                            : Color.primary
                                    )
                            }
                            if let reason = entry.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(formattedDate(entry.createdAt))
                                Spacer()
                                Text("Balance \(duration(entry.balanceAfterSeconds))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if store.ledgerNextCursorByChild[child.id] != nil {
                    Button {
                        Task { await store.loadMoreLedger(childID: child.id) }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isWorking)
                }
            }

            Section("Reading Reports") {
                if pendingReading.isEmpty {
                    ContentUnavailableView(
                        "No Pending Reports",
                        systemImage: "book.closed"
                    )
                } else {
                    ForEach(pendingReading) { submission in
                        NavigationLink {
                            ParentReadingReviewView(
                                childID: child.id,
                                submission: submission,
                                store: store
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(submission.bookTitle ?? "Untitled Book")
                                    .font(.headline)
                                Text("\(submission.evidence.count) pages")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Requests") {
                if pendingRequests.isEmpty {
                    ContentUnavailableView(
                        "No Pending Requests",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ForEach(pendingRequests) { request in
                        VStack(alignment: .leading, spacing: 10) {
                            appLabel(managedAppID: request.managedAppId)
                            if let message = request.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    decide(request, as: .earnedTime)
                                } label: {
                                    Label("Earned", systemImage: "hourglass")
                                }
                                Spacer()
                                Button {
                                    decide(request, as: .alwaysAllowed)
                                } label: {
                                    Label("Allow", systemImage: "checkmark.circle")
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    decide(request, as: .blocked)
                                } label: {
                                    Label("Deny", systemImage: "xmark.circle")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.isWorking)
                        }
                    }
                }
            }

            Section("Managed Apps") {
                if let access, !access.apps.isEmpty {
                    ForEach(access.apps) { app in
                        HStack {
                            appLabel(app)
                            Spacer()
                            Menu {
                                policyButton(.blocked, app: app)
                                policyButton(.earnedTime, app: app)
                                policyButton(.alwaysAllowed, app: app)
                            } label: {
                                Label(
                                    app.policy.displayName,
                                    systemImage: "slider.horizontal.3"
                                )
                            }
                            .disabled(store.isWorking)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Managed Apps",
                        systemImage: "square.grid.2x2"
                    )
                }
            }

            if let access {
                Section {
                    LabeledContent("Policy Version", value: "\(access.policyVersion)")
                }
            }

            if let message = store.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(child.name)
        .sheet(isPresented: $showingAddTime) {
            ParentAddTimeSheet(child: child, store: store)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(
                get: { devicePendingRevoke != nil },
                set: { if !$0 { devicePendingRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: devicePendingRevoke
        ) { device in
            Button("Revoke \(device.deviceName)", role: .destructive) {
                Task {
                    await store.revokeDevice(
                        childID: child.id,
                        deviceID: device.id
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("PagePass on this device will lose access. Active Earned Time must be stopped and synced first.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refreshDevices(childID: child.id)
                        await store.refreshAppAccess(childID: child.id)
                        await store.refreshReading(childID: child.id)
                        await store.refreshLedger(childID: child.id)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh app access")
                .disabled(store.isWorking)
            }
        }
        .task {
            await store.refreshDevices(childID: child.id)
            await store.refreshAppAccess(childID: child.id)
            await store.refreshReading(childID: child.id)
            await store.refreshLedger(childID: child.id)
        }
        .onChange(of: push.eventRevision) {
            guard push.childProfileID == child.id else {
                return
            }
            Task {
                if push.eventType == "reading_submission_submitted" {
                    await store.refreshReading(childID: child.id)
                } else {
                    await store.refreshAppAccess(childID: child.id)
                }
            }
        }
        .refreshable {
            await store.refreshDevices(childID: child.id)
            await store.refreshAppAccess(childID: child.id)
            await store.refreshReading(childID: child.id)
            await store.refreshLedger(childID: child.id)
        }
    }

    private func deviceStatus(_ value: String) -> String {
        switch value {
        case "pending_setup": String(localized: "Setup Required")
        case "active": String(localized: "Active")
        case "retired": String(localized: "Replaced")
        case "revoked": String(localized: "Revoked")
        default: value
        }
    }

    private func authorizationStatus(_ value: String) -> String {
        switch value {
        case "approved": String(localized: "Approved")
        case "not_determined": String(localized: "Not Determined")
        case "denied": String(localized: "Denied")
        case "restricted": String(localized: "Restricted")
        case "revoked": String(localized: "Revoked")
        case "conflict": String(localized: "Authorization Conflict")
        default: String(localized: "Unavailable")
        }
    }

    private func controlStatus(_ value: String) -> String {
        switch value {
        case "policy_applied": String(localized: "Policy Applied")
        case "unlocked_for_session": String(localized: "Earned Time Active")
        case "policy_application_failed": String(localized: "Application Failed")
        default: String(localized: "Unknown")
        }
    }

    private func isControlStatusHealthy(_ value: String) -> Bool {
        value == "policy_applied" || value == "unlocked_for_session"
    }

    private func isStatusStale(_ value: String) -> Bool {
        guard let date = try? Date(value, strategy: .iso8601) else { return true }
        return Date().timeIntervalSince(date) > 24 * 60 * 60
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func ledgerTitle(_ value: String) -> String {
        switch value {
        case "parent_grant": String(localized: "Parent Added Time")
        case "reading_reward": String(localized: "Reading Reward")
        case "session_spend": String(localized: "Earned Time Used")
        case "parent_adjustment": String(localized: "Parent Adjustment")
        default: String(localized: "Balance Updated")
        }
    }

    private func signedDuration(_ seconds: Int) -> String {
        let sign = seconds > 0 ? "+" : seconds < 0 ? "-" : ""
        return sign + duration(abs(seconds))
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)
        )
    }

    @ViewBuilder
    private func appLabel(managedAppID: String) -> some View {
        if let app = access?.apps.first(where: { $0.id == managedAppID }) {
            appLabel(app)
        } else {
            Label("Unavailable App", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func appLabel(_ app: ManagedAppResponse) -> some View {
        if let token = applicationToken(for: app) {
            Label(token)
        } else {
            Label("Unavailable App", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func policyButton(
        _ policy: ManagedAppPolicyValue,
        app: ManagedAppResponse
    ) -> some View {
        Button {
            Task {
                await store.updatePolicy(
                    childID: child.id,
                    managedAppID: app.id,
                    policy: policy
                )
            }
        } label: {
            Label(policy.displayName, systemImage: policy.systemImage)
        }
        .disabled(app.policy == policy)
    }

    private func decide(
        _ request: AppRequestResponse,
        as policy: ManagedAppPolicyValue
    ) {
        Task {
            await store.decideRequest(
                childID: child.id,
                request: request,
                policy: policy
            )
        }
    }

    private func applicationToken(
        for app: ManagedAppResponse
    ) -> ApplicationToken? {
        guard app.tokenFormatVersion == 1,
              let data = Data(base64Encoded: app.tokenEnvelope),
              let selection = try? JSONDecoder().decode(
                FamilyActivitySelection.self,
                from: data
              ),
              selection.applicationTokens.count == 1 else {
            return nil
        }
        return selection.applicationTokens.first
    }
}

struct ParentReadingReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let childID: String
    let submission: ReadingSubmissionResponse
    @Bindable var store: ParentHomeStore
    let isReadOnly: Bool

    @State private var comment = ""
    @State private var rewardMinutes = 15
    @State private var mediaURLs: [String: URL] = [:]

    init(
        childID: String,
        submission: ReadingSubmissionResponse,
        store: ParentHomeStore,
        isReadOnly: Bool = false
    ) {
        self.childID = childID
        self.submission = submission
        self.store = store
        self.isReadOnly = isReadOnly
    }

    private var orderedEvidence: [ReadingEvidenceResponse] {
        submission.evidence.sorted { $0.pageOrder < $1.pageOrder }
    }

    private var rawTranscript: String {
        orderedEvidence
            .compactMap(\.rawOcrText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var body: some View {
        List {
            Section("Book") {
                LabeledContent("Title", value: submission.bookTitle ?? "Untitled")
                if let author = submission.author {
                    LabeledContent("Author", value: author)
                }
            }

            ForEach(orderedEvidence) { evidence in
                Section("Page \(evidence.pageOrder + 1)") {
                    if let url = mediaURLs[evidence.originalMediaId] {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                ContentUnavailableView(
                                    "Image Unavailable",
                                    systemImage: "photo.badge.exclamationmark"
                                )
                            default:
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }

                    if let text = evidence.rawOcrText, !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                    } else {
                        Text("No text recognized")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let corrected = submission.correctedOcrText,
               corrected != rawTranscript {
                Section("Edited Transcript") {
                    Text(corrected)
                        .textSelection(.enabled)
                }
            }

            if !submission.reviews.isEmpty {
                Section("Review History") {
                    ForEach(submission.reviews) { review in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                review.decision.readingStatusName,
                                systemImage: review.decision.readingStatusSymbol
                            )
                            if let comment = review.comment {
                                Text(comment)
                                    .foregroundStyle(.secondary)
                            }
                            if review.rewardSeconds > 0 {
                                Text(Duration.seconds(review.rewardSeconds).formatted())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if submission.status == "pending" && !isReadOnly {
                Section("Decision") {
                    TextField("Comment", text: $comment, axis: .vertical)
                        .lineLimit(3...6)

                    Picker("Reward", selection: $rewardMinutes) {
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }

                    Button {
                        review(decision: "approved", rewardSeconds: rewardMinutes * 60)
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(store.isWorking)

                    Button {
                        review(decision: "changes_requested", rewardSeconds: 0)
                    } label: {
                        Label("Request Changes", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(store.isWorking || commentIsEmpty)

                    Button(role: .destructive) {
                        review(decision: "rejected", rewardSeconds: 0)
                    } label: {
                        Label("Reject", systemImage: "xmark.circle")
                    }
                    .disabled(store.isWorking || commentIsEmpty)
                }
            }

            if let message = store.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isReadOnly ? "Reading Report" : "Review Report")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMediaURLs() }
        .task {
            if let reward = store.familyPreferences?.defaultReadingRewardSeconds {
                rewardMinutes = reward / 60
            }
        }
    }

    private var commentIsEmpty: Bool {
        comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadMediaURLs() async {
        for evidence in orderedEvidence where mediaURLs[evidence.originalMediaId] == nil {
            if let url = await store.readingMediaURL(mediaID: evidence.originalMediaId) {
                mediaURLs[evidence.originalMediaId] = url
            }
        }
    }

    private func review(decision: String, rewardSeconds: Int) {
        Task {
            if await store.reviewReadingSubmission(
                childID: childID,
                submission: submission,
                decision: decision,
                comment: comment,
                rewardSeconds: rewardSeconds
            ) {
                dismiss()
            }
        }
    }
}

extension String {
    var readingStatusName: String {
        switch self {
        case "approved": "Approved"
        case "changes_requested": "Changes Requested"
        case "rejected": "Rejected"
        case "pending": "Pending"
        default: capitalized
        }
    }

    var readingStatusSymbol: String {
        switch self {
        case "approved": "checkmark.circle.fill"
        case "changes_requested": "arrow.uturn.backward.circle"
        case "rejected": "xmark.circle.fill"
        default: "clock"
        }
    }
}

private extension ManagedAppPolicyValue {
    var systemImage: String {
        switch self {
        case .blocked: "lock"
        case .earnedTime: "hourglass"
        case .alwaysAllowed: "checkmark.circle"
        }
    }
}

private struct PairingSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let session: PairingSessionResponse

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = qrImage(payload: session.qrToken) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .accessibilityLabel("Child pairing QR code")
                }

                Text(session.numericCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)

                Text("Expires \(session.expiresAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Connect Child")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func qrImage(payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 12, y: 12)) else {
            return nil
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
