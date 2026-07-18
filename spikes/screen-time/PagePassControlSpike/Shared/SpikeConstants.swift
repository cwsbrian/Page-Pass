import FamilyControls
import Foundation

enum SpikeConstants {
    static let appGroupID = "group.com.pagepass.controlspike"
    static let monitorExtensionBundleID = "com.pagepass.controlspike.DeviceActivityMonitor"
    static let storeName = "PagePassControlSpike"
    static let legacyStoreName = "PagePassControlSpike.Legacy"
    static let activityPrefix = "PagePassCreditRun"
    static let eventPrefix = "limitedAppCredit"
    static let testCreditSeconds = 60
    static let fallbackProofCreditSeconds = 120
    static let quantizedProofCreditSeconds = 120
    static let debitQuantumSeconds = 60
    static let minimumWallClockSessionSeconds = 15 * 60
    static let eventThresholdSeconds = 60
    static let managedAppTokenLimit = 50
    static let monitoringStartLeadSeconds = 3
    static let measurementGraceSeconds = 60
    static let maximumCumulativeEventCount = 240
    static let maximumCreditGrantSeconds = 4 * 60 * 60
    static let maximumCreditActivationDelaySeconds = 25
    static let minimumMonitoringWindowSeconds = 4 * 60 * 60

    struct RunNames: Equatable {
        let activity: String
    }

    static func names(for runID: String) -> RunNames {
        RunNames(
            activity: "\(activityPrefix)-\(runID)"
        )
    }

    static func eventName(for runID: String, cumulativeThresholdSeconds: Int) -> String {
        "\(eventPrefix)-\(runID)-\(cumulativeThresholdSeconds)"
    }

    static func deviceActivityThresholdSeconds(
        for logicalThresholdSeconds: Int,
        includesMeasurementGrace: Bool = true
    ) -> Int {
        let grace = includesMeasurementGrace ? measurementGraceSeconds : 0
        let (threshold, overflow) = logicalThresholdSeconds.addingReportingOverflow(grace)
        precondition(!overflow)
        return threshold
    }

    static func cumulativeThresholdSeconds(eventName: String, runID: String) -> Int? {
        let prefix = "\(eventPrefix)-\(runID)-"
        guard eventName.hasPrefix(prefix),
              let threshold = Int(eventName.dropFirst(prefix.count)),
              threshold > 0 else {
            return nil
        }
        return threshold
    }

    static func cumulativeThresholds(
        creditGrantSeconds: Int,
        debitQuantumSeconds: Int,
        deductionPath: AutomaticDeductionPath
    ) -> [Int] {
        guard isValidCumulativeConfiguration(
            creditGrantSeconds: creditGrantSeconds,
            debitQuantumSeconds: debitQuantumSeconds,
            deductionPath: deductionPath
        ) else { return [] }

        switch deductionPath {
        case .singleThresholdFallback:
            return [creditGrantSeconds]
        case .quantized:
            guard debitQuantumSeconds > 0 else { return [creditGrantSeconds] }
            var thresholds = Array(
                stride(
                    from: debitQuantumSeconds,
                    through: creditGrantSeconds,
                    by: debitQuantumSeconds
                )
            )
            if thresholds.last != creditGrantSeconds {
                thresholds.append(creditGrantSeconds)
            }
            return thresholds
        }
    }

    static func isValidCumulativeConfiguration(
        creditGrantSeconds: Int,
        debitQuantumSeconds: Int,
        deductionPath: AutomaticDeductionPath
    ) -> Bool {
        guard creditGrantSeconds > 0,
              debitQuantumSeconds > 0,
              debitQuantumSeconds <= creditGrantSeconds,
              creditGrantSeconds <= maximumCreditGrantSeconds,
              creditGrantSeconds <= Int.max - measurementGraceSeconds else {
            return false
        }
        guard deductionPath == .quantized else { return true }
        let eventCount = creditGrantSeconds / debitQuantumSeconds
            + (creditGrantSeconds % debitQuantumSeconds == 0 ? 0 : 1)
        return eventCount <= maximumCumulativeEventCount
    }
}

extension AuthorizationStatus {
    var allowsPagePassShielding: Bool {
        if self == .approved {
            return true
        }
        if #available(iOS 26.4, *), self == .approvedWithDataAccess {
            return true
        }
        return false
    }
}
