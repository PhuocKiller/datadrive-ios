// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Serializes the auto upload work that can be started from several places at once:
/// the foreground pipeline, the background refill after a finished upload, BGTasks and
/// significant location changes.
///
/// Without it two of these paths could pick the same queued item and send the same PUT
/// twice (the server answers the second one with 423 Locked), or scan the photo library
/// twice and queue the same asset twice.
actor NCAutoUploadCoordinator {
    static let shared = NCAutoUploadCoordinator()

    /// How many uploads the background refill keeps handed to the background URLSession.
    /// Those keep running while the screen is off; every finished one wakes the app to refill.
    static let backgroundMaxInFlight = 40

    private var claimedOcIds: Set<String> = []
    private var claimedServerUrlFileNames: Set<String> = []
    private var isScanning = false
    private var isBackgroundSyncRunning = false

    // MARK: - Upload claims

    /// Reserves an item for upload. Returns `false` when another path is already handling
    /// the same item or the same destination file.
    func claim(ocId: String, serverUrlFileName: String) -> Bool {
        guard !claimedOcIds.contains(ocId),
              !claimedServerUrlFileNames.contains(serverUrlFileName) else {
            return false
        }
        claimedOcIds.insert(ocId)
        claimedServerUrlFileNames.insert(serverUrlFileName)
        return true
    }

    func release(ocId: String, serverUrlFileName: String) {
        claimedOcIds.remove(ocId)
        claimedServerUrlFileNames.remove(serverUrlFileName)
    }

    // MARK: - Photo library scan

    func beginScan() -> Bool {
        guard !isScanning else {
            return false
        }
        isScanning = true
        return true
    }

    func endScan() {
        isScanning = false
    }

    // MARK: - Background sync

    func beginBackgroundSync() -> Bool {
        guard !isBackgroundSyncRunning else {
            return false
        }
        isBackgroundSyncRunning = true
        return true
    }

    func endBackgroundSync() {
        isBackgroundSyncRunning = false
    }
}
