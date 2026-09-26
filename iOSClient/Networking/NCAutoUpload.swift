// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2021 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import CoreLocation
import NextcloudKit
import Photos
import OrderedCollections
import LucidBanner

class NCAutoUpload: NSObject {
    static let shared = NCAutoUpload()

    private let database = NCManageDatabase.shared
    private let global = NCGlobal.shared
    private let networking = NCNetworking.shared
    private var endForAssetToUpload: Bool = false

    func initAutoUpload(controller: NCMainTabBarController? = nil) async -> Int {
        guard self.networking.isOnline else {
            return 0
        }
        // Scene activation, BGTasks and the background refill all call this; two scans at
        // once would queue the same photos twice before autoUploadSinceDate moves forward.
        guard await NCAutoUploadCoordinator.shared.beginScan() else {
            return 0
        }
        let counter = await scanAndQueueAutoUpload()
        await NCAutoUploadCoordinator.shared.endScan()
        return counter
    }

    private func scanAndQueueAutoUpload() async -> Int {
        var counter = 0

        let tblAccounts = await NCManageDatabase.shared.getTableAccountsAsync(predicate: NSPredicate(format: "autoUploadStart == true"))
        for tblAccount in tblAccounts {
            let albumIds = NCPreferences().getAutoUploadAlbumIds(account: tblAccount.account)
            let assetCollections = PHAssetCollection.allAlbums.filter({albumIds.contains($0.localIdentifier)})
            let result = await getCameraRollAssets(controller: nil, assetCollections: assetCollections, tblAccount: tableAccount(value: tblAccount))
            if let assets = result.assets, !assets.isEmpty, let fileNames = result.fileNames {
                let item = await uploadAssets(controller: nil, tblAccount: tblAccount, assets: assets, fileNames: fileNames, filterExistingQueue: true)
                counter += item
            }
        }

        return counter
    }

    @MainActor
    func startManualAutoUploadForAlbums(controller: NCMainTabBarController?,
                                        model: NCAutoUploadModel,
                                        assetCollections: [PHAssetCollection],
                                        account: String) async {
        let windowScene = SceneManager.shared.getWindowScene(controller: controller)
        var banner: LucidBanner?
        defer {
            if let banner {
                banner.dismiss()
            }
        }

        guard let tblAccount = await self.database.getTableAccountAsync(predicate: NSPredicate(format: "account == %@", account)) else {
            return
        }

        (banner, _) = await showBanner(windowScene: windowScene,
                                       title: "_info_",
                                       subtitle: "_creating_db_photo_progress_",
                                       systemImage: "photo.on.rectangle.angled",
                                       imageAnimation: .bounce,
                                       imageColor: .systemBlue,
                                       autoDismissAfter: 0,
                                       swipeToDismiss: false
        )

        // Wait for a scan started elsewhere (scene activation, background refill) to finish.
        while !(await NCAutoUploadCoordinator.shared.beginScan()) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let result = await getCameraRollAssets(controller: controller, assetCollections: assetCollections, tblAccount: tblAccount)

        // IMPORTANT: Always set to autoUploadSinceDate to now
        await self.database.updateAccountPropertyAsync(\.autoUploadSinceDate, value: Date.now, account: tblAccount.account)

        model.onViewAppear()

        guard let assets = result.assets,
              !assets.isEmpty,
              let fileNames = result.fileNames else {
            await NCAutoUploadCoordinator.shared.endScan()
            nkLog(debug: "Automatic upload 0 upload")
            return
        }

        let num = await uploadAssets(controller: controller, tblAccount: tblAccount, assets: assets, fileNames: fileNames, filterExistingQueue: true)
        await NCAutoUploadCoordinator.shared.endScan()
        nkLog(debug: "Automatic upload \(num) upload")
    }

    private func uploadAssets(controller: NCMainTabBarController?,
                              tblAccount: tableAccount,
                              assets: [PHAsset],
                              fileNames: [String],
                              filterExistingQueue: Bool) async -> Int {
        let capabilities = await NKCapabilities.shared.getCapabilities(for: tblAccount.account)
        let autoMkcol = NCBrandOptions.shared.isServerVersion(capabilities, greaterOrEqualTo: .v33)
        let session = NCSession.shared.getSession(account: tblAccount.account)
        let autoUploadServerUrlBase = await self.database.getAccountAutoUploadServerUrlBaseAsync(account: tblAccount.account, urlBase: tblAccount.urlBase, userId: tblAccount.userId)
        var metadatas: [tableMetadata] = []
        let formatCompatibility = NCPreferences().formatCompatibility
        let keychainLivePhoto = NCPreferences().livePhoto
        let fileSystem = NCUtilityFileSystem()
        let skipFileNames = await self.database.fetchSkipFileNamesAsync(account: tblAccount.account,
                                                                        autoUploadServerUrlBase: autoUploadServerUrlBase)

        nkLog(debug: "Automatic upload, new \(assets.count) assets found")

        for (index, asset) in assets.enumerated() {
            let fileName = fileNames[index]

            let sourceFileExtension = (fileName as NSString).pathExtension.lowercased()
            let fileNameCompatible = NCCameraRoll.outputFileName(
                for: fileName,
                sourceFileExtension: sourceFileExtension,
                nativeFormat: !formatCompatibility
            )

            if skipFileNames.contains(fileNameCompatible) || skipFileNames.contains(fileName) {
                continue
            }

            let mediaType = asset.mediaType
            let isLivePhoto = asset.mediaSubtypes.contains(.photoLive) && keychainLivePhoto
            let serverUrl = tblAccount.autoUploadCreateSubfolder ? fileSystem.createGranularityPath(asset: asset, serverUrlBase: autoUploadServerUrlBase) : autoUploadServerUrlBase
            let onWWAN = (mediaType == .image && tblAccount.autoUploadWWAnPhoto) || (mediaType == .video && tblAccount.autoUploadWWAnVideo)
            let uploadSession = onWWAN ? self.networking.sessionUploadBackgroundWWan : self.networking.sessionUploadBackground

            let metadata = await NCManageDatabaseCreateMetadata().createMetadataAsync(
                fileName: fileNameCompatible,
                ocId: UUID().uuidString,
                serverUrl: serverUrl,
                session: session,
                sceneIdentifier: controller?.sceneIdentifier)

            if isLivePhoto {
                metadata.livePhotoFile = (metadata.fileName as NSString).deletingPathExtension + ".mov"
            }

            metadata.assetLocalIdentifier = asset.localIdentifier
            metadata.autoUploadServerUrlBase = autoUploadServerUrlBase
            metadata.session = uploadSession
            metadata.sessionSelector = NCGlobal.shared.selectorUploadAutoUpload
            metadata.status = NCGlobal.shared.metadataStatusWaitUpload
            metadata.sessionDate = Date()

            metadata.classFile = {
                switch mediaType {
                case .video: return NKTypeClassFile.video.rawValue
                case .image: return NKTypeClassFile.image.rawValue
                default: return ""
                }
            }()

            metadata.iconName = {
                switch mediaType {
                case .video: return NKTypeIconFile.video.rawValue
                case .image: return NKTypeIconFile.image.rawValue
                default: return ""
                }
            }()

            metadata.typeIdentifier = {
                switch mediaType {
                case .video: return "com.apple.quicktime-movie"
                case .image: return "public.image"
                default: return ""
                }
            }()

            metadatas.append(metadata)
        }

        // Set last date in autoUploadOnlyNewSinceDate
        if let metadata = metadatas.last {
            let date = metadata.creationDate as Date
            await self.database.updateAccountPropertyAsync(\.autoUploadSinceDate, value: date, account: session.account)
        }

        guard !metadatas.isEmpty else {
            return 0
        }

        let metadatasToAdd: [tableMetadata]

        if filterExistingQueue {
            metadatasToAdd = await self.database.filterAutoUploadMetadatasNotAlreadyQueuedAsync(metadatas)
        } else {
            metadatasToAdd = metadatas
        }

        guard !metadatasToAdd.isEmpty else {
            return 0
        }

        if autoMkcol {
            await self.database.addMetadatasAsync(metadatasToAdd)
        } else {
            let metadatasFolder = await NCManageDatabaseCreateMetadata().createMetadatasFolderAsync(
                assets: assets,
                useSubFolder: tblAccount.autoUploadCreateSubfolder,
                session: session)
            await self.database.addMetadatasAsync(metadatasFolder + metadatasToAdd)
        }

        return metadatasToAdd.count
    }

    // MARK: -

    func getCameraRollAssets(controller: NCMainTabBarController?,
                             assetCollections: [PHAssetCollection] = [],
                             tblAccount: tableAccount) async -> (assets: [PHAsset]?, fileNames: [String]?) {
        let hasPermission = await withCheckedContinuation { continuation in
            NCAskAuthorization().askAuthorizationPhotoLibrary(controller: controller) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard hasPermission else {
            return (nil, nil)
        }
        let autoUploadServerUrlBase = await self.database.getAccountAutoUploadServerUrlBaseAsync(account: tblAccount.account, urlBase: tblAccount.urlBase, userId: tblAccount.userId)
        var mediaPredicates: [NSPredicate] = []
        var datePredicates: [NSPredicate] = []
        let fetchOptions = PHFetchOptions()

        if tblAccount.autoUploadImage {
            mediaPredicates.append(NSPredicate(format: "mediaType == %i", PHAssetMediaType.image.rawValue))
        }

        if tblAccount.autoUploadVideo {
            mediaPredicates.append(NSPredicate(format: "mediaType == %i", PHAssetMediaType.video.rawValue))
        }

        if let autoUploadSinceDate = tblAccount.autoUploadSinceDate {
            datePredicates.append(NSPredicate(format: "creationDate > %@", autoUploadSinceDate as NSDate))
        } else if let lastDate = await self.database.fetchLastAutoUploadedDateAsync(account: tblAccount.account, autoUploadServerUrlBase: autoUploadServerUrlBase) {
            datePredicates.append(NSPredicate(format: "creationDate > %@", lastDate as NSDate))
        }

        fetchOptions.predicate = {
            switch (mediaPredicates.isEmpty, datePredicates.isEmpty) {
            case (false, false):
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSCompoundPredicate(orPredicateWithSubpredicates: mediaPredicates),
                    NSCompoundPredicate(andPredicateWithSubpredicates: datePredicates)
                ])
            case (false, true):
                return NSCompoundPredicate(orPredicateWithSubpredicates: mediaPredicates)
            case (true, false):
                return NSCompoundPredicate(andPredicateWithSubpredicates: datePredicates)
            default:
                return nil
            }
        }()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let collections: [PHAssetCollection] = {
            if assetCollections.isEmpty {
                let fetched = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
                return fetched.firstObject.map { [$0] } ?? []
            } else {
                return assetCollections
            }
        }()

        guard !collections.isEmpty else {
             return (nil, nil)
        }

        let allAssets = collections.flatMap { collection in
            let result = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            return result.objects(at: IndexSet(0..<result.count))
        }
        let newAssets = OrderedSet(allAssets)
        let fileNames = newAssets.compactMap { asset -> String? in
            let date = asset.creationDate ?? Date()
            return NCUtilityFileSystem().createFileName(asset.originalFilename, fileDate: date, fileType: asset.mediaType)
        }

        return(Array(newAssets), fileNames)
    }

    // MARK: - Background

    // Executes the background synchronization flow for Auto Upload.
    //
    // The function:
    // - discovers new Auto Upload items,
    // - fetches pending metadata,
    // - creates missing folders when required,
    // - checks remote existence,
    // - expands seeds into concrete metadata items,
    // - hands them to the background URLSession, which keeps uploading with the screen off.
    //
    // Every upload that finishes in the background wakes the app, and `scheduleBackgroundRefill()`
    // runs this again, so the queue keeps moving without the app being opened.
    //
    // The flow cooperates with Swift task cancellation triggered by BGTask expiration.
    func autoUploadBackgroundSync() async {
        guard !Task.isCancelled else { return }

        let coordinator = NCAutoUploadCoordinator.shared
        guard await coordinator.beginBackgroundSync() else {
            return
        }
        await runBackgroundSync()
        await coordinator.endBackgroundSync()
    }

    private func runBackgroundSync() async {
        let coordinator = NCAutoUploadCoordinator.shared

        // Discover new items for Auto Upload.
        let numAutoUpload = await initAutoUpload()
        nkLog(tag: self.global.logTagBgSync, emoji: .start, message: "Auto upload found \(numAutoUpload) new items")

        guard !Task.isCancelled else { return }

        // Fetch pending metadata.
        var metadatas = await NCManageDatabase.shared.getMetadataProcess()
        guard !metadatas.isEmpty, !Task.isCancelled else {
            return
        }

        // Failed uploads older than 5 minutes go back to the queue, as in the foreground.
        let retryDate = Date().addingTimeInterval(-300)
        let failed = metadatas.filter {
            $0.status == self.global.metadataStatusUploadError &&
            $0.sessionSelector == self.global.selectorUploadAutoUpload &&
            ($0.sessionDate ?? .distantFuture) < retryDate
        }
        if !failed.isEmpty {
            for metadata in failed {
                await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                      session: self.networking.sessionUploadBackground,
                                                                      sessionError: "",
                                                                      status: self.global.metadataStatusWaitUpload)
            }
            metadatas = await NCManageDatabase.shared.getMetadataProcess()
        }

        // Create all pending Auto Upload folders (fail-fast).
        let pendingCreateFolders = metadatas.lazy.filter {
            $0.status == self.global.metadataStatusWaitCreateFolder &&
            $0.sessionSelector == self.global.selectorUploadAutoUpload
        }

        // Resolve capabilities once per account.
        let accounts = Array(Set(pendingCreateFolders.map { $0.account }))
        var capabilitiesByAccount: [String: NKCapabilities.Capabilities] = [:]

        for account in accounts {
            guard !Task.isCancelled else { return }

            let capabilities = await NKCapabilities.shared.getCapabilities(for: account)
            capabilitiesByAccount[account] = capabilities
        }

        for metadata in pendingCreateFolders {
            guard !Task.isCancelled else { return }

            // If server supports auto MKCOL (Nextcloud >= 33), skip manual folder creation.
            if let capabilities = capabilitiesByAccount[metadata.account] {
                let autoMkcol = NCBrandOptions.shared.isServerVersion(capabilities, greaterOrEqualTo: .v33)
                if autoMkcol {
                    continue
                }
            }

            let err = await NCNetworking.shared.createFolderForAutoUpload(
                serverUrlFileName: metadata.serverUrlFileName,
                account: metadata.account
            )

            if err != .success {
                nkLog(
                    tag: self.global.logTagBgSync,
                    emoji: .error,
                    message: "Create folder '\(metadata.serverUrlFileName)' failed: \(err.errorCode) – aborting sync"
                )
                return
            }
        }

        // Compute available capacity. Uploads handed to the background URLSession run on
        // their own, so the background can keep more of them in flight than the foreground.
        let downloading = metadatas.lazy.filter { $0.status == self.global.metadataStatusDownloading }.count
        let uploading = metadatas.lazy.filter { $0.status == self.global.metadataStatusUploading }.count
        let availableProcess = max(0, NCAutoUploadCoordinator.backgroundMaxInFlight - (downloading + uploading))
        let isWiFi = self.networking.networkReachability == NKTypeReachability.reachableEthernetOrWiFi

        // Select Auto Upload candidates: photos first, then by queue date.
        // Large files (chunk > 0) need the app in the foreground and are left for it.
        let metadatasToUpload = Array(
            metadatas.filter {
                $0.status == self.global.metadataStatusWaitUpload &&
                $0.sessionSelector == self.global.selectorUploadAutoUpload &&
                $0.chunk == 0 &&
                (isWiFi || $0.session != self.networking.sessionUploadBackgroundWWan)
            }
            .sorted { lhs, rhs in
                let lhsVideo = lhs.classFile == NKTypeClassFile.video.rawValue
                let rhsVideo = rhs.classFile == NKTypeClassFile.video.rawValue
                if lhsVideo != rhsVideo {
                    return !lhsVideo
                }
                return (lhs.sessionDate ?? .distantFuture) < (rhs.sessionDate ?? .distantFuture)
            }
            .prefix(availableProcess)
        )

        let cameraRoll = NCCameraRoll()

        for metadata in metadatasToUpload {
            guard !Task.isCancelled else { return }

            guard await coordinator.claim(ocId: metadata.ocId, serverUrlFileName: metadata.serverUrlFileName) else {
                continue
            }
            await backgroundUpload(metadata: metadata, cameraRoll: cameraRoll)
            await coordinator.release(ocId: metadata.ocId, serverUrlFileName: metadata.serverUrlFileName)
        }
    }

    private func backgroundUpload(metadata: tableMetadata, cameraRoll: NCCameraRoll) async {
        // The snapshot may be stale: the foreground pipeline could have sent it meanwhile.
        guard let current = await NCManageDatabase.shared.getMetadataFromOcIdAsync(metadata.ocId),
              current.status == self.global.metadataStatusWaitUpload else {
            return
        }

        // Check whether the file already exists remotely.
        let existsResult = await NCNetworking.shared.fileExists(
            serverUrlFileName: metadata.serverUrlFileName,
            account: metadata.account
        )

        if existsResult == .success {
            await NCManageDatabase.shared.deleteMetadataAsync(id: metadata.ocId)
            return
        } else if existsResult.errorCode != 404 {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: existsResult.errorDescription,
                                                                  status: self.global.metadataStatusUploadError,
                                                                  errorCode: existsResult.errorCode)
            return
        }

        // Expand the seed into concrete metadata entries (for example, Live Photo pairs).
        let extractedMetadatas = await cameraRoll.extractCameraRoll(from: metadata)

        if extractedMetadatas.isEmpty {
            await handleExtractionFailure(metadata: metadata)
            return
        }

        for extractedMetadata in extractedMetadatas {
            // Too large for a single PUT: stays queued for the chunked upload in the foreground.
            guard extractedMetadata.chunk == 0, !extractedMetadata.e2eEncrypted else {
                continue
            }

            let err = await NCNetworking.shared.uploadFileInBackground(
                metadata: extractedMetadata.detachedCopy()
            )

            if err == .success {
                nkLog(
                    tag: self.global.logTagBgSync,
                    message: "In queued upload \(extractedMetadata.fileName) -> \(extractedMetadata.serverUrl)"
                )
            } else {
                nkLog(
                    tag: self.global.logTagBgSync,
                    emoji: .error,
                    message: "Upload failed \(extractedMetadata.fileName) -> \(extractedMetadata.serverUrl) [\(err.errorDescription)]"
                )
            }
        }
    }

    /// Runs the background sync again while the app is in the background, for example when
    /// iOS wakes the app because an upload of the background URLSession finished. This is what
    /// keeps auto upload going with the screen off: each finished upload queues the next ones.
    func scheduleBackgroundRefill() {
        Task { @MainActor in
            guard isAppInBackground,
                  UIApplication.shared.applicationState != .active,
                  NCManageDatabase.shared.openRealmBackground() else {
                return
            }
            let app = UIApplication.shared
            var bgID: UIBackgroundTaskIdentifier = .invalid
            let work = Task.detached {
                await self.autoUploadBackgroundSync()
            }
            bgID = app.beginBackgroundTask(withName: "AutoUploadRefill") {
                work.cancel()
                app.endBackgroundTask(bgID)
                bgID = .invalid
            }
            guard bgID != .invalid else {
                work.cancel()
                return
            }
            await work.value
            if bgID != .invalid {
                app.endBackgroundTask(bgID)
                bgID = .invalid
            }
        }
    }

    /// The asset could not be read from the photo library. If it is still there (iCloud
    /// download failed, export timed out…) retry later; if the user deleted it, drop it.
    func handleExtractionFailure(metadata: tableMetadata) async {
        let assetExists = !metadata.assetLocalIdentifier.isEmpty &&
            PHAsset.fetchAssets(withLocalIdentifiers: [metadata.assetLocalIdentifier], options: nil).count > 0

        if assetExists {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: "Extraction failed",
                                                                  status: self.global.metadataStatusUploadError)
        } else {
            await NCManageDatabase.shared.deleteMetadataAsync(id: metadata.ocId)
        }
    }
}
