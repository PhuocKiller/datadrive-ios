// SPDX-FileCopyrightText: 2026 Tran Huy Phuoc
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

///
/// Captures App Store screenshots at the simulator's native resolution.
///
/// Skipped unless `SCREENSHOT_DIR` is set, so it never runs as part of the regular test suite.
/// Credentials come from the environment and never end up in the repository:
///
/// ```
/// TEST_RUNNER_SCREENSHOT_DIR=<dir> TEST_RUNNER_SCREENSHOT_USER=<user> TEST_RUNNER_SCREENSHOT_PASSWORD=<password> \
/// xcodebuild test -scheme DataDrive -destination 'platform=iOS Simulator,id=<udid>' \
///   -only-testing:DataDriveUITests/AppStoreScreenshots
/// ```
///
/// The account is expected to hold the demo content the steps below open ("Ảnh du lịch", "Tài liệu"…).
/// `SCREENSHOT_LANGUAGE` / `SCREENSHOT_LOCALE` default to Vietnamese (`vi` / `vi_VN`).
/// Every capture also writes the accessibility hierarchy next to the PNG, to debug a step that missed.
///
@MainActor
final class AppStoreScreenshots: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    private var outputDirectory: URL!
    private var counter = 0

    /// Onboarding tips that would otherwise cover the screenshots (Vietnamese and English).
    private let tips = [
        "Chạm vào đây để đổi tài khoản hoặc thêm tài khoản mới", "Touch here to change account or to add a new one",
        "Vuốt lên để xem chi tiết", "Swipe up to show the details",
        "Vuốt sang trái từ mép phải màn hình để hiện ảnh thu nhỏ các trang", "Swipe left from the right edge of the screen to show the thumbnails"
    ]

    override func setUp() async throws {
        guard let directory = environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR is not set")
        }
        outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(environment["SCREENSHOT_LANGUAGE"] ?? "vi"))",
            "-AppleLocale", environment["SCREENSHOT_LOCALE"] ?? "vi_VN"
        ]
    }

    func testCaptureScreenshots() async throws {
        app.launch()
        try await pause(3)
        dismissSystemAlerts()

        try await logInIfNeeded()
        try await pause(8)
        dismissSystemAlerts()
        dismissTips()

        // Files, then the "+" menu
        if openTab(0, labels: ["Tệp", "Files"]) {
            try await pause(5)
            dismissTips()
            capture("files")
            if let add = floatingAddButton() {
                add.tap()
                try await pause(2)
                capture("plus-menu")
                dismissMenu()
            }
        } else {
            capture("no-tab-bar")
            XCTFail("Could not find the tab bar")
            return
        }

        // Media first: it downloads the previews that the photo folder then shows as thumbnails
        if openTab(2, labels: ["Phương tiện", "Media"]) {
            try await pause(10)
            capture("media")
        }

        // A photo folder, then one photo full screen
        if openTab(0, labels: ["Tệp", "Files"]), tapItem("Ảnh du lịch") {
            try await pause(12)
            capture("folder-photos")
            if tapItem("Hoàng hôn trên biển.jpg") {
                try await pause(8)
                dismissTips()
                capture("photo-viewer")
                goBack()
            }
            goBack()
        }

        // Favorites
        if openTab(1, labels: ["Ưa thích", "Favorites"]) {
            try await pause(5)
            capture("favorites")
        }

        // A PDF document
        if openTab(0, labels: ["Tệp", "Files"]), tapItem("Tài liệu") {
            try await pause(5)
            capture("folder-documents")
            if let more = rowButton("Báo cáo quý 3 - 2026.pdf", index: 1) {
                more.tap()
                try await pause(2)
                capture("file-menu")
                dismissMenu()
            }
            if tapItem("Báo cáo quý 3 - 2026.pdf") {
                try await pause(10)
                dismissTips()
                capture("pdf-viewer")
                goBack()
            }
            goBack()
        }

        // More
        if openTab(4, labels: ["Thêm", "More"]) {
            try await pause(5)
            capture("more")
        }

        // Sharing, last because the share sheet covers the tab bar
        if openTab(0, labels: ["Tệp", "Files"]), tapItem("Tài liệu"), let share = rowButton("Báo cáo quý 3 - 2026.pdf", index: 0) {
            share.tap()
            try await pause(6)
            capture("share")
        }
    }

    /// Checks the language picker in Settings (captures are for review, not for the App Store): picks Vietnamese,
    /// then relaunches without `-AppleLanguages`, so on an English simulator only the saved choice can make it Vietnamese.
    func testLanguagePicker() async throws {
        app.launch()
        try await pause(3)
        dismissSystemAlerts()
        try await logInIfNeeded()
        try await pause(5)
        dismissSystemAlerts()
        dismissTips()

        guard openTab(4, labels: ["Thêm", "More"]) else {
            XCTFail("Could not find the tab bar")
            return
        }
        guard tapItem("Cài đặt") || tapItem("Settings") else {
            XCTFail("Could not open Settings")
            return
        }
        try await pause(3)
        capture("settings")

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Ngôn ngữ", "Language")).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            XCTFail("No language row")
            return
        }
        row.tap()
        try await pause(2)
        capture("language-menu")

        let vietnamese = app.buttons["Tiếng Việt"].firstMatch
        guard vietnamese.waitForExistence(timeout: 5) else {
            XCTFail("No Vietnamese in the language menu")
            return
        }
        vietnamese.tap()
        try await pause(2)
        capture("language-changed")
        let ok = app.alerts.firstMatch.buttons.firstMatch
        if ok.waitForExistence(timeout: 5) {
            ok.tap()
        } else {
            XCTFail("No alert after changing the language")
        }

        app.swipeUp()
        app.swipeUp()
        try await pause(1)
        capture("settings-footer")

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        try await pause(8)
        capture("relaunched")
        XCTAssertTrue(relaunched.buttons["Tệp"].firstMatch.waitForExistence(timeout: 10), "The saved language was not applied on relaunch")
    }

    /// Walks through the app for an App Store app preview while the simulator screen is being recorded.
    /// Writes `preview-start.txt` / `preview-end.txt` (Unix time) so the recording can be trimmed to the tour.
    func testRecordPreview() async throws {
        app.launch()
        try await pause(3)
        dismissSystemAlerts()
        try await logInIfNeeded()
        try await pause(5)
        dismissSystemAlerts()
        dismissTips()

        // Warm up: load the previews and thumbnails before recording starts
        guard openTab(2, labels: ["Phương tiện", "Media"]) else {
            XCTFail("Could not find the tab bar")
            return
        }
        try await pause(8)
        // Also open the photo and Favorites once, so neither shows a blank or empty screen on camera
        if openTab(1, labels: ["Ưa thích", "Favorites"]) {
            try await pause(4)
        }
        if openTab(0, labels: ["Tệp", "Files"]), tapItem("Ảnh du lịch") {
            try await pause(6)
            if tapItem("Hoàng hôn trên biển.jpg") {
                try await pause(6)
                goBack()
            }
            goBack()
        }
        try await pause(3)

        // Every query costs a couple of seconds in the VM, so the pauses are short to stay near 30 s
        mark("preview-start")
        if tapItem("Ảnh du lịch") {
            try await pause(1.5)
            if tapItem("Hoàng hôn trên biển.jpg") {
                try await pause(2)
                // Queries are slower on the iPad simulator, so it skips the swipe to stay near 30 s
                if UIDevice.current.userInterfaceIdiom != .pad {
                    app.swipeLeft()
                    try await pause(1.5)
                }
                goBack()
            }
        }
        if openTab(2, labels: ["Phương tiện", "Media"]) {
            // Its loading spinner keeps the screen "moving", so the still-stretch trim cannot shorten it later
            try await pause(UIDevice.current.userInterfaceIdiom == .pad ? 1.5 : 3)
        }
        if openTab(1, labels: ["Ưa thích", "Favorites"]) {
            try await pause(1)
            if tapItem("Báo cáo quý 3 - 2026.pdf") {
                try await pause(3.5)
            }
        }
        mark("preview-end")
    }

    // MARK: - Steps

    private func logInIfNeeded() async throws {
        let password = app.secureTextFields.firstMatch
        guard password.waitForExistence(timeout: 10) else { return }

        capture("login")

        guard let userValue = environment["SCREENSHOT_USER"], let passwordValue = environment["SCREENSHOT_PASSWORD"] else {
            XCTFail("SCREENSHOT_USER / SCREENSHOT_PASSWORD are not set")
            return
        }

        let user = app.textFields.firstMatch
        user.tap()
        dismissKeyboardOnboarding()
        user.typeText(userValue)
        password.tap()
        dismissKeyboardOnboarding()
        // Return on the password field submits the login form.
        password.typeText(passwordValue + "\n")
        try await pause(5)
        dismissSystemAlerts()
    }

    // MARK: - Navigation

    /// Selects a tab by position in a bottom tab bar (iPhone) or by title in the top floating tab bar (iPad).
    private func openTab(_ index: Int, labels: [String]) -> Bool {
        // The iPad tab bar is not exposed as a TabBar, so waiting for one there only wastes ~7 s per switch
        let tabBar = app.tabBars.firstMatch
        if UIDevice.current.userInterfaceIdiom != .pad, tabBar.waitForExistence(timeout: 5), tabBar.buttons.count > index {
            tabBar.buttons.element(boundBy: index).tap()
            return true
        }
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    /// File cells show the extension in a separate label, so a file is matched by its name without it.
    private func tapItem(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", name, stem)).firstMatch
        guard text.waitForExistence(timeout: 15) else {
            capture("missing-\(name)")
            return false
        }
        text.tap()
        return true
    }

    /// The floating "+" button. Row "…" buttons share its label, but it sits below every row.
    private func floatingAddButton() -> XCUIElement? {
        let tabBarFrame = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .null
        let candidates = app.buttons.matching(NSPredicate(format: "label IN %@", ["Thêm", "Add"])).allElementsBoundByIndex
            .filter { $0.isHittable && !tabBarFrame.intersects($0.frame) }
        return candidates.max { $0.frame.minY < $1.frame.minY }
    }

    /// A button in the row of the given file: 0 is share, 1 is "…".
    private func rowButton(_ name: String, index: Int) -> XCUIElement? {
        let stem = (name as NSString).deletingPathExtension
        let cell = app.cells.containing(NSPredicate(format: "label == %@ OR label == %@", name, stem)).firstMatch
        guard cell.waitForExistence(timeout: 10), cell.buttons.count > index else {
            capture("missing-row-\(name)")
            return nil
        }
        return cell.buttons.element(boundBy: index)
    }

    /// Menus close on a tap outside them, and that tap is not passed on to what is underneath.
    /// The buttons that open them sit on the right, so their menus never reach the left edge.
    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func mark(_ name: String) {
        try? String(Date().timeIntervalSince1970).write(to: outputDirectory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        if back.waitForExistence(timeout: 3), back.isHittable {
            back.tap()
        } else {
            app.swipeDown()
        }
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        counter += 1
        let fileName = String(format: "%02d-%@", counter, sanitized(name))
        let screenshot = XCUIScreen.main.screenshot()
        let url = outputDirectory.appendingPathComponent(fileName + ".png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            try app.debugDescription.write(to: outputDirectory.appendingPathComponent(fileName + ".txt"), atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Could not write \(url.path): \(error)")
        }
    }

    /// Answers permission prompts (notifications, photos, saved passwords…) so they don't cover the screenshots.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow", "Allow Full Access", "Allow While Using App", "Cho phép", "Cho phép truy cập đầy đủ", "Not Now", "Để sau", "OK"]
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            guard let label = labels.first(where: { alert.buttons[$0].exists }) else { return }
            alert.buttons[label].tap()
        }
    }

    private func dismissTips() {
        for tip in tips {
            let element = app.staticTexts[tip].firstMatch
            if element.exists, element.isHittable {
                element.tap()
            }
        }
    }

    /// The first keyboard use shows the swipe-typing tutorial over the lower half of the screen.
    private func dismissKeyboardOnboarding() {
        for label in ["Continue", "Tiếp tục"] {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 1), button.isHittable {
                button.tap()
            }
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }
}
