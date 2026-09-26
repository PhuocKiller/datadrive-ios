// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import RealmSwift
import NextcloudKit

class tableAutoUploadTransfer: Object {
    @Persisted(primaryKey: true) var primaryKey: String
    @Persisted var account: String
    @Persisted var serverUrlBase: String
    @Persisted var fileName: String
    @Persisted var assetLocalIdentifier: String
    @Persisted var date: Date

    convenience init(account: String, serverUrlBase: String, fileName: String, assetLocalIdentifier: String, date: Date) {
        self.init()

        self.primaryKey = account + serverUrlBase + fileName
        self.account = account
        self.serverUrlBase = serverUrlBase
        self.fileName = fileName
        self.assetLocalIdentifier = assetLocalIdentifier
        self.date = date
    }
}

extension NCManageDatabase {

    // MARK: - Realm Write

    func addAutoUploadTransferAsync(account: String,
                                    serverUrlBase: String,
                                    fileName: String,
                                    assetLocalIdentifier: String,
                                    date: Date) async {
        await core.performRealmWriteAsync { realm in
            let result = tableAutoUploadTransfer(account: account,
                                                 serverUrlBase: serverUrlBase,
                                                 fileName: fileName,
                                                 assetLocalIdentifier: assetLocalIdentifier,
                                                 date: date)
            realm.add(result, update: .all)
        }
    }

    func addAutoUploadTransferAsync(_ items: [tableAutoUploadTransfer]) async {
        guard !items.isEmpty else {
            return
        }

        await core.performRealmWriteAsync { realm in
            realm.add(items, update: .all)
        }
    }

    func deleteAutoUploadTransferAsync(account: String,
                                       autoUploadServerUrlBase: String) async {
        await core.performRealmWriteAsync { realm in
            let result = realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
            realm.delete(result)
        }
    }

    // MARK: - Realm Read

    /// Asynchronously fetches a set of filenames that should be skipped for auto-upload,
    /// based on metadata and ongoing transfers for a given account and server URL base.
    ///
    /// - Parameters:
    ///   - account: The account identifier.
    ///   - autoUploadServerUrlBase: The server base URL used for auto-upload.
    /// - Returns: A set of file names that are either in metadata with a relevant status or currently being transferred.
    func fetchSkipFileNamesAsync(account: String,
                                 autoUploadServerUrlBase: String) async -> Set<String> {
        let result: Set<String>? = await core.performRealmReadAsync { realm in
            let metadatas = realm.objects(tableMetadata.self)
                .filter("account == %@ AND autoUploadServerUrlBase == %@ AND status IN %@", account, autoUploadServerUrlBase, NCGlobal.shared.metadataStatusUploadingAllMode)
                .map(\.fileNameView)

            let transfers = realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
                .map(\.fileName)

            return Set(metadatas).union(transfers)
        }

        return result ?? []
    }

    /// Who owns each auto upload file name: for every name already uploaded or still queued,
    /// the photo library identifiers of the assets behind it ("" when unknown).
    /// Lets a new asset be skipped only when it is the same asset, not just the same name.
    func fetchAutoUploadNameOwnersAsync(account: String,
                                        autoUploadServerUrlBase: String) async -> [String: Set<String>] {
        let result: [String: Set<String>]? = await core.performRealmReadAsync { realm in
            var owners: [String: Set<String>] = [:]

            let metadatas = realm.objects(tableMetadata.self)
                .filter("account == %@ AND autoUploadServerUrlBase == %@ AND status IN %@", account, autoUploadServerUrlBase, NCGlobal.shared.metadataStatusUploadingAllMode)
            for metadata in metadatas {
                owners[metadata.fileNameView, default: []].insert(metadata.assetLocalIdentifier)
            }

            let transfers = realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
            for transfer in transfers {
                owners[transfer.fileName, default: []].insert(transfer.assetLocalIdentifier)
            }

            return owners
        }

        return result ?? [:]
    }

    /// Asynchronously fetches the most recent auto-uploaded date for the given account and server base URL.
    /// - Parameters:
    ///   - account: The account identifier.
    ///   - autoUploadServerUrlBase: The server base URL for auto-upload.
    /// - Returns: The most recent upload `Date`, or `nil` if no entry exists.
    func fetchLastAutoUploadedDateAsync(account: String,
                                        autoUploadServerUrlBase: String) async -> Date? {
        await core.performRealmReadAsync { realm in
            realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
                .sorted(byKeyPath: "date", ascending: false)
                .first?.date
        }
    }

    func countAutoUploadMetadatasAsync(account: String,
                                       autoUploadServerUrlBase: String) async -> (pending: Int, failed: Int) {
        let global = NCGlobal.shared
        let pendingStatuses = global.metadatasStatusInWaitingDownloadUpload + global.metadatasStatusDownloadingUploading
        let failedStatuses = [global.metadataStatusUploadError]

        let result = await core.performRealmReadAsync { realm -> (pending: Int, failed: Int) in
            let scope = realm.objects(tableMetadata.self)
                .filter("account == %@ AND autoUploadServerUrlBase == %@ AND directory == false AND sessionSelector == %@",
                        account,
                        autoUploadServerUrlBase,
                        global.selectorUploadAutoUpload)

            let pendingCount = scope.filter("status IN %@", pendingStatuses).count
            let failedCount = scope.filter("status IN %@", failedStatuses).count

            return (pending: pendingCount, failed: failedCount)
        }

        return result ?? (pending: 0, failed: 0)
    }

    /// Everything the auto upload status screen shows, read in one pass: the names already
    /// backed up and the items still in the queue (without folders and Live Photo videos,
    /// which the user sees as part of their photo).
    func getAutoUploadStatusAsync(account: String,
                                  autoUploadServerUrlBase: String) async -> (doneFileNames: [String],
                                                                             pending: [(ocId: String,
                                                                                        fileName: String,
                                                                                        isVideo: Bool,
                                                                                        status: Int,
                                                                                        session: String,
                                                                                        chunk: Int,
                                                                                        errorCode: Int,
                                                                                        sessionDate: Date?)]) {
        let global = NCGlobal.shared
        let result = await core.performRealmReadAsync { realm in
            let done = Array(realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
                .map(\.fileName))

            let pending = realm.objects(tableMetadata.self)
                .filter("account == %@ AND autoUploadServerUrlBase == %@ AND directory == false AND sessionSelector == %@ AND status IN %@",
                        account,
                        autoUploadServerUrlBase,
                        global.selectorUploadAutoUpload,
                        global.metadataStatusUploadingAllMode)
                .sorted(byKeyPath: "sessionDate", ascending: true)
                .filter { !($0.isVideo && !$0.livePhotoFile.isEmpty) }
                .map { (ocId: $0.ocId,
                        fileName: $0.fileNameView,
                        isVideo: $0.isVideo,
                        status: $0.status,
                        session: $0.session,
                        chunk: $0.chunk,
                        errorCode: $0.errorCode,
                        sessionDate: $0.sessionDate) }

            return (doneFileNames: done, pending: Array(pending))
        }

        return result ?? (doneFileNames: [], pending: [])
    }

    func existsAutoUpload(account: String,
                          autoUploadServerUrlBase: String) -> Bool {
        return core.performRealmRead { realm in
            realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
                .first != nil
        } ?? false
    }

    func existsAutoUploadAsync(account: String,
                               autoUploadServerUrlBase: String) async -> Bool {
        return await core.performRealmReadAsync { realm in
            realm.objects(tableAutoUploadTransfer.self)
                .filter("account == %@ AND serverUrlBase == %@", account, autoUploadServerUrlBase)
                .first != nil
        } ?? false
    }
}
