import DeviceActivity
import FamilyControls
import SwiftUI

struct UsageDiagnosticView: View {
    let selection: FamilyActivitySelection
    let intervalStart: Date
    let intervalEnd: Date

    @State private var refreshID = UUID()

    var body: some View {
        List {
            Section("Diagnostic Window") {
                Text("Start: \(intervalStart.formatted())")
                Text("End: \(effectiveEnd.formatted())")
                Text("Selected apps: \(selection.applicationTokens.count)")
                Text("All Screen Time devices are included")
                    .foregroundStyle(.secondary)
            }

            Section("System Usage") {
                DeviceActivityReport(.pagePassUsage, filter: filter)
                    .id(refreshID)
                    .frame(minHeight: 170)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    refreshID = UUID()
                }
            }
        }
        .navigationTitle("Usage Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var effectiveEnd: Date {
        min(Date(), intervalEnd)
    }

    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: intervalStart, end: effectiveEnd)),
            applications: selection.applicationTokens
        )
    }
}

extension DeviceActivityReport.Context {
    static let pagePassUsage = Self("pagepass-usage")
}
