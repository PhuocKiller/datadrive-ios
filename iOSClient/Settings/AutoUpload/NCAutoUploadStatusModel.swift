// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UniformTypeIdentifiers
import NextcloudKit

/// Feeds the auto upload status screen: how many photos and videos are backed up, and what is
/// still waiting and why. Everything is read from the local database, so it also works offline.
@MainActor
final class NCAutoUploadStatusModel: ObservableObject {
    @Published private(set) var donePhotos = 0
    @Published private(set) var doneVideos = 0
    @Published private(set) var pendingPhotos = 0
    @Published private(set) var pendingVideos = 0
    @Published private(set) var pendingItems: [NCAutoUploadStatusItem] = []
    @Published private(set) var isLoaded = false

    var done: Int { donePhotos + doneVideos }
    var total: Int { done + pendingPhotos + pendingVideos }
    var isAllDone: Bool { isLoaded && total > 0 && pendingItems.isEmpty }
    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    private var session: NCSession.Session?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let global = NCGlobal.shared

    func start(session: NCSession.Session) {
        self.session = session
        guard observer == nil else {
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: global.notificationCenterTransferCountChanged),
                                                          object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        // Reasons such as "retry at 11:45" change without any transfer event.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                await self.refresh()
            }
        }
        Task {
            await refresh()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard let session else {
            return
        }
        let database = NCManageDatabase.shared
        let serverUrlBase = await database.getAccountAutoUploadServerUrlBaseAsync(account: session.account,
                                                                                   urlBase: session.urlBase,
                                                                                   userId: session.userId)
        let status = await database.getAutoUploadStatusAsync(account: session.account,
                                                             autoUploadServerUrlBase: serverUrlBase)

        // Backed up: photos and videos, without the video half of Live Photos.
        var photoNames = Set<String>()
        var videoNames: [String] = []
        for fileName in status.doneFileNames {
            if Self.isVideo(fileName: fileName) {
                videoNames.append(fileName)
            } else {
                photoNames.insert((fileName as NSString).deletingPathExtension)
            }
        }
        let videos = videoNames.filter { !photoNames.contains(($0 as NSString).deletingPathExtension) }

        let isWiFi = NCNetworking.shared.networkReachability == NKTypeReachability.reachableEthernetOrWiFi
        let items = status.pending.map { item in
            NCAutoUploadStatusItem(id: item.ocId,
                                   fileName: item.fileName,
                                   isVideo: item.isVideo,
                                   reason: reason(status: item.status,
                                                  session: item.session,
                                                  chunk: item.chunk,
                                                  errorCode: item.errorCode,
                                                  sessionDate: item.sessionDate,
                                                  isWiFi: isWiFi))
        }

        donePhotos = photoNames.count
        doneVideos = videos.count
        pendingPhotos = items.filter { !$0.isVideo }.count
        pendingVideos = items.filter { $0.isVideo }.count
        pendingItems = items
        isLoaded = true
    }

    /// Puts every waiting failure back in the queue now instead of at its retry time.
    func retryNow() async {
        guard let session else {
            return
        }
        let database = NCManageDatabase.shared
        let serverUrlBase = await database.getAccountAutoUploadServerUrlBaseAsync(account: session.account,
                                                                                   urlBase: session.urlBase,
                                                                                   userId: session.userId)
        let metadatas = await database.getMetadatasAsync(predicate: NSPredicate(format: "account == %@ AND autoUploadServerUrlBase == %@ AND sessionSelector == %@ AND status == %d",
                                                                                 session.account,
                                                                                 serverUrlBase,
                                                                                 global.selectorUploadAutoUpload,
                                                                                 global.metadataStatusUploadError))
        for metadata in metadatas {
            await NCAutoUploadCoordinator.shared.resetRetry(ocId: metadata.ocId)
            let uploadSession = metadata.chunk > 0 ? NCNetworking.shared.sessionUpload : NCNetworking.shared.sessionUploadBackground
            await database.setMetadataSessionAsync(ocId: metadata.ocId,
                                                   session: metadata.session == NCNetworking.shared.sessionUploadBackgroundWWan ? metadata.session : uploadSession,
                                                   sessionError: "",
                                                   status: global.metadataStatusWaitUpload)
        }
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: global.notificationCenterNetworkingProcess), object: nil)
        await refresh()
    }

    // MARK: - Helpers

    private func reason(status: Int,
                        session: String,
                        chunk: Int,
                        errorCode: Int,
                        sessionDate: Date?,
                        isWiFi: Bool) -> String {
        if status == global.metadataStatusUploading {
            return NSLocalizedString("_autoupload_reason_uploading_", value: "Uploading", comment: "")
        }

        if status == global.metadataStatusUploadError {
            if errorCode == global.errorQuota {
                return NSLocalizedString("_autoupload_reason_quota_", value: "Storage full", comment: "")
            }
            // The queue retries a failure once its date is 5 minutes old.
            let retryDate = (sessionDate ?? Date()).addingTimeInterval(NCAutoUploadCoordinator.defaultRetryDelay)
            if errorCode == global.errorAutoUploadAssetUnavailable {
                let icloud = NSLocalizedString("_autoupload_reason_icloud_", value: "Downloading from iCloud", comment: "")
                return retryDate > Date() ? icloud + " · " + retryText(retryDate) : icloud
            }
            if retryDate > Date() {
                return retryText(retryDate)
            }
            return NSLocalizedString("_autoupload_reason_waiting_", value: "Waiting", comment: "")
        }

        if session == NCNetworking.shared.sessionUploadBackgroundWWan, !isWiFi {
            return NSLocalizedString("_autoupload_reason_wifi_", value: "Waiting for Wi-Fi", comment: "")
        }
        if chunk > 0 {
            return NSLocalizedString("_autoupload_reason_open_app_", value: "Uploads while the app is open", comment: "")
        }
        return NSLocalizedString("_autoupload_reason_waiting_", value: "Waiting", comment: "")
    }

    private func retryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return String(format: NSLocalizedString("_autoupload_reason_retry_at_", value: "Will retry at %@", comment: ""),
                      formatter.string(from: date))
    }

    nonisolated static func isVideo(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .movie)
    }

    nonisolated static func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
