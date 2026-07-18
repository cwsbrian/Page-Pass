import SwiftUI
import VisionKit

struct QRScannerView: UIViewControllerRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(
        _ controller: DataScannerViewController,
        coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onToken: (String) -> Void
        private var didScan = false

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didScan else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let token = barcode.payloadStringValue else { continue }
                didScan = true
                onToken(token)
                return
            }
        }
    }
}
