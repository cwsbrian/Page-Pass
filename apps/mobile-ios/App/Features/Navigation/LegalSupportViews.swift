import SwiftUI

enum PagePassLegalDocument: String, Identifiable {
    case privacy
    case terms

    var id: Self { self }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Use"
        }
    }
}

struct PagePassLegalDocumentView: View {
    let document: PagePassLegalDocument

    var body: some View {
        List {
            Section {
                Text("Last updated: August 6, 2026")
                    .foregroundStyle(.secondary)
            }

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                    }
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sections: [LegalSection] {
        switch document {
        case .privacy: privacySections
        case .terms: termsSections
        }
    }

    private var privacySections: [LegalSection] {
        [
            LegalSection(
                title: "Information We Collect",
                paragraphs: [
                    "PagePass stores parent account details, family and child profile details, paired-device information, Earned Time balances and activity, app-access requests, and reading-review decisions.",
                    "A reading submission can include the book title, optional author, original images of a child's handwritten report, on-device OCR results, an optional corrected transcript, and review history.",
                    "For managed apps, PagePass stores encrypted or opaque Screen Time tokens and policy state. These tokens let PagePass apply the selected policy but do not reveal browsing content or activity inside an app."
                ]
            ),
            LegalSection(
                title: "How We Use Information",
                paragraphs: [
                    "We use this information to connect parent and child devices, apply app restrictions, operate Earned Time, deliver requests and decisions, review handwritten reports, grant rewards, secure accounts, and troubleshoot the service.",
                    "Handwriting recognition runs on the child device using Apple's Vision framework. PagePass uploads the original report images and OCR text so the parent can review the submission."
                ]
            ),
            LegalSection(
                title: "Sharing",
                paragraphs: [
                    "PagePass does not sell personal information or use it for third-party advertising. Information is shared only with service providers needed to host the service, deliver email and notifications, store submitted media, or comply with law.",
                    "Apple processes Screen Time authorization, app tokens, and push notifications under Apple's own terms and privacy policy."
                ]
            ),
            LegalSection(
                title: "Children and Family Access",
                paragraphs: [
                    "A parent or guardian creates child profiles, pairs child devices, and controls family settings. Family information is visible only to authorized parent accounts and the paired child device as required for the service."
                ]
            ),
            LegalSection(
                title: "Retention and Your Choices",
                paragraphs: [
                    "PagePass keeps account and family information while the account is active. When an account is deleted, personal account information and sign-in credentials are removed. Limited security, transaction, and review records may be retained when needed for legal compliance, fraud prevention, dispute resolution, or service integrity.",
                    "Parents can revoke a child device, sign out, or delete their account from the app."
                ]
            )
        ]
    }

    private var termsSections: [LegalSection] {
        [
            LegalSection(
                title: "Using PagePass",
                paragraphs: [
                    "PagePass helps a parent or guardian manage selected apps, review a child's handwritten reading report, and grant Earned Time. The parent is responsible for family setup, policy choices, and review decisions."
                ]
            ),
            LegalSection(
                title: "Accounts and Devices",
                paragraphs: [
                    "Provide accurate account information and keep sign-in and pairing codes secure. Pair only devices that you are authorized to manage. A child device requires Apple's Family Controls authorization before PagePass can apply restrictions."
                ]
            ),
            LegalSection(
                title: "Screen Time Limitations",
                paragraphs: [
                    "PagePass relies on Apple system frameworks and cannot guarantee that every app or system feature can be hidden, measured, or restricted in the same way. Emergency, communication, and other system behavior may remain available according to Apple settings and law."
                ]
            ),
            LegalSection(
                title: "Reading Reports",
                paragraphs: [
                    "OCR can be incomplete or inaccurate. Original report images remain the source for parent review. PagePass does not certify that a child read a book, and no OCR result is automatically approved."
                ]
            ),
            LegalSection(
                title: "Acceptable Use",
                paragraphs: [
                    "Do not use PagePass unlawfully, interfere with the service, access another family without permission, or upload content that you are not permitted to store or review."
                ]
            ),
            LegalSection(
                title: "Account Closure",
                paragraphs: [
                    "You may stop using PagePass and delete your parent account in the app. End any active Earned Time session before deleting the final parent account for a family so managed apps return to their restricted state."
                ]
            )
        ]
    }
}

struct PagePassTroubleshootingView: View {
    var body: some View {
        List {
            Section("Connection") {
                Label("Confirm both devices have internet access.", systemImage: "wifi")
                Label("Open PagePass and use Sync when a recent change is missing.", systemImage: "arrow.triangle.2.circlepath")
            }

            Section("Screen Time") {
                Label("Confirm authorization says Approved on the child device.", systemImage: "checkmark.shield")
                Label("Save, lock, and sync again after changing managed apps.", systemImage: "lock.shield")
            }

            Section("Earned Time") {
                Label("Stop the current session before changing devices or account access.", systemImage: "stop.circle")
                Label("Keep PagePass installed so scheduled restrictions can be applied.", systemImage: "iphone")
            }

            Section("Reading Reports") {
                Label("Original pages remain in the local draft when upload fails.", systemImage: "doc.on.doc")
                Label("Retry unfinished OCR or upload from the saved draft.", systemImage: "arrow.clockwise")
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PagePassAboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("App", value: "PagePass")
                LabeledContent("Version", value: versionDescription)
            }

            Section("Legal") {
                NavigationLink("Privacy Policy") {
                    PagePassLegalDocumentView(document: .privacy)
                }
                NavigationLink("Terms of Use") {
                    PagePassLegalDocumentView(document: .terms)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "-"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "-"
        return "\(version) (\(build))"
    }
}

private struct LegalSection: Identifiable {
    let title: String
    let paragraphs: [String]
    var id: String { title }
}
