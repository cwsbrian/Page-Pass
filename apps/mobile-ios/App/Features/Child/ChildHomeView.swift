import FamilyControls
import Foundation
import PagePassCore
import SwiftUI
import VisionKit

struct ChildHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ChildSessionStore()
    @State private var pairingStore = ChildPairingStore()
    @State private var showingEarnedTimePicker = false
    @State private var showingAlwaysAllowedPicker = false
    @State private var showingQRScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section("Child Device") {
                    TextField("Server URL", text: $pairingStore.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if pairingStore.isPaired {
                        LabeledContent("Child", value: pairingStore.childName ?? "Connected")
                        if let snapshot = pairingStore.snapshot {
                            LabeledContent(
                                "Server Balance",
                                value: Duration.seconds(snapshot.balanceSeconds)
                                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                            )
                        }

                        Button {
                            Task {
                                await syncWithServer()
                            }
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
                            Task {
                                if let snapshot = await pairingStore.pairWithCode() {
                                    store.applyServerSnapshot(snapshot)
                                }
                            }
                        } label: {
                            Label("Connect", systemImage: "link")
                        }
                        .disabled(pairingStore.isWorking)
                    }

                    if let message = pairingStore.errorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Screen Time") {
                    LabeledContent("Authorization", value: store.authorizationDescription)

                    Button {
                        Task { await store.requestChildAuthorization() }
                    } label: {
                        Label("Authorize This Child Device", systemImage: "checkmark.shield")
                    }
                    .disabled(store.isRequestingAuthorization)

                    if pairingStore.isPaired {
                        LabeledContent(
                            "Policy",
                            value: store.hasEarnedTimePolicy ? "Configured" : "Required"
                        )
                    } else {
                        Button {
                            showingEarnedTimePicker = true
                        } label: {
                            Label("Earned Time Apps", systemImage: "hourglass")
                        }

                        LabeledContent("Selected", value: "\(store.earnedTimeAppCount)")

                        Button {
                            showingAlwaysAllowedPicker = true
                        } label: {
                            Label("Always Allowed Apps", systemImage: "checkmark.circle")
                        }

                        LabeledContent("Always Allowed", value: "\(store.alwaysAllowedAppCount)")

                        Button {
                            store.savePolicy()
                        } label: {
                            Label("Save and Lock", systemImage: "lock.fill")
                        }
                        .disabled(store.earnedTimeAppCount == 0)
                    }
                }

                Section("Earned Time") {
                    LabeledContent("Balance", value: store.balanceDescription)
                    LabeledContent("Status", value: store.statusDescription)

                    if let session = store.activeSession {
                        SessionTimerView(session: session)
                    }
                }

                Section {
                    Button {
                        Task { await store.startMaximumSession() }
                    } label: {
                        Label("Use Earned Time", systemImage: "play.fill")
                    }
                    .disabled(!store.canStartSession)

                    if store.canStopSession {
                        Button(role: .destructive) {
                            store.stopSession()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }

                #if DEBUG
                Section("Verification") {
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

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("PagePass")
            .familyActivityPicker(
                isPresented: $showingEarnedTimePicker,
                selection: $store.earnedTimeSelection
            )
            .familyActivityPicker(
                isPresented: $showingAlwaysAllowedPicker,
                selection: $store.alwaysAllowedSelection
            )
            .sheet(isPresented: $showingQRScanner) {
                NavigationStack {
                    QRScannerView { token in
                        Task {
                            if let snapshot = await pairingStore.pairWithQRToken(token) {
                                store.applyServerSnapshot(snapshot)
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
            .task {
                store.reconcile()
                if let snapshot = await pairingStore.load() {
                    store.applyServerSnapshot(snapshot)
                    if !store.pendingSettlements.isEmpty {
                        await syncWithServer()
                    }
                }
            }
            .task(id: store.activeSession?.id) {
                guard let session = store.activeSession else { return }
                let delay = max(0, session.expiresAt.timeIntervalSinceNow)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                store.reconcile()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.reconcile()
                    if pairingStore.isPaired {
                        Task { await syncWithServer() }
                    }
                }
            }
            .onChange(of: store.pendingSettlements.count) { _, count in
                if count > 0, pairingStore.isPaired {
                    Task { await syncWithServer() }
                }
            }
        }
    }

    private func syncWithServer() async {
        if let result = await pairingStore.sync(settlements: store.pendingSettlements) {
            store.applyServerSync(result)
        }
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
