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

    /// Waits before retrying a temporary failure (423, 5xx, lost connection…): 2 s, 5 s, 15 s,
    /// 30 s, 60 s, 60 s, then the normal 5 minute retry of the queue.
    static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60, 60]
    static let defaultRetryDelay: TimeInterval = 300

    private var claimedOcIds: Set<String> = []
    private var claimedServerUrlFileNames: Set<String> = []
    private var retryAttempts: [String: Int] = [:]
    private var readyFolders: Set<String> = []
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

    // MARK: - Retry

    /// Delay before the next attempt of a temporary failure, with some jitter so parallel
    /// uploads that failed together do not all come back at the same moment.
    func nextRetryDelay(ocId: String) -> TimeInterval {
        let attempt = retryAttempts[ocId, default: 0]
        retryAttempts[ocId] = attempt + 1
        guard attempt < Self.retryDelays.count else {
            return Self.defaultRetryDelay
        }
        let delay = Self.retryDelays[attempt]
        return delay + Double.random(in: 0...(delay * 0.3))
    }

    func resetRetry(ocId: String) {
        retryAttempts.removeValue(forKey: ocId)
    }

    // MARK: - Destination folders

    /// A folder is "ready" once one upload into it went through. Until then only one upload
    /// at a time goes into it: parallel PUTs into a folder the server is still creating hit
    /// its lock and get 423.
    func isFolderReady(_ serverUrl: String) -> Bool {
        readyFolders.contains(serverUrl)
    }

    func markFolderReady(_ serverUrl: String) {
        readyFolders.insert(serverUrl)
    }

    // MARK: - Quota

    private var quotaWarningShown = false

    /// True the first time only: a full storage fails every upload, one message is enough.
    func shouldShowQuotaWarning() -> Bool {
        guard !quotaWarningShown else {
            return false
        }
        quotaWarningShown = true
        return true
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
