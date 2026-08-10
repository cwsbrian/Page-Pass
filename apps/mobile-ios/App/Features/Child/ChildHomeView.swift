import FamilyControls
import Foundation
import ManagedSettings
import PagePassCore
import SwiftUI
import VisionKit

struct ChildHomeView: View {
    let runtime: ChildRuntimeStore
    let onOpenEarn: () -> Void
    let onOpenMore: () -> Void
    @State private var showingEarnedTimeStart = false
    @State private var showingStopConfirmation = false
    @AccessibilityFocusState private var sessionControlFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if !runtime.hasLoaded {
                    Section {
                        ProgressView("Loading device status")
                    }
                } else if !runtime.pairing.isPaired || !runtime.pairing.isDeviceReady {
                    Section {
                        PagePassActionLabel(
                            title: runtime.pairing.isPaired
                                ? "Finish device setup to use Earned Time."
                                : "Connect this device to a parent account.",
                            systemImage: "exclamationmark.shield"
                        )
                        .foregroundStyle(PagePassTheme.warning)

                        Button(action: onOpenMore) {
                            PagePassActionLabel(
                                title: "Open Device Setup",
                                systemImage: "gearshape"
                            )
                        }
                    }
                }

                Section {
                    LabeledContent("Balance", value: runtime.session.balanceDescription)
                    LabeledContent("Status", value: runtime.session.statusDescription)

                    if let session = runtime.session.activeSession {
                        SessionTimerView(session: session)
                    }

                    if runtime.session.canStopSession {
                        Button(role: .destructive) {
                            showingStopConfirmation = true
                        } label: {
                            Label("Stop & Lock", systemImage: "stop.fill")
                        }
                        .accessibilityFocused($sessionControlFocused)
                    } else if runtime.session.canStartSession {
                        Button {
                            showingEarnedTimeStart = true
                        } label: {
                            Label("Use Earned Time", systemImage: "play.fill")
                        }
                        .accessibilityFocused($sessionControlFocused)
                    } else if runtime.session.state.balanceSeconds <
                        EarnedTimeSessionRules.minimumDurationSeconds {
                        Button(action: onOpenEarn) {
                            PagePassActionLabel(
                                title: "Earn Time",
                                systemImage: "book.badge.plus"
                            )
                                .padding(.leading, 2)
                                .padding(.vertical, 4)
                        }
                        .accessibilityFocused($sessionControlFocused)
                    } else {
                        Button {} label: {
                            Label("Use Earned Time", systemImage: "play.fill")
                        }
                        .accessibilityFocused($sessionControlFocused)
                        .disabled(true)
                    }
                } header: {
                    Text("Earned Time")
                        .font(.headline)
                        .lineLimit(nil)
                        .foregroundStyle(PagePassTheme.secondaryText)
                }

                Section {
                    Button(action: onOpenEarn) {
                        Label("Submit Reading Report", systemImage: "book.badge.plus")
                    }
                    Button(action: onOpenMore) {
                        Label("Managed Apps", systemImage: "square.grid.2x2")
                    }
                } header: {
                    Text("Quick Actions")
                        .font(.headline)
                        .lineLimit(nil)
                        .foregroundStyle(PagePassTheme.secondaryText)
                }

                if runtime.pairing.isPaired || runtime.pairing.isWorking {
                    Section {
                        if runtime.pairing.isWorking {
                            ProgressView("Syncing")
                        } else {
                            Button {
                                Task { await runtime.sync() }
                            } label: {
                                PagePassActionLabel(
                                    title: "Sync Now",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                            }
                        }

                        if let lastSyncedAt = runtime.pairing.snapshot?.lastSyncedAt {
                            LabeledContent("Last Sync", value: formattedDate(lastSyncedAt))
                        }
                    } header: {
                        Text("Sync")
                            .font(.headline)
                            .lineLimit(nil)
                            .foregroundStyle(PagePassTheme.secondaryText)
                    }
                }

                if let message = runtime.pairing.errorMessage ?? runtime.session.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(PagePassTheme.error)
                            .lineLimit(nil)
                    } header: {
                        Text("Needs Attention")
                            .font(.headline)
                            .lineLimit(nil)
                            .foregroundStyle(PagePassTheme.secondaryText)
                    }
                }
            }
            .contentMargins(.bottom, 120, for: .scrollContent)
            .navigationTitle("PagePass")
            .sheet(
                isPresented: $showingEarnedTimeStart,
                onDismiss: restoreSessionControlFocus
            ) {
                EarnedTimeStartSheet(runtime: runtime)
                    .presentationDetents([.medium, .large])
            }
            .sheet(
                isPresented: $showingStopConfirmation,
                onDismiss: restoreSessionControlFocus
            ) {
                if let session = runtime.session.activeSession {
                    StopEarnedTimeSheet(session: session) {
                        runtime.session.stopSession()
                    }
                    .presentationDetents([.medium])
                }
            }
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func restoreSessionControlFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            sessionControlFocused = true
        }
    }
}

private struct EarnedTimeStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: ChildRuntimeStore
    @State private var selectedOptionID: String?

    private var balanceSeconds: Int {
        runtime.session.state.balanceSeconds
    }

    private var options: [EarnedTimeDurationOption] {
        let maximum = min(
            balanceSeconds,
            EarnedTimeSessionRules.maximumDurationSeconds
        )
        let presets = runtime.session.sessionPresetSeconds.map {
            EarnedTimeDurationOption(id: "preset-\($0)", seconds: $0)
        }
        return presets + [
            EarnedTimeDurationOption(id: "maximum", seconds: maximum, isMaximum: true)
        ]
    }

    private var selectedOption: EarnedTimeDurationOption {
        options.first(where: { $0.id == selectedOptionID }) ?? options[0]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Duration") {
                    ForEach(options) { option in
                        let isSelected = option.id ==
                            (selectedOptionID ?? options.first?.id)
                        Button {
                            selectedOptionID = option.id
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .disabled(option.seconds > balanceSeconds)
                    }
                }

                Section("Session") {
                    LabeledContent(
                        "Unlocks",
                        value: "\(runtime.session.earnedTimeManagedAppCount) apps"
                    )
                    LabeledContent(
                        "Ends at",
                        value: Date()
                            .addingTimeInterval(TimeInterval(selectedOption.seconds))
                            .formatted(date: .omitted, time: .shortened)
                    )
                    LabeledContent(
                        "Balance afterward",
                        value: durationDescription(
                            max(0, balanceSeconds - selectedOption.seconds)
                        )
                    )
                }

                Section {
                    Button {
                        Task {
                            if await runtime.startSession(
                                durationSeconds: selectedOption.seconds
                            ) {
                                dismiss()
                            }
                        }
                    } label: {
                        Label(
                            "Start \(selectedOption.actionTitle)",
                            systemImage: "play.fill"
                        )
                    }
                    .disabled(
                        runtime.session.isStartingSession ||
                        selectedOption.seconds > balanceSeconds
                    )
                }

                if let message = runtime.session.errorMessage {
                    Section("Needs Attention") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Use Earned Time")
            .task {
                if selectedOptionID == nil {
                    selectedOptionID = options.first?.id
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct StopEarnedTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: EarnedTimeSession
    let stop: () -> Void

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let consumed = min(
                    session.requestedDurationSeconds,
                    max(0, Int(ceil(context.date.timeIntervalSince(session.startedAt))))
                )
                List {
                    Section {
                        LabeledContent("Used", value: durationDescription(consumed))
                        LabeledContent(
                            "Remaining credit",
                            value: durationDescription(
                                max(0, session.balanceBeforeSeconds - consumed)
                            )
                        )
                    }

                    Section {
                        Button(role: .destructive) {
                            stop()
                            dismiss()
                        } label: {
                            Label("Stop & Lock", systemImage: "stop.fill")
                        }
                        Button("Keep Using") { dismiss() }
                    }
                }
            }
            .navigationTitle("Stop Earned Time?")
        }
    }
}

private struct EarnedTimeDurationOption: Identifiable {
    let id: String
    let seconds: Int
    var isMaximum = false

    var title: String {
        isMaximum
            ? String(localized: "Max - \(durationDescription(seconds))")
            : durationDescription(seconds)
    }

    var actionTitle: String {
        isMaximum ? String(localized: "Max") : durationDescription(seconds)
    }
}

private func durationDescription(_ seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)
    )
}

struct ChildMoreView: View {
    @Bindable var store: ChildSessionStore
    @Bindable var pairingStore: ChildPairingStore
    let runtime: ChildRuntimeStore
    let onResetInstallation: () -> Void
    @State private var showingEarnedTimePicker = false
    @State private var showingQRScanner = false
    @State private var showingRevokedReset = false

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                screenTimeSection
                appAccessSection

                Section("Support") {
                    NavigationLink {
                        ChildDiagnosticsView(
                            store: store,
                            pairingStore: pairingStore
                        )
                    } label: {
                        Label("Device Diagnostics", systemImage: "stethoscope")
                    }
                    NavigationLink {
                        PagePassTroubleshootingView()
                    } label: {
                        Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        PagePassLegalDocumentView(document: .privacy)
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        PagePassAboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

                if pairingStore.isRevoked {
                    Section("Revoked Device") {
                        Label(
                            "A parent disconnected this device.",
                            systemImage: "iphone.slash"
                        )
                        .foregroundStyle(.orange)
                        Button(role: .destructive) {
                            showingRevokedReset = true
                        } label: {
                            Label("Reset Revoked Device", systemImage: "trash")
                        }
                    }
                }

                #if DEBUG
                Section("Screen Time Verification") {
                    Button {
                        store.loadVerificationCredit(seconds: 15 * 60)
                    } label: {
                        Label("Load 15 Minutes", systemImage: "timer")
                    }

                    Button {
                        store.loadVerificationCredit(seconds: 30 * 60)
                    } label: {
                        Label("Load 30 Minutes", systemImage: "clock.badge.checkmark")
                    }
                }
                #endif

                if let message = pairingStore.errorMessage ?? store.errorMessage {
                    Section("Needs Attention") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("More")
            .familyActivityPicker(
                isPresented: $showingEarnedTimePicker,
                selection: $store.earnedTimeSelection
            )
            .sheet(isPresented: $showingQRScanner) {
                NavigationStack {
                    QRScannerView { token in
                        Task {
                            if await runtime.pairWithQRToken(token) {
                                showingQRScanner = false
                            }
                        }
                    }
                    .navigationTitle("Scan Parent QR")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingQRScanner = false }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Reset this PagePass installation?",
                isPresented: $showingRevokedReset,
                titleVisibility: .visible
            ) {
                Button("Reset Device", role: .destructive) {
                    Task {
                        if await runtime.resetRevokedInstallation() {
                            onResetInstallation()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the revoked connection and PagePass restrictions from this device.")
            }
        }
    }

    private var deviceSection: some View {
        Section("Parent Connection") {
#if DEBUG
            TextField("Server URL", text: $pairingStore.serverURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif

            if pairingStore.isPaired {
                LabeledContent(
                    "Child",
                    value: pairingStore.childName ?? String(localized: "Connected")
                )
                LabeledContent(
                    "Device",
                    value: pairingStore.isDeviceReady ? "Ready" : "Setup Required"
                )

                Button {
                    Task { await runtime.sync() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(pairingStore.isWorking)
            } else {
                Button {
                    showingQRScanner = true
                } label: {
                    Label("Scan Parent QR", systemImage: "qrcode.viewfinder")
                }
                .disabled(!DataScannerViewController.isSupported)

                TextField("6-digit code", text: $pairingStore.numericCode)
                    .keyboardType(.numberPad)

                Button {
                    Task { await runtime.pairWithCode() }
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .disabled(pairingStore.isWorking)
            }
        }
    }

    private var screenTimeSection: some View {
        Section("Screen Time") {
            LabeledContent("Authorization", value: store.authorizationDescription)

            Button {
                Task { await store.requestChildAuthorization() }
            } label: {
                Label("Authorize This Child Device", systemImage: "checkmark.shield")
            }
            .disabled(store.isRequestingAuthorization)

            if pairingStore.isPaired, !pairingStore.isDeviceReady {
                Button {
                    Task { await runtime.completeSetup() }
                } label: {
                    Label("Complete Setup", systemImage: "checkmark.shield.fill")
                }
                .disabled(pairingStore.isWorking || store.managedApps.isEmpty)
            }
        }
    }

    private var appAccessSection: some View {
        Section("Managed Apps") {
            Button {
                showingEarnedTimePicker = true
            } label: {
                Label("Choose Managed Apps", systemImage: "square.grid.2x2")
            }

            LabeledContent("Selected", value: "\(store.managedAppCount)")

            Button {
                Task { await runtime.saveAndRegisterManagedApps() }
            } label: {
                Label("Save, Lock and Sync", systemImage: "lock.fill")
            }
            .disabled(
                !pairingStore.isPaired ||
                pairingStore.isWorking ||
                store.managedAppCount == 0
            )

            if store.managedApps.isEmpty {
                Text("No apps synced")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.managedApps) { app in
                    managedAppRow(app)
                }
            }
        }
    }

    private func managedAppRow(_ app: ManagedAppResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let token = applicationToken(for: app) {
                Label(token)
            } else {
                Label("Unavailable App", systemImage: "exclamationmark.triangle")
            }

            LabeledContent("Policy", value: app.policy.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let request = store.pendingRequest(for: app.id) {
                Label(
                    request.status == "pending" ? "Waiting for Parent" : "Decided",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await runtime.requestAccess(for: app.id) }
                } label: {
                    Label("Ask Parent", systemImage: "paperplane")
                }
                .disabled(pairingStore.isWorking)
            }
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

private struct ChildDiagnosticsView: View {
    @Bindable var store: ChildSessionStore
    @Bindable var pairingStore: ChildPairingStore

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent(
                    "Parent",
                    value: pairingStore.isPaired
                        ? String(localized: "Connected")
                        : String(localized: "Not Connected")
                )
                LabeledContent("Device", value: deviceStatus)
                if let snapshot = pairingStore.snapshot {
                    LabeledContent("Last Sync", value: formattedDate(snapshot.lastSyncedAt))
                    LabeledContent("Policy Version", value: String(snapshot.policyVersion))
                    LabeledContent("Ledger Revision", value: String(snapshot.ledgerRevision))
                }
            }

            Section("Screen Time") {
                LabeledContent("Authorization", value: store.authorizationDescription)
                LabeledContent(
                    "Earned Time Policy",
                    value: store.hasEarnedTimePolicy ? "Ready" : "Needs Setup"
                )
                LabeledContent("Managed Apps", value: String(store.managedAppCount))
                LabeledContent("Pending Settlements", value: String(store.pendingSettlements.count))
            }

            Section("App") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
            }

            Section {
                ShareLink(item: diagnosticText) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .refreshable {
            _ = await pairingStore.load()
        }
    }

    private var deviceStatus: String {
        if pairingStore.isRevoked { return String(localized: "Revoked") }
        if pairingStore.isDeviceReady { return String(localized: "Ready") }
        return pairingStore.isPaired
            ? String(localized: "Setup Required")
            : String(localized: "Not Paired")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? String(localized: "Unknown")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? String(localized: "Unknown")
    }

    private var diagnosticText: String {
        let snapshot = pairingStore.snapshot
        return [
            "PagePass Diagnostics",
            "App: \(appVersion) (\(appBuild))",
            "Parent: \(pairingStore.isPaired ? "Connected" : "Not Connected")",
            "Device: \(deviceStatus)",
            "Screen Time: \(store.authorizationDescription)",
            "Policy: \(store.hasEarnedTimePolicy ? "Ready" : "Needs Setup")",
            "Managed Apps: \(store.managedAppCount)",
            "Pending Settlements: \(store.pendingSettlements.count)",
            "Policy Version: \(snapshot.map { String($0.policyVersion) } ?? "Unavailable")",
            "Ledger Revision: \(snapshot.map { String($0.ledgerRevision) } ?? "Unavailable")",
            "Last Sync: \(snapshot?.lastSyncedAt ?? "Unavailable")"
        ].joined(separator: "\n")
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct SessionTimerView: View {
    let session: EarnedTimeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = remainingSeconds(at: context.date)
            let progress = 1 - Double(remaining) / Double(session.requestedDurationSeconds)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Remaining") {
                    Text(timerDescription(remaining))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }

                ProgressView(value: min(1, max(0, progress)))
                    .tint(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Earned Time remaining")
            .accessibilityValue(timerDescription(remaining))
        }
    }

    private func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(session.expiresAt.timeIntervalSince(date))))
    }

    private func timerDescription(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let seconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
