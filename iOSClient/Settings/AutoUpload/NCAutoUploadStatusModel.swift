// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Photos
import UniformTypeIdentifiers
import NextcloudKit

/// Feeds the auto upload status (More tab and auto upload screen): how many of the photos and
/// videos on this device are backed up, and what is still waiting and why.
///
/// The totals come from the photo library itself, not from the upload queue: the queue is
/// emptied when auto upload is stopped, and it knows nothing about photos taken afterwards.
/// "Backed up" means the library identifier of the asset is in the auto upload records.
@MainActor
final class NCAutoUploadStatusModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var donePhotos = 0
    @Published private(set) var totalPhotos = 0
    @Published private(set) var doneVideos = 0
    @Published private(set) var totalVideos = 0
    @Published private(set) var photosEnabled = true
    @Published private(set) var videosEnabled = true
    @Published private(set) var autoUploadStart = false
    @Published private(set) var pendingItems: [NCAutoUploadStatusItem] = []
    @Published private(set) var isLoaded = false

    var done: Int { donePhotos + doneVideos }
    var total: Int { totalPhotos + totalVideos }
    var remaining: Int { max(0, total - done) }
    var isAllDone: Bool { isLoaded && total > 0 && remaining == 0 }
    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    /// One line for the More tab.
    var summary: String {
        guard isLoaded, total > 0 else {
            return ""
        }
        if isAllDone {
            return NSLocalizedString("_autoupload_status_all_done_", value: "All photos and videos are backed up", comment: "")
        }
        return progressText + " · " + stateText
    }

    var progressText: String {
        String(format: NSLocalizedString("_autoupload_status_progress_", value: "Backed up %@ / %@", comment: ""),
               Self.formatted(done),
               Self.formatted(total))
    }

    /// "Backing up…" while auto upload runs, "Backup not finished" when it was stopped.
    var stateText: String {
        autoUploadStart
            ? NSLocalizedString("_autoupload_status_running_", value: "Backing up…", comment: "")
            : NSLocalizedString("_autoupload_status_not_finished_", value: "Backup not finished", comment: "")
    }

    private var session: NCSession.Session?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var library: (photos: [String], videos: [String]) = ([], [])
    private var libraryIsStale = true
    private var isRefreshing = false
    private let global = NCGlobal.shared

    func start(session: NCSession.Session) {
        self.session = session
        // Always count the library again when the screen appears: photos may have been added.
        libraryIsStale = true
        Task {
            await refresh()
        }
        guard observer == nil else {
            return
        }
        PHPhotoLibrary.shared().register(self)
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
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
        timer?.invalidate()
        timer = nil
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.libraryIsStale = true
            await self.refresh()
        }
    }

    func refresh() async {
        guard let session, !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let database = NCManageDatabase.shared
        guard let tblAccount = await database.getTableAccountAsync(account: session.account) else {
            return
        }
        let serverUrlBase = await database.getAccountAutoUploadServerUrlBaseAsync(account: session.account,
                                                                                   urlBase: session.urlBase,
                                                                                   userId: session.userId)

        if libraryIsStale {
            libraryIsStale = false
            let albumIds = NCPreferences().getAutoUploadAlbumIds(account: session.account)
            let newOnlyDate = NCPreferences().getAutoUploadNewOnlyDate(account: session.account)
            library = await Task.detached(priority: .utility) {
                Self.libraryAssets(albumIds: albumIds, sinceDate: newOnlyDate)
            }.value
        }

        let status = await database.getAutoUploadStatusAsync(account: session.account,
                                                             autoUploadServerUrlBase: serverUrlBase)

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

        photosEnabled = tblAccount.autoUploadImage
        videosEnabled = tblAccount.autoUploadVideo
        autoUploadStart = tblAccount.autoUploadStart
        totalPhotos = photosEnabled ? library.photos.count : 0
        donePhotos = photosEnabled ? library.photos.filter { status.doneAssetIds.contains($0) }.count : 0
        totalVideos = videosEnabled ? library.videos.count : 0
        doneVideos = videosEnabled ? library.videos.filter { status.doneAssetIds.contains($0) }.count : 0
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

    /// Library identifiers of the photos and videos auto upload covers: the chosen albums
    /// (or the whole library), from the "new photos only" date if the user set one.
    nonisolated static func libraryAssets(albumIds: [String], sinceDate: Date?) -> (photos: [String], videos: [String]) {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            return ([], [])
        }

        var collections = PHAssetCollection.allAlbums.filter { albumIds.contains($0.localIdentifier) }
        if collections.isEmpty,
           let library = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            collections = [library]
        }

        let options = PHFetchOptions()
        if let sinceDate {
            options.predicate = NSPredicate(format: "creationDate > %@", sinceDate as NSDate)
        }

        var seen = Set<String>()
        var photos: [String] = []
        var videos: [String] = []
        for collection in collections {
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                guard seen.insert(asset.localIdentifier).inserted else {
                    return
                }
                switch asset.mediaType {
                case .image: photos.append(asset.localIdentifier)
                case .video: videos.append(asset.localIdentifier)
                default: break
                }
            }
        }
        return (photos, videos)
    }

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
