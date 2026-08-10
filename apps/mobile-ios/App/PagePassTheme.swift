import SwiftUI
import UIKit

enum PagePassTheme {
    static let tint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1)
            : UIColor(red: 0.00, green: 0.31, blue: 0.62, alpha: 1)
    })

    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
            : UIColor(red: 0.29, green: 0.29, blue: 0.31, alpha: 1)
    })

    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.72, blue: 0.38, alpha: 1)
            : UIColor(red: 0.56, green: 0.27, blue: 0.00, alpha: 1)
    })

    static let error = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.64, blue: 0.62, alpha: 1)
            : UIColor(red: 0.70, green: 0.08, blue: 0.08, alpha: 1)
    })
}

struct PagePassActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .lineLimit(nil)
        }
    }
}
