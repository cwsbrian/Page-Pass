import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ParentHomeView: View {
    var onSignOut: (() async -> Void)?

    @State private var store: ParentHomeStore
    @State private var showingAddChild = false
    @State private var showingLegacyImport = false
    @State private var childName = ""
    @State private var legacyParentToken = ""

    init(onSignOut: (() async -> Void)? = nil) {
        self.onSignOut = onSignOut
        _store = State(initialValue: ParentHomeStore(onUnauthorized: onSignOut))
    }

    var body: some View {
        NavigationStack {
            List {
#if DEBUG
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
#endif

                Section("Children") {
                    if store.children.isEmpty {
                        ContentUnavailableView(
                            "No Child Profiles",
                            systemImage: "person.2"
                        )
                    } else {
                        ForEach(store.children) { child in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(child.name)
                                            .font(.headline)
                                        Text(child.activeDeviceName ?? "Not connected")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(balanceDescription(child.balanceSeconds))
                                        .monospacedDigit()
                                }

                                HStack {
                                    Button {
                                        Task { await store.createPairingSession(childID: child.id) }
                                    } label: {
                                        Label("Connect", systemImage: "link")
                                    }

                                    Spacer()

                                    Button {
                                        Task { await store.grantCredit(childID: child.id, seconds: 15 * 60) }
                                    } label: {
                                        Label("15 min", systemImage: "plus.circle")
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Family")
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
