import DeviceActivity
import SwiftUI

extension DeviceActivityReport.Context {
    static let pagePassUsage = Self("pagepass-usage")
}

struct PagePassUsageConfiguration {
    let totalActivityDuration: TimeInterval
    let segmentStart: Date?
    let segmentEnd: Date?
}

@main
struct PagePassDeviceActivityReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        PagePassUsageReport { configuration in
            PagePassUsageReportView(configuration: configuration)
        }
    }
}

struct PagePassUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .pagePassUsage
    let content: (PagePassUsageConfiguration) -> PagePassUsageReportView

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> PagePassUsageConfiguration {
        var totalActivityDuration: TimeInterval = 0
        var segmentStart: Date?
        var segmentEnd: Date?

        for await activityData in data {
            for await segment in activityData.activitySegments {
                totalActivityDuration += segment.totalActivityDuration
                segmentStart = min(segmentStart ?? segment.dateInterval.start, segment.dateInterval.start)
                segmentEnd = max(segmentEnd ?? segment.dateInterval.end, segment.dateInterval.end)
            }
        }

        return PagePassUsageConfiguration(
            totalActivityDuration: totalActivityDuration,
            segmentStart: segmentStart,
            segmentEnd: segmentEnd
        )
    }
}

struct PagePassUsageReportView: View {
    let configuration: PagePassUsageConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple reported usage")
                .font(.headline)
            Text(durationDescription)
                .font(.system(.title, design: .monospaced, weight: .semibold))
            if let start = configuration.segmentStart,
               let end = configuration.segmentEnd {
                Text("Report segments: \(start.formatted()) to \(end.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var durationDescription: String {
        let seconds = Int(configuration.totalActivityDuration.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }
}
