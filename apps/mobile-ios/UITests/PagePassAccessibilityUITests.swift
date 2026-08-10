import XCTest

final class PagePassAccessibilityUITests: XCTestCase {
    @MainActor
    func testInstallationRoleAccessibility() throws {
        let app = launch(role: "selection")

        XCTAssertTrue(app.buttons["Parent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Child"].exists)
        try performAppAccessibilityAudit(app)
    }

    @MainActor
    func testParentHomeAccessibility() throws {
        let app = launch(role: "parent")

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        try performAppAccessibilityAudit(app)
    }

    @MainActor
    func testChildHomeAccessibility() throws {
        let app = launch(role: "child")

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        try performAppAccessibilityAudit(app)
    }

    @MainActor
    func testChildHomeAtLargestDynamicType() throws {
        let app = launch(
            role: "child",
            preferredContentSizeCategory:
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )

        let earnTime = app.buttons["Earn Time"]
        XCTAssertTrue(earnTime.waitForExistence(timeout: 10))
        XCTAssertTrue(earnTime.isHittable)

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Quick Actions"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(
        role: String,
        preferredContentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PAGEPASS_UI_TEST_ROLE"] = role
        app.launchEnvironment["PAGEPASS_SERVER_URL"] = "http://127.0.0.1:8787"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let preferredContentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                preferredContentSizeCategory
            ]
        }
        app.launch()
        return app
    }

    @MainActor
    private func performAppAccessibilityAudit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit { issue in
            if issue.auditType == .dynamicType,
               let label = issue.element?.label,
               ["Earn Time", "Quick Actions"].contains(label) {
                return true
            }

            guard issue.auditType == .contrast else { return false }
            guard let element = issue.element else { return true }

            return element.label.isEmpty &&
                element.identifier.isEmpty &&
                !element.isHittable
        }
    }
}
