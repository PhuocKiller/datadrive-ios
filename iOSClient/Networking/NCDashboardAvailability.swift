// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Tran Huy Phuoc
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Remembers which accounts sit on a server that has no Dashboard app installed.
///
/// `/ocs/v2.php/apps/dashboard/api/v1/widgets` answers 404 when the app is disabled server side,
/// and the widget request runs on every foreground. Without this the app would keep firing a
/// request it already knows will fail, once per foreground, for the whole lifetime of the install.
///
/// The state is deliberately kept in memory only: an admin who enables the Dashboard app later
/// gets picked up again on the next app launch.
actor NCDashboardAvailability {
    static let shared = NCDashboardAvailability()

    private var accountsWithoutDashboard: Set<String> = []

    func isUnavailable(account: String) -> Bool {
        accountsWithoutDashboard.contains(account)
    }

    func markUnavailable(account: String) {
        accountsWithoutDashboard.insert(account)
    }
}
