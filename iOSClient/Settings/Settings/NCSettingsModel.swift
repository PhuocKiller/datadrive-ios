// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Aditya Tyagi
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import SwiftUI
import LocalAuthentication
import NextcloudKit

class NCSettingsModel: ObservableObject, ViewOnAppearHandling {
    // Keychain access
    var keychain = NCPreferences()
    // State to control the lock on/off section
    @Published var isLockActive: Bool = false
    // State to control the enable TouchID toggle
    @Published var enableTouchFaceID: Bool = false
    // State to control
    @Published var lockScreen: Bool = false
    // State to control
    @Published var privacyScreen: Bool = false
    // State to control
    @Published var resetWrongAttempts: Bool = false
    // Request account on start
    @Published var accountRequest: Bool = false
    // Root View Controller
    @Published var controller: NCMainTabBarController?
    // App language: a code from `languages`, or `NCSettingsModel.automaticLanguage` to follow the device
    @Published var language: String = NCSettingsModel.automaticLanguage
    static let automaticLanguage = "auto"
    // Localizations shipped in the app, each named in its own language, Vietnamese and English first
    let languages: [NCAppLanguage] = NCAppLanguage.available()
    // Footer
    var footerApp = ""
    var footerSlogan = ""
    // Get session
    @MainActor
    var session: NCSession.Session {
        NCSession.shared.getSession(controller: controller)
    }

    var changePasscode = false

    /// Initializes the view model with default values.
    init(controller: NCMainTabBarController?) {
        self.controller = controller
        onViewAppear()
    }

    /// Triggered when the view appears.
    func onViewAppear() {
        let capabilities = NCNetworking.shared.capabilities[self.controller?.account ?? ""] ?? NKCapabilities.Capabilities()
        isLockActive = (keychain.passcode != nil)
        enableTouchFaceID = keychain.touchFaceID
        lockScreen = !keychain.requestPasscodeAtStart
        privacyScreen = keychain.privacyScreenEnabled
        resetWrongAttempts = keychain.resetAppCounterFail
        accountRequest = keychain.accountRequest
        language = NCAppLanguage.saved.flatMap { saved in languages.first { $0.code == saved }?.code } ?? Self.automaticLanguage
        // The server (Nextcloud) version is left out on purpose: it is not the app version and only confuses users
        footerApp = String(format: NCBrandOptions.shared.textCopyrightNextcloudiOS, NCUtility().getVersionBuild()) + "\n\n"
        footerSlogan = capabilities.themingName + " - " + capabilities.themingSlogan + "\n\n"
    }

    // MARK: - All functions

    /// Function to update Touch ID / Face ID setting
    func updateTouchIDSetting() {
        keychain.touchFaceID = enableTouchFaceID
    }

    /// Function to update Lock Screen setting
    func updateLockScreenSetting() {
        keychain.requestPasscodeAtStart = !lockScreen
    }

    /// Function to update Privacy Screen setting
    func updatePrivacyScreenSetting() {
        keychain.privacyScreenEnabled = privacyScreen
    }

    /// Function to update Reset Wrong Attempts setting
    func updateResetWrongAttemptsSetting() {
        keychain.resetAppCounterFail = resetWrongAttempts
    }

    /// This function initiates a service call to download the configuration files
    /// using the URL provided in the `configLink` property.
    func getConfigFiles() {
        let session = NCSession.shared.getSession(controller: controller)
        let configLink = session.urlBase + NCBrandOptions.shared.mobileconfig
        let configServer = NCConfigServer(controller: self.controller)
        if let url = URL(string: configLink) {
            configServer.startService(url: url, account: session.account)
        }
    }

    /// Function to update Account request on start
    func updateAccountRequest() {
        keychain.accountRequest = accountRequest
    }

    /// Stores the chosen language; like the per-app language in iOS Settings, it applies from the next launch
    func updateLanguage() {
        NCAppLanguage.save(language == Self.automaticLanguage ? nil : language)
    }
}

/// A localization of the app, for the language picker in Settings.
struct NCAppLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    /// The per-app language iOS reads at launch is `AppleLanguages` in the app's own defaults domain.
    private static let key = "AppleLanguages"

    /// The language chosen in the app, or nil when it follows the device.
    static var saved: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return (UserDefaults.standard.persistentDomain(forName: bundleID)?[key] as? [String])?.first
    }

    static func save(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func available() -> [NCAppLanguage] {
        let first = ["vi", "en"]
        let languages = Bundle.main.localizations
            .filter { $0 != "Base" }
            .map { code -> NCAppLanguage in
                let locale = Locale(identifier: code)
                let name = locale.localizedString(forIdentifier: code) ?? code
                return NCAppLanguage(code: code, name: name.prefix(1).uppercased(with: locale) + name.dropFirst())
            }
        return languages.sorted { lhs, rhs in
            let l = first.firstIndex(of: lhs.code) ?? first.count, r = first.firstIndex(of: rhs.code) ?? first.count
            return l != r ? l < r : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
