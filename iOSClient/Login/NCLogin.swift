// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-FileCopyrightText: 2025 Milen Pivchev
// SPDX-License-Identifier: GPL-3.0-or-later

import UniformTypeIdentifiers
import UIKit
import NextcloudKit
import SwiftUI
import SafariServices

class NCLogin: UIViewController, UITextFieldDelegate, NCLoginQRCodeDelegate {
    @IBOutlet weak var imageBrand: UIImageView!
    @IBOutlet weak var imageBrandConstraintY: NSLayoutConstraint!
    @IBOutlet weak var baseUrlTextField: UITextField!
    @IBOutlet weak var loginAddressDetail: UILabel!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var qrCode: UIButton!
    @IBOutlet weak var certificate: UIButton!
    @IBOutlet weak var enforceServersButton: UIButton!
    @IBOutlet weak var enforceServersDropdownImage: UIImageView!

    private let appDelegate = (UIApplication.shared.delegate as? AppDelegate)!
    private var textColor: UIColor = .white
    private var textColorOpponent: UIColor = .black
    private var activeTextfieldDiff: CGFloat = 0
    private var activeTextField = UITextField()


    /// Controller
    var controller: NCMainTabBarController?

    /// The URL that will show up on the URL field when this screen appears
    var urlBase = ""

    // Used for MDM
    var configServerUrl: String?
    var configUsername: String?
    var configPassword: String?
    var configAppPassword: String?

    private var p12Data: Data?
    private var p12Password: String?
    private var QRCodeCheck: Bool = false
    private var activeLoginProvider: NCLoginProvider?
    private var didStartFixedServerLogin = false

    /// In-app login (fixed server): built in code, the storyboard only carries the brand image and the button.
    private var userTextField: UITextField?
    private var passwordTextField: UITextField?
    private var errorLabel: UILabel?
    private var homePageButton: UIButton?

    /// True when the brand pins the server, so the user signs in here instead of in a web page.
    private var usesDirectLogin: Bool { NCBrandOptions.shared.disable_request_login_url }

    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let backgroundImage = UIImage(named: "background")

        // Text color: dark text on the (light) brand background image
        if backgroundImage != nil || NCBrandColor.shared.customer.isTooLight() {
            textColor = .black
            textColorOpponent = .white
        } else if NCBrandColor.shared.customer.isTooDark() {
            textColor = .white
            textColorOpponent = .black
        } else {
            textColor = .white
            textColorOpponent = .black
        }

        // Background
        if let backgroundImage {
            let backgroundImageView = UIImageView(image: backgroundImage)
            backgroundImageView.contentMode = .scaleAspectFill
            backgroundImageView.clipsToBounds = true
            backgroundImageView.frame = view.bounds
            backgroundImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(backgroundImageView, at: 0)
            // Keep the status bar readable on the light background
            navigationController?.overrideUserInterfaceStyle = .light
        }

        // Image Brand
        imageBrand.image = UIImage(named: "logo")

        // Url
        baseUrlTextField.textColor = textColor
        baseUrlTextField.tintColor = textColor
        baseUrlTextField.layer.cornerRadius = 10
        baseUrlTextField.layer.borderWidth = 1
        baseUrlTextField.layer.borderColor = textColor.cgColor
        baseUrlTextField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: baseUrlTextField.frame.height))
        baseUrlTextField.leftViewMode = .always
        baseUrlTextField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 35, height: baseUrlTextField.frame.height))
        baseUrlTextField.rightViewMode = .always
        baseUrlTextField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("_login_url_", comment: ""), attributes: [NSAttributedString.Key.foregroundColor: textColor.withAlphaComponent(0.5)])
        baseUrlTextField.delegate = self

        baseUrlTextField.isEnabled = !NCBrandOptions.shared.disable_request_login_url

        // Login button
        loginAddressDetail.textColor = textColor
        loginAddressDetail.text = String.localizedStringWithFormat(NSLocalizedString("_login_address_detail_", comment: ""), NCBrandOptions.shared.brand)

        // QR code button
        qrCode.tintColor = NCBrandColor.shared.customer.isTooLight() ? .black : .white

        // brand: fixed server, no address entry
        if NCBrandOptions.shared.disable_request_login_url {
            urlBase = NCBrandOptions.shared.loginBaseUrl
            baseUrlTextField.isHidden = true
            loginAddressDetail.isHidden = true
            qrCode.isHidden = true
            setupDirectLoginUI()
        }

        // certificate
        certificate.setImage(UIImage(named: "certificate")?.image(color: textColor, size: 100), for: .normal)
        certificate.isHidden = true
        certificate.isEnabled = false

        // navigation
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.shadowColor = .clear
        navBarAppearance.shadowImage = UIImage()
        navBarAppearance.titleTextAttributes = [.foregroundColor: textColor]
        navBarAppearance.largeTitleTextAttributes = [.foregroundColor: textColor]
        self.navigationController?.navigationBar.standardAppearance = navBarAppearance
        self.navigationController?.view.backgroundColor = NCBrandColor.shared.customer
        self.navigationController?.navigationBar.tintColor = textColor

        self.navigationController?.navigationBar.setValue(true, forKey: "hidesShadow")
        view.backgroundColor = NCBrandColor.shared.customer

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        handleLoginWithAppConfig()
        baseUrlTextField.text = urlBase

        enforceServersButton.setTitle(NSLocalizedString("_select_server_", comment: ""), for: .normal)

        let enforceServers = NCBrandOptions.shared.enforce_servers

        if !enforceServers.isEmpty {
            baseUrlTextField.isHidden = true
            enforceServersDropdownImage.isHidden = false
            enforceServersButton.isHidden = false

            let actions = enforceServers.map { server in
                UIAction(title: server.name, handler: { [self] _ in
                    enforceServersButton.setTitle(server.name, for: .normal)
                    baseUrlTextField.text = server.url
                })
            }

            enforceServersButton.layer.cornerRadius = 10
            enforceServersButton.menu = .init(title: NSLocalizedString("_servers_", comment: ""), children: actions)
            enforceServersButton.showsMenuAsPrimaryAction = true
            enforceServersButton.configuration?.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 13)
                return outgoing
            }
        }

        NCNetworking.shared.certificateDelegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !NCManageDatabase.shared.getAllTableAccount().isEmpty,
           self.navigationController?.viewControllers.count ?? 0 == 1 {
            let navigationItemCancel = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(actionCancel(_:)))
            navigationItemCancel.tintColor = textColor
            navigationItem.leftBarButtonItem = navigationItemCancel
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if usesDirectLogin, !didStartFixedServerLogin {
            // Fixed server: the credentials are typed here, so just focus the first field
            didStartFixedServerLogin = true
            userTextField?.becomeFirstResponder()
        }
    }

    private func handleLoginWithAppConfig() {
        let accountCount = NCManageDatabase.shared.getAccounts()?.count ?? 0

        // load AppConfig
        if (NCBrandOptions.shared.disable_multiaccount == false) || (NCBrandOptions.shared.disable_multiaccount == true && accountCount == 0) {
            if let configurationManaged = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed"), NCBrandOptions.shared.use_AppConfig {
                if let serverUrl = configurationManaged[NCGlobal.shared.configuration_serverUrl] as? String {
                    self.configServerUrl = serverUrl
                }
                if let username = configurationManaged[NCGlobal.shared.configuration_username] as? String, !username.isEmpty, username.lowercased() != "username" {
                    self.configUsername = username
                }
                if let password = configurationManaged[NCGlobal.shared.configuration_password] as? String, !password.isEmpty, password.lowercased() != "password" {
                    self.configPassword = password
                }
                if let apppassword = configurationManaged[NCGlobal.shared.configuration_apppassword] as? String, !apppassword.isEmpty, apppassword.lowercased() != "apppassword" {
                    self.configAppPassword = apppassword
                }
            }
        }

        // AppConfig
        if let url = configServerUrl {
            Task {
                if let user = self.configUsername, let password = configAppPassword {
                    await createAccount(urlBase: url, user: user, password: password)
                    return
                } else if let user = self.configUsername, let password = configPassword {
                    await getAppPassword(urlBase: url, user: user, password: password)
                    return
                } else {
                    urlBase = url
                }
            }
        }
    }

    /// With a fixed server there is no address field: the user types credentials here and the
    /// arrow button becomes a "Log in" button, with a link to the DataDrive home page below it.
    private func setupDirectLoginUI() {
        // Storyboard constraints place the button next to the address field and size it 40x40
        let storyboardConstraints = view.constraints.filter { $0.firstItem === loginButton || $0.secondItem === loginButton }
            + loginButton.constraints.filter { $0.secondItem == nil && ($0.firstAttribute == .width || $0.firstAttribute == .height) }
        NSLayoutConstraint.deactivate(storyboardConstraints)

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("_log_in_", comment: "")
        configuration.baseBackgroundColor = NCBrandColor.shared.customer
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 40, bottom: 12, trailing: 40)
        loginButton.configuration = configuration

        let user = makeCredentialTextField(placeholder: NSLocalizedString("_user_", comment: ""))
        user.textContentType = .username
        user.autocapitalizationType = .none
        user.autocorrectionType = .no
        user.spellCheckingType = .no
        user.returnKeyType = .next
        userTextField = user

        let password = makeCredentialTextField(placeholder: NSLocalizedString("_password_", comment: ""))
        password.textContentType = .password
        password.isSecureTextEntry = true
        password.returnKeyType = .go
        passwordTextField = password

        let error = UILabel()
        error.font = .systemFont(ofSize: 13)
        error.textColor = .systemRed
        error.numberOfLines = 0
        error.textAlignment = .center
        error.isHidden = true
        errorLabel = error

        let homePage = UIButton(type: .system)
        var homePageConfiguration = UIButton.Configuration.plain()
        homePageConfiguration.title = NSLocalizedString("_home_page_", comment: "")
        homePageConfiguration.baseForegroundColor = textColor
        homePage.configuration = homePageConfiguration
        homePage.addTarget(self, action: #selector(actionHomePage(_:)), for: .touchUpInside)
        homePageButton = homePage

        let stackView = UIStackView(arrangedSubviews: [user, password, error, loginButton, homePage])
        stackView.axis = .vertical
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        stackView.setCustomSpacing(8, after: password)
        stackView.setCustomSpacing(18, after: error)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: imageBrand.bottomAnchor, constant: 40),
            stackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            user.heightAnchor.constraint(equalToConstant: 44),
            password.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    /// Matches the styling the storyboard applies to the server address field.
    private func makeCredentialTextField(placeholder: String) -> UITextField {
        let textField = UITextField()
        textField.delegate = self
        textField.textColor = textColor
        textField.tintColor = textColor
        textField.layer.cornerRadius = 10
        textField.layer.borderWidth = 1
        textField.layer.borderColor = textColor.cgColor
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: 44))
        textField.leftViewMode = .always
        textField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 15, height: 44))
        textField.rightViewMode = .always
        textField.attributedPlaceholder = NSAttributedString(string: placeholder,
                                                             attributes: [.foregroundColor: textColor.withAlphaComponent(0.5)])
        return textField
    }

    // MARK: - In-app login

    /// Verifies the credentials against the fixed server and opens the session, without showing a web page.
    ///
    /// `getAppPassword` authenticates with HTTP Basic and answers 401 when the credentials are wrong,
    /// so a successful call both validates the login and hands back an app password to store in place
    /// of the real one.
    private func performDirectLogin() {
        let user = (userTextField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordTextField?.text ?? ""

        guard !user.isEmpty, !password.isEmpty else {
            showInlineError(NSLocalizedString("_login_enter_credentials_", comment: ""))
            return
        }

        var urlBase = NCBrandOptions.shared.loginBaseUrl
        if urlBase.hasSuffix("/") { urlBase = String(urlBase.dropLast()) }

        showInlineError(nil)
        view.endEditing(true)
        setDirectLoginBusy(true)

        Task {
            let results = await NextcloudKit.shared.getAppPasswordAsync(url: urlBase, user: user, password: password)

            guard results.error == .success, let appPassword = results.token else {
                setDirectLoginBusy(false)
                showInlineError(directLoginMessage(for: results.error))
                return
            }

            await createAccount(urlBase: urlBase, user: user, password: appPassword)
            setDirectLoginBusy(false)
        }
    }

    private func directLoginMessage(for error: NKError) -> String {
        let global = NCGlobal.shared
        // A rejected login answers HTTP 401 with an OCS body, and NKError prefers the OCS meta code
        // (997) over the HTTP status, so both have to be matched here. 403 covers a server that
        // refuses plain credentials outright, e.g. when two-factor authentication is enforced.
        let rejected = [global.errorUnauthorized997, global.errorUnauthorized, global.errorForbidden]

        if rejected.contains(error.errorCode) {
            return NSLocalizedString("_wrong_username_or_password_", comment: "")
        }
        return error.errorDescription
    }

    private func setDirectLoginBusy(_ busy: Bool) {
        loginButton.isEnabled = !busy
        loginButton.configuration?.showsActivityIndicator = busy
        loginButton.configuration?.title = busy
            ? NSLocalizedString("_login_checking_", comment: "")
            : NSLocalizedString("_log_in_", comment: "")
        userTextField?.isEnabled = !busy
        passwordTextField?.isEnabled = !busy
        homePageButton?.isEnabled = !busy
    }

    private func showInlineError(_ text: String?) {
        errorLabel?.text = text
        errorLabel?.isHidden = (text?.isEmpty ?? true)
    }

    /// Sign-up lives on the marketing site, not on the storage server.
    @objc private func actionHomePage(_ sender: Any?) {
        guard let url = URL(string: NCBrandOptions.shared.linkLoginHost),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: - TextField

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === userTextField {
            passwordTextField?.becomeFirstResponder()
            return false
        }
        textField.resignFirstResponder()
        actionButtonLogin(self)
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        self.activeTextField = textField
    }

    // MARK: - Keyboard notification

    @objc internal func keyboardWillShow(_ notification: Notification?) {
        activeTextfieldDiff = 0
        if let info = notification?.userInfo, let centerObject = self.activeTextField.superview?.convert(self.activeTextField.center, to: nil) {

            let frameEndUserInfoKey = UIResponder.keyboardFrameEndUserInfoKey
            if let keyboardFrame = info[frameEndUserInfoKey] as? CGRect {
                let diff = keyboardFrame.origin.y - centerObject.y - self.activeTextField.frame.height
                if diff < 0 {
                    activeTextfieldDiff = diff
                    imageBrandConstraintY.constant += diff
                }
            }
        }
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        imageBrandConstraintY.constant -= activeTextfieldDiff
    }

    // MARK: - Action

    @objc func actionCancel(_ sender: Any?) {
        dismiss(animated: true) { }
    }

    @IBAction func actionButtonLogin(_ sender: Any) {
        NCNetworking.shared.p12Data = nil
        NCNetworking.shared.p12Password = nil

        if usesDirectLogin {
            performDirectLogin()
        } else {
            login()
        }
    }

    @IBAction func actionQRCode(_ sender: Any) {
        let qrCode = NCLoginQRCode(delegate: self)
        qrCode.scan()
    }

    @IBAction func actionCertificate(_ sender: Any) {

    }

    // MARK: - Login

    private func login() {
        guard var url = baseUrlTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if url.isEmpty { return }

        attemptLogin(url: url)
    }

    private func attemptLogin(url: String) {
        var url = url

        if url.hasPrefix("https") == false && url.hasPrefix("http") == false {
            url = "https://" + url
        } else if url.isInsecureHTTPURL {
            url = "https://" + url.dropFirst("http://".count)
        }

        self.baseUrlTextField.text = url
        startLogin(url: url)
    }

    private func startLogin(url: String) {
        loginButton.isEnabled = false
        loginButton.hideButtonAndShowSpinner(tint: textColor)

        NextcloudKit.shared.getServerStatus(serverUrl: url) { [self] _, serverInfoResult in
            switch serverInfoResult {
            case .success:
                if let host = URL(string: url)?.host {
                    NCNetworking.shared.writeCertificate(host: host)
                }
                let loginOptions = NKRequestOptions(customUserAgent: userAgent)
                NextcloudKit.shared.getLoginFlowV2(serverUrl: url, options: loginOptions) { [self] token, endpoint, login, _, error in
                    // Login Flow V2
                    if error == .success, let token, let endpoint, let login {
                        nkLog(debug: "Successfully received login flow information.")
                        let loginProvider = NCLoginProvider()
                        loginProvider.initialURLString = login
                        loginProvider.delegate = self
                        loginProvider.controller = self.controller
                        loginProvider.presentingViewController = self
                        loginProvider.startPolling(loginFlowV2Token: token, loginFlowV2Endpoint: endpoint, loginFlowV2Login: login)
                        loginProvider.startAuthentication()
                        self.activeLoginProvider = loginProvider
                    }
                }
            case .failure(let error):
                loginButton.hideSpinnerAndShowButton()
                loginButton.isEnabled = true

                if error.errorCode == NSURLErrorServerCertificateUntrusted {
                    let alertController = UIAlertController(title: NSLocalizedString("_ssl_certificate_untrusted_", comment: ""), message: NSLocalizedString("_connect_server_anyway_", comment: ""), preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_yes_", comment: ""), style: .default, handler: { _ in
                        if let host = URL(string: url)?.host {
                            NCNetworking.shared.writeCertificate(host: host)
                        }
                    }))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_no_", comment: ""), style: .default, handler: { _ in }))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_certificate_details_", comment: ""), style: .default, handler: { _ in
                        if let navigationController = UIStoryboard(name: "NCViewCertificateDetails", bundle: nil).instantiateInitialViewController() as? UINavigationController,
                           let viewController = navigationController.topViewController as? NCViewCertificateDetails {
                            if let host = URL(string: url)?.host {
                                viewController.host = host
                            }
                            self.present(navigationController, animated: true)
                        }
                    }))
                    self.present(alertController, animated: true)
                } else if url.lowercased().hasPrefix("https://") {
                    let httpUrl = "http://" + url.dropFirst("https://".count)

                    #if DEBUG
                    self.baseUrlTextField.text = httpUrl
                    self.startLogin(url: httpUrl)
                    #else
                    // Any failed https attempt may fall back to plain http, but only with explicit consent.
                    let alertController = UIAlertController(title: NSLocalizedString("_warning_", comment: ""),
                                                            message: NSLocalizedString("_https_failed_try_http_", comment: ""),
                                                            preferredStyle: .alert)

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_continue_", comment: ""), style: .destructive) { _ in
                        self.baseUrlTextField.text = httpUrl
                        self.startLogin(url: httpUrl)
                    })

                    self.present(alertController, animated: true)
                    #endif
                } else {
                    let alertController = UIAlertController(title: NSLocalizedString("_connection_error_", comment: ""), message: error.errorDescription, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in }))
                    self.present(alertController, animated: true, completion: { })
                }
            }
        }
    }

    // MARK: - QRCode

    func dismissQRCode(_ value: String?, metadataType: String?) {
        guard let value, !QRCodeCheck else {
            return
        }
        QRCodeCheck = true

        Task { @MainActor in
            let protocolLogin = NCBrandOptions.shared.webLoginAutenticationProtocol + "login/"
            let protocolLoginOneTime = NCBrandOptions.shared.webLoginAutenticationProtocol + "onetime-login/"
            var parameters: String = ""

            if value.hasPrefix(protocolLoginOneTime) {
                parameters = value.replacingOccurrences(of: protocolLoginOneTime, with: "")
            } else if value.hasPrefix(protocolLogin) {
                parameters = value.replacingOccurrences(of: protocolLogin, with: "")
            } else {
                QRCodeCheck = false
                return
            }

            guard parameters.contains("user:"),
                  parameters.contains("password:"),
                  parameters.contains("server:") else {
                QRCodeCheck = false
                return
            }
            let parametersArray = parameters.components(separatedBy: "&")
            let user = parametersArray[0].replacingOccurrences(of: "user:", with: "")
            let password = parametersArray[1].replacingOccurrences(of: "password:", with: "")
            let server = parametersArray[2].replacingOccurrences(of: "server:", with: "")

            if value.hasPrefix(protocolLoginOneTime) {
                let results = await NextcloudKit.shared.getAppPasswordOnetimeAsync(url: server, user: user, onetimeToken: password)
                if results.error == .success, let token = results.token {
                    await createAccount(urlBase: server, user: user, password: token)
                } else {
                    let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)
                    await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                    dismiss(animated: true, completion: nil)
                }
            } else if value.hasPrefix(protocolLogin) {
                await self.createAccount(urlBase: server, user: user, password: password)
            }
        }
    }

    private func getAppPassword(urlBase: String, user: String, password: String) async {
        let results = await NextcloudKit.shared.getAppPasswordAsync(url: urlBase, user: user, password: password)

        if results.error == .success, let password = results.token {
            await self.createAccount(urlBase: urlBase, user: user, password: password)
        } else {
            let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)
            await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
            dismiss(animated: true, completion: nil)
        }
    }

    @MainActor
    private func createAccount(urlBase: String, user: String, password: String) async {
        if self.controller == nil {
            self.controller = UIApplication.shared.mainAppWindow?.rootViewController as? NCMainTabBarController
        }

        if let host = URL(string: urlBase)?.host {
            NCNetworking.shared.writeCertificate(host: host)
        }

        await NCAccount().createAccount(viewController: self, urlBase: urlBase, user: user, password: password, controller: self.controller)
    }
}

// MARK: - UIDocumentPickerDelegate

extension NCLogin: ClientCertificateDelegate, UIDocumentPickerDelegate {
    func didAskForClientCertificate() {
        let alertNoCertFound = UIAlertController(title: NSLocalizedString("_no_client_cert_found_", comment: ""), message: NSLocalizedString("_no_client_cert_found_desc_", comment: ""), preferredStyle: .alert)
        alertNoCertFound.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel, handler: nil))
        alertNoCertFound.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in
            let documentProviderMenu = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pkcs12])
            documentProviderMenu.delegate = self
            self.present(documentProviderMenu, animated: true, completion: nil)
        }))
        DispatchQueue.main.async {
            self.present(alertNoCertFound, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let alertEnterPassword = UIAlertController(title: NSLocalizedString("_client_cert_enter_password_", comment: ""), message: "", preferredStyle: .alert)
        alertEnterPassword.addAction(UIAlertAction(title: NSLocalizedString("_cancel_", comment: ""), style: .cancel, handler: nil))
        alertEnterPassword.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default, handler: { _ in
            NCNetworking.shared.p12Data = try? Data(contentsOf: urls[0])
            NCNetworking.shared.p12Password = alertEnterPassword.textFields?[0].text
            self.login()
        }))
        alertEnterPassword.addTextField { textField in
            textField.isSecureTextEntry = true
        }
        DispatchQueue.main.async {
            self.present(alertEnterPassword, animated: true)
        }
    }

    func onIncorrectPassword() {
        NCNetworking.shared.p12Data = nil
        NCNetworking.shared.p12Password = nil
        let alertWrongPassword = UIAlertController(title: NSLocalizedString("_client_cert_wrong_password_", comment: ""), message: "", preferredStyle: .alert)
        alertWrongPassword.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default))
        DispatchQueue.main.async {
            self.present(alertWrongPassword, animated: true)
        }
    }
}

// MARK: - NCLoginProviderDelegate

extension NCLogin: NCLoginProviderDelegate {
    func onBack() {
        loginButton.isEnabled = true
        loginButton.hideSpinnerAndShowButton()
        activeLoginProvider?.cancel()
        activeLoginProvider = nil
    }
}
