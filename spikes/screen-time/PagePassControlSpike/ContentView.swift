import FamilyControls
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SpikeViewModel()
    @State private var showingPicker = false
    @State private var showingRequestPicker = false
    @State private var showingEmptyPickerWarning = false
    @State private var showingInvalidRequestWarning = false

    var body: some View {
        NavigationStack {
            List {
                Section("Gate A Status") {
                    Text(model.message)
                    Text("Authorization: \(model.authorizationStatusDescription)")
                    Text("Managed apps: \(model.managedApps.count)")
                    Text("Policy: v\(model.managedPolicyVersion), applied v\(model.appliedManagedPolicyVersion)")
                    Text("Shield engine: category + explicit apps")
                    Text("Mode: \(model.state.enforcementMode.rawValue)")
                    Text("Credit: \(model.state.creditSeconds)s")
                    Text("intervalDidStart: \(model.state.intervalDidStart ? "yes" : "no")")
                    Text("Baseline: \(model.state.monitoringCompromised ? "compromised" : "valid")")
                }
                .font(.caption)

                Section("Gate A - Child Request") {
                    controlButton("1. Pick One App to Request", systemImage: "square.grid.2x2") {
                        model.requestSelection = FamilyActivitySelection(includeEntireCategory: false)
                        showingRequestPicker = true
                    }
                    Text("Request selection: \(model.requestSelection.applicationTokens.count) app")
                    ForEach(Array(model.requestSelection.applicationTokens), id: \.self) { token in
                        Label(token)
                    }
                    controlButton("2. Create or Reuse Request", systemImage: "paperplane") {
                        model.createAppRequest()
                    }
                    Text("Request payload: copy child → parent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.requestEnvelopePayload)
                        .frame(minHeight: 96)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !model.requestEnvelopePayload.isEmpty {
                        ShareLink(item: model.requestEnvelopePayload) {
                            Label("Share Request Payload", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Gate A - Parent Console") {
                    controlButton("3. Import Child Request", systemImage: "square.and.arrow.down") {
                        model.importAppRequest()
                    }

                    if model.managedApps.isEmpty {
                        Text("No managed app requests")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.managedApps) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                if let token = record.applicationToken {
                                    Label(token)
                                } else {
                                    Label("Invalid app token", systemImage: "exclamationmark.triangle")
                                }
                                Text("\(record.status.displayName) · item v\(record.policyVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    Button("Blocked", systemImage: "lock") {
                                        model.setParentStatus(.blocked, requestID: record.requestID)
                                    }
                                    Button("Earned Time", systemImage: "hourglass") {
                                        model.setParentStatus(.earnedTime, requestID: record.requestID)
                                    }
                                    Button("Always Allowed", systemImage: "checkmark.circle") {
                                        model.setParentStatus(.alwaysAllowed, requestID: record.requestID)
                                    }
                                } label: {
                                    Label("Set Parent Policy", systemImage: "slider.horizontal.3")
                                }
                            }
                        }
                    }

                    controlButton("4. Export Full Parent Policy", systemImage: "square.and.arrow.up") {
                        model.exportParentPolicy()
                    }
                    Text("Policy payload: copy parent → child")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.policyEnvelopePayload)
                        .frame(minHeight: 96)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !model.policyEnvelopePayload.isEmpty {
                        ShareLink(item: model.policyEnvelopePayload) {
                            Label("Share Policy Payload", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Gate A - Child Enforcement") {
                    controlButton("5. Import Parent Policy", systemImage: "square.and.arrow.down") {
                        model.importParentPolicy()
                    }
                    controlButton("6. Apply at Zero Credit", systemImage: "lock") {
                        model.applyManagedPolicyAtZeroCredit()
                    }
                    controlButton("7. Start Earned-Time Proof", systemImage: "hourglass") {
                        model.startManagedQuantizedProofRun()
                    }
                    controlButton("8. Refresh Extension Events", systemImage: "arrow.clockwise") {
                        model.refreshFromStore()
                    }
                    controlButton("9. Add Credit After intervalDidStart", systemImage: "lock.open") {
                        model.addManagedProofCreditAfterIntervalStart()
                    }
                    Text("Earned Time usage should debit. Always Allowed and unregistered usage should not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                Section("Legacy Controls") {
                    controlButton("Request Child Authorization") {
                        Task { await model.requestAuthorization() }
                    }
                    controlButton("Request Individual Authorization") {
                        Task { await model.requestIndividualAuthorization() }
                    }
                    controlButton("Revoke Screen Time Authorization") {
                        Task { await model.revokeAuthorization() }
                    }
                    controlButton("Pick Limited Apps") {
                        showingPicker = true
                    }
                    NavigationLink("Open Inline Picker") {
                        FamilyActivityPicker(selection: $model.selection)
                    }
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
                    controlButton("Lock Selected Apps") {
                        model.lockSelectedApps()
                    }
                    controlButton("Start Quantized Proof Run") {
                        model.startQuantizedProofRun()
                    }
                    controlButton("Start Fallback Proof Run") {
                        model.startFallbackProofRun()
                    }
                    controlButton("Start 15-Min Wall-Clock Session") {
                        model.startWallClockSessionProof(balanceSeconds: 1800, durationSeconds: 900)
                    }
                    controlButton("Stop Wall-Clock Session") {
                        model.stopWallClockSessionProof()
                    }
                    controlButton("Refresh Extension Events") {
                        model.refreshFromStore()
                    }
                    controlButton("Add Proof Credit After intervalDidStart") {
                        model.addProofCreditAfterIntervalStart()
                    }
                    controlButton("Record Negative-Control Passed") {
                        model.recordNegativeControlPassed()
                    }
                    controlButton("Record Negative-Control Failed") {
                        model.recordNegativeControlFailed()
                    }
                    controlButton("Cleanup Reset") {
                        model.cleanupReset()
                    }
                }
                #endif

                Section("State") {
                    Text("Authorization: \(model.authorizationStatusDescription)")
                    Text("Credit: \(model.state.creditSeconds)s")
                    Text("Shielded: \(model.state.isShielded ? "yes" : "no")")
                    Text("Apps selected: \(model.selection.applicationTokens.count)")
                    Text("Run: \(model.state.activeRunID ?? "-")")
                    Text("Activity: \(model.state.activeActivityName ?? "-")")
                    Text("Event: \(model.state.activeEventName ?? "-")")
                    Text("intervalDidStart: \(model.state.intervalDidStart ? "yes" : "no")")
                    Text("Threshold: \(model.state.eventThresholdSeconds)s")
                    Text("Deduction path: \(model.state.deductionPath.rawValue)")
                    Text("Credit grant: \(model.state.creditGrantSeconds)s")
                    Text("Threshold hits: \(model.state.thresholdReachedCount)")
                    Text("Schedule: \(model.state.scheduleIntervalDescription)")
                    Text("Past activity: \(model.state.includesPastActivityEvidence)")
                    Text("Enforcement mode: \(model.state.enforcementMode.rawValue)")
                }

                Section("Usage Attribution") {
                    if let start = model.state.monitoringIntervalStart,
                       let end = model.state.monitoringIntervalEnd,
                       !model.monitoringSelection.applicationTokens.isEmpty {
                        NavigationLink("Open Usage Diagnostic") {
                            UsageDiagnosticView(
                                selection: model.monitoringSelection,
                                intervalStart: start,
                                intervalEnd: end
                            )
                        }
                    } else {
                        Text("Start a proof run to create a diagnostic window")
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.selection.applicationTokens.isEmpty {
                    Section("Selected Apps") {
                        ForEach(Array(model.selection.applicationTokens), id: \.self) { token in
                            Label(token)
                        }
                    }
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
                            Text("source: \(event.source)")
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
            .familyActivityPicker(isPresented: $showingRequestPicker, selection: $model.requestSelection)
            .onChange(of: showingPicker) { wasShowing, isShowing in
                if wasShowing && !isShowing && selectionIsEmpty {
                    showingEmptyPickerWarning = true
                }
            }
            .onChange(of: model.selection) { _, _ in
                model.persistSelection()
            }
            .onChange(of: showingRequestPicker) { wasShowing, isShowing in
                if wasShowing && !isShowing && !requestSelectionIsValid {
                    showingInvalidRequestWarning = true
                }
            }
            .alert("No Apps Selected", isPresented: $showingEmptyPickerWarning) {
                Button("Try Again") {
                    showingPicker = true
                }
                Button("Dismiss", role: .cancel) {}
            } message: {
                Text("No apps were selected. If the picker was empty, Apple Family Sharing may still be syncing the child's activity. Only one parent or guardian needs to approve PagePass on the child's device. If you cancelled, no action is needed.")
            }
            .alert("Select Exactly One App", isPresented: $showingInvalidRequestWarning) {
                Button("Try Again") {
                    model.requestSelection = FamilyActivitySelection(includeEntireCategory: false)
                    showingRequestPicker = true
                }
                Button("Dismiss", role: .cancel) {}
            } message: {
                Text("Gate A requests require one individual app and no categories or websites.")
            }
            .onAppear {
                model.refreshFromStore()
            }
            .task {
                await model.runManagedProofAutomationIfRequested()
            }
            .task {
                await model.runLegacyProofAutomationIfRequested()
            }
            .task {
                await model.runPersistentMeterAutomationIfRequested()
            }
            .task {
                await model.runWallClockSessionAutomationIfRequested()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    model.refreshFromStore()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshFromStore()
                }
            }
        }
    }

    private var selectionIsEmpty: Bool {
        model.selection.applicationTokens.isEmpty
            && model.selection.categoryTokens.isEmpty
            && model.selection.webDomainTokens.isEmpty
    }

    private var requestSelectionIsValid: Bool {
        model.requestSelection.applicationTokens.count == 1
            && model.requestSelection.categoryTokens.isEmpty
            && model.requestSelection.webDomainTokens.isEmpty
            && !model.requestSelection.includeEntireCategory
    }

    private func controlButton(
        _ title: String,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}
