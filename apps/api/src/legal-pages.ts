interface LegalSection {
  title: string;
  paragraphs: string[];
}

const privacySections: LegalSection[] = [
  {
    title: "Information We Collect",
    paragraphs: [
      "PagePass stores parent account details, family and child profile details, paired-device information, Earned Time balances and activity, app-access requests, and reading-review decisions.",
      "A reading submission can include the book title, optional author, original images of a child's handwritten report, on-device OCR results, an optional corrected transcript, and review history.",
      "For managed apps, PagePass stores encrypted or opaque Screen Time tokens and policy state. These tokens let PagePass apply the selected policy but do not reveal browsing content or activity inside an app."
    ]
  },
  {
    title: "How We Use Information",
    paragraphs: [
      "We use this information to connect parent and child devices, apply app restrictions, operate Earned Time, deliver requests and decisions, review handwritten reports, grant rewards, secure accounts, and troubleshoot the service.",
      "Handwriting recognition runs on the child device using Apple's Vision framework. PagePass uploads the original report images and OCR text so the parent can review the submission."
    ]
  },
  {
    title: "Sharing",
    paragraphs: [
      "PagePass does not sell personal information or use it for third-party advertising. Information is shared only with service providers needed to host the service, deliver email and notifications, store submitted media, or comply with law.",
      "Apple processes Screen Time authorization, app tokens, and push notifications under Apple's own terms and privacy policy."
    ]
  },
  {
    title: "Children and Family Access",
    paragraphs: [
      "A parent or guardian creates child profiles, pairs child devices, and controls family settings. Family information is visible only to authorized parent accounts and the paired child device as required for the service."
    ]
  },
  {
    title: "Retention and Your Choices",
    paragraphs: [
      "PagePass keeps account and family information while the account is active. When an account is deleted, personal account information and sign-in credentials are removed. Limited security, transaction, and review records may be retained when needed for legal compliance, fraud prevention, dispute resolution, or service integrity.",
      "Parents can revoke a child device, sign out, or delete their account from the app."
    ]
  }
];

const termsSections: LegalSection[] = [
  {
    title: "Using PagePass",
    paragraphs: [
      "PagePass helps a parent or guardian manage selected apps, review a child's handwritten reading report, and grant Earned Time. The parent is responsible for family setup, policy choices, and review decisions."
    ]
  },
  {
    title: "Accounts and Devices",
    paragraphs: [
      "Provide accurate account information and keep sign-in and pairing codes secure. Pair only devices that you are authorized to manage. A child device requires Apple's Family Controls authorization before PagePass can apply restrictions."
    ]
  },
  {
    title: "Screen Time Limitations",
    paragraphs: [
      "PagePass relies on Apple system frameworks and cannot guarantee that every app or system feature can be hidden, measured, or restricted in the same way. Emergency, communication, and other system behavior may remain available according to Apple settings and law."
    ]
  },
  {
    title: "Reading Reports",
    paragraphs: [
      "OCR can be incomplete or inaccurate. Original report images remain the source for parent review. PagePass does not certify that a child read a book, and no OCR result is automatically approved."
    ]
  },
  {
    title: "Acceptable Use",
    paragraphs: [
      "Do not use PagePass unlawfully, interfere with the service, access another family without permission, or upload content that you are not permitted to store or review."
    ]
  },
  {
    title: "Account Closure",
    paragraphs: [
      "You may stop using PagePass and delete your parent account in the app. End any active Earned Time session before deleting the final parent account for a family so managed apps return to their restricted state."
    ]
  }
];

export const privacyPolicyHTML = legalPage("Privacy Policy", privacySections);
export const termsOfUseHTML = legalPage("Terms of Use", termsSections);

function legalPage(title: string, sections: LegalSection[]): string {
  const content = sections.map((section) => `
    <section>
      <h2>${section.title}</h2>
      ${section.paragraphs.map((paragraph) => `<p>${paragraph}</p>`).join("\n")}
    </section>`).join("\n");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} - PagePass</title>
  <style>
    body { margin: 0; color: #172126; background: #fff; font: 16px/1.6 system-ui, sans-serif; }
    main { width: min(720px, calc(100% - 40px)); margin: 0 auto; padding: 48px 0 72px; }
    h1 { margin: 0 0 4px; font-size: 2rem; }
    h2 { margin: 32px 0 8px; font-size: 1.2rem; }
    p { margin: 0 0 12px; }
    .updated { color: #5e6a70; }
  </style>
</head>
<body>
  <main>
    <h1>${title}</h1>
    <p class="updated">Last updated: August 6, 2026</p>
    ${content}
  </main>
</body>
</html>`;
}
