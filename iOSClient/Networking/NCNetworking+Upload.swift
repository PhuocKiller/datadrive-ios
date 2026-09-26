// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2024 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit
import Alamofire

extension NCNetworking {

    // MARK: - Upload file in foreground

    @discardableResult
    func uploadFile(account: String,
                    fileNameLocalPath: String,
                    serverUrlFileName: String,
                    creationDate: Date? = nil,
                    dateModificationFile: Date? = nil,
                    customHeaders: [String: String]? = nil,
                    requestHandler: @escaping (_ request: UploadRequest) -> Void = { _ in },
                    taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in },
                    progressHandler: @escaping (_ totalBytesExpected: Int64, _ totalBytes: Int64, _ fractionCompleted: Double) -> Void = { _, _, _ in })
    async -> (account: String,
              ocId: String?,
              etag: String?,
              date: Date?,
              ownerId: String?,
              permissions: String?,
              error: NKError) {
        let options = NKRequestOptions(customHeader: customHeaders, queue: nkComm.backgroundQueue)
        let results = await NextcloudKit.shared.uploadAsync(serverUrlFileName: serverUrlFileName,
                                                            fileNameLocalPath: fileNameLocalPath,
                                                            dateCreationFile: creationDate,
                                                            dateModificationFile: dateModificationFile,
                                                            autoMkcol: true,
                                                            account: account,
                                                            options: options) { request in
            requestHandler(request)
        } taskHandler: { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: account,
                                                                                            path: serverUrlFileName,
                                                                                            name: "upload")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
            taskHandler(task)
        } progressHandler: { progress in
            progressHandler(progress.completedUnitCount, progress.totalUnitCount, progress.fractionCompleted)
        }

        let allHeaderFields = results.response?.response?.allHeaderFields

        let ocId = nkComm.findHeader("oc-fileid", allHeaderFields: allHeaderFields)
        let etag = nkComm.normalizedETag(nkComm.findHeader("oc-etag", allHeaderFields: allHeaderFields))
        let date = nkComm.findHeader("date", allHeaderFields: allHeaderFields)?.parsedDate(using: "EEE, dd MMM y HH:mm:ss zzz")
        let ownerId = nkComm.findHeader("x-nc-ownerid", allHeaderFields: allHeaderFields)
        let permissions = nkComm.findHeader("x-nc-permissions", allHeaderFields: allHeaderFields)

        return (results.account,
                ocId,
                etag,
                date,
                ownerId,
                permissions,
                results.error)
    }

    // MARK: - Upload chunk file in foreground

    @discardableResult
    func uploadChunkFile(metadata: tableMetadata,
                         performPostProcessing: Bool = true,
                         customHeaders: [String: String]? = nil,
                         chunkProgressHandler: @escaping (_ total: Int, _ counter: Int) -> Void = { _, _ in },
                         uploadStart: @escaping (_ filesChunk: [(fileName: String, size: Int64)]) -> Void = { _ in },
                         uploadProgressHandler: @escaping (_ totalBytesExpected: Int64, _ totalBytes: Int64, _ fractionCompleted: Double) -> Void = { _, _, _ in },
                         assembling: @escaping () -> Void = { }) async -> (account: String,
                                                                           file: NKFile?,
                                                                           error: NKError) {
        let directory = utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                          userId: metadata.userId,
                                                                          urlBase: metadata.urlBase)
        let chunkFolder = NCManageDatabase.shared.getChunkFolder(account: metadata.account, ocId: metadata.ocId)
        let filesChunk = NCManageDatabase.shared.getChunks(account: metadata.account, ocId: metadata.ocId)
        let chunkSize = self.global.chunkPieceSize
        let options = NKRequestOptions(customHeader: customHeaders, queue: nkComm.backgroundQueue)
        var backupError = NKError()
        var backupFile: NKFile?

        do {
            let (_, file) = try await NextcloudKit.shared.uploadChunkAsync(
                directory: directory,
                fileName: metadata.fileName,
                date: metadata.date as Date,
                creationDate: metadata.creationDate as Date,
                serverUrl: metadata.serverUrl,
                chunkFolder: chunkFolder,
                filesChunk: filesChunk,
                chunkSize: chunkSize,
                account: metadata.account,
                options: options) { total, counter in
                    chunkProgressHandler(total, counter)
                } uploadStart: { filesChunk in
                    Task {
                        await NCManageDatabase.shared.addChunksAsync(account: metadata.account,
                                                                     ocId: metadata.ocId,
                                                                     chunkFolder: chunkFolder,
                                                                     filesChunk: filesChunk)
                        await self.transferDispatcher.notifyAllDelegates { delegate in
                            delegate.transferChange(networkingStatus: self.global.networkingStatusUploading,
                                                    account: metadata.account,
                                                    fileName: metadata.fileName,
                                                    serverUrl: metadata.serverUrl,
                                                    selector: metadata.sessionSelector,
                                                    ocId: metadata.ocId,
                                                    destination: nil,
                                                    error: .success)
                        }
                    }
                    uploadStart(filesChunk)
                } uploadTaskHandler: { task in
                    Task {
                        let url = task.originalRequest?.url?.absoluteString ?? ""
                        let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                                    path: url,
                                                                                                    name: "upload")
                        await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                              sessionTaskIdentifier: task.taskIdentifier,
                                                                              status: self.global.metadataStatusUploading)
                    }
                } uploadProgressHandler: { totalBytesExpected, totalBytes, fractionCompleted in
                    Task {
                        guard await self.progressQuantizer.shouldEmit(serverUrlFileName: metadata.serverUrlFileName, fraction: fractionCompleted) else {
                            return
                        }
                        await self.transferDispatcher.notifyAllDelegates { delegate in
                            delegate.transferProgressDidUpdate(progress: Float(fractionCompleted),
                                                               totalBytes: totalBytes,
                                                               totalBytesExpected: totalBytesExpected,
                                                               fileName: metadata.fileName,
                                                               serverUrl: metadata.serverUrl)
                        }
                    }
                    uploadProgressHandler(totalBytesExpected, totalBytes, fractionCompleted)
                } uploaded: { fileChunk in
                    Task {
                        await NCManageDatabase.shared.deleteChunkAsync(account: metadata.account,
                                                                       ocId: metadata.ocId,
                                                                       fileChunk: fileChunk,
                                                                       directory: directory)
                    }
                } assembling: {
                    assembling()
                }

            await NCManageDatabase.shared.deleteChunksAsync(account: metadata.account,
                                                            ocId: metadata.ocId,
                                                            directory: directory)

            if performPostProcessing, let file {
                await uploadSuccess(withMetadata: metadata,
                                    ocId: file.ocId,
                                    etag: file.etag,
                                    date: file.date,
                                    ownerId: file.ownerId,
                                    permissions: file.permissions)
            }

            backupFile = file
        } catch is CancellationError {
            backupError = NKError(errorCode: -5, errorDescription: "Transfers was cancelled.")
            await handleChunkCancel(metadata: metadata, directory: directory)
        } catch let error as NKError {
            backupError = error
            if error.errorCode == -5 {
                await handleChunkCancel(metadata: metadata, directory: directory)
            } else {
                if performPostProcessing {
                    await uploadError(withMetadata: metadata, error: error)
                }
            }
        } catch let error {
            backupError = NKError(error: error)
            if performPostProcessing {
                await uploadError(withMetadata: metadata, error: backupError)
            }
        }

        return(metadata.account, backupFile, backupError)
    }

    /// An auto upload cancelled because the app went to the background goes back to the queue
    /// and keeps the chunks already sent, so it resumes where it stopped. Any other cancel
    /// (the user tapped cancel) drops the upload as before.
    private func handleChunkCancel(metadata: tableMetadata, directory: String) async {
        #if !EXTENSION
        if metadata.sessionSelector == global.selectorUploadAutoUpload, isAppInBackground {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: "",
                                                                  status: global.metadataStatusWaitUpload)
            return
        }
        #endif
        await uploadCancelFile(metadata: metadata, directoryChunks: directory)
    }

    // MARK: - Upload file in background

    @discardableResult
    func uploadFileInBackground(
        metadata: tableMetadata,
        taskHandler: @escaping (_ task: URLSessionUploadTask?) -> Void = { _ in },
        start: @escaping () -> Void = { }
    ) async -> NKError {
        let directoryLocalPath = utilityFileSystem.getDirectoryProviderStorageOcId(
            metadata.ocId,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )
        let fileNameLocalPath = URL(fileURLWithPath: directoryLocalPath, isDirectory: true)
            .appendingPathComponent(metadata.fileName)
            .path
        let localFileSize = utilityFileSystem.getFileSize(filePath: fileNameLocalPath)

        if localFileSize == 0 && metadata.size != 0 {
            nkLog(
                debug: "Background upload local file: " +
                       "path=\(fileNameLocalPath), " +
                       "size=\(localFileSize), " +
                       "metadataSize=\(metadata.size)"
            )

            if metadata.sessionSelector == global.selectorUploadAutoUpload,
               !metadata.assetLocalIdentifier.isEmpty {
                // Auto upload: the photo is still in the library, export it again next time
                // instead of dropping it from the queue.
                nkLog(error: "Local file missing, exporting again: \(metadata.fileNameView), ocId: \(metadata.ocId)")
                let retry = metadata.detachedCopy()
                retry.isExtractFile = false
                retry.chunk = 0
                retry.status = global.metadataStatusWaitUpload
                retry.sessionTaskIdentifier = 0
                retry.sessionDate = Date()
                await NCManageDatabase.shared.addMetadataAsync(retry)
                return NKError(errorCode: global.errorResourceNotFound, errorDescription: "Local file missing")
            }

            nkLog(
                error: "Deleting upload metadata because local file is empty or missing: " +
                       "\(metadata.fileNameView), ocId: \(metadata.ocId)"
            )

            await NCManageDatabase.shared.deleteMetadataAsync(id: metadata.ocId)

            return NKError(
                errorCode: global.errorResourceNotFound,
                errorDescription: NSLocalizedString(
                    "_error_not_found_",
                    value: "The requested resource could not be found",
                    comment: ""
                )
            )
        }

        start()

        let (task, error) = await backgroundSession.uploadAsync(
            serverUrlFileName: metadata.serverUrlFileName,
            fileNameLocalPath: fileNameLocalPath,
            dateCreationFile: metadata.creationDate as Date,
            dateModificationFile: metadata.date as Date,
            autoMkcol: true,
            account: metadata.account,
            sessionIdentifier: metadata.session
        )

        taskHandler(task)

        guard let task, error == .success else {
            task?.cancel()

            nkLog(
                error: "Background upload task creation failed: " +
                       "\(metadata.fileNameView), " +
                       "task: \(String(describing: task?.taskIdentifier)), " +
                       "error: \(error.errorCode) \(error.errorDescription)"
            )

            await NCManageDatabase.shared.setMetadataSessionAsync(
                ocId: metadata.ocId,
                sessionTaskIdentifier: 0,
                sessionError: error.errorDescription,
                status: global.metadataStatusUploadError,
                errorCode: error.errorCode
            )

            return error
        }

        nkLog(debug: "Uploading file \(metadata.fileNameView) " + "with taskIdentifier \(task.taskIdentifier)")

        await NCManageDatabase.shared.setMetadataSessionAsync(
            ocId: metadata.ocId,
            sessionTaskIdentifier: task.taskIdentifier,
            status: global.metadataStatusUploading
        )

        await self.transferDispatcher.notifyAllDelegates { delegate in
            delegate.transferChange(networkingStatus: self.global.networkingStatusUploading,
                                    account: metadata.account,
                                    fileName: metadata.fileName,
                                    serverUrl: metadata.serverUrl,
                                    selector: metadata.sessionSelector,
                                    ocId: metadata.ocId,
                                    destination: nil,
                                    error: .success)
        }

        return error
    }

    // MARK: - UPLOAD SUCCESS

    func uploadSuccess(withMetadata metadata: tableMetadata,
                       ocId: String,
                       etag: String?,
                       date: Date?,
                       ownerId: String? = nil,
                       permissions: String? = nil) async {
        nkLog(success: "Uploaded file: " + metadata.serverUrlFileName)

        #if !EXTENSION
        await NCAutoUploadCoordinator.shared.resetRetry(ocId: metadata.ocIdTransfer)
        await NCAutoUploadCoordinator.shared.markFolderReady(metadata.serverUrl)
        #endif

        metadata.uploadDate = (date as? NSDate) ?? NSDate()
        metadata.etag = etag ?? ""
        metadata.ocId = ocId
        metadata.chunk = 0

        if let fileId = NCUtility().ocIdToFileId(ocId: ocId) {
            metadata.fileId = fileId
        }

        if let ownerId = ownerId.isNotEmpty {
            metadata.ownerId = ownerId
            if let ownerDisplayName = await NCManageDatabase.shared.getOwnerDisplayName(account: metadata.account, ownerId: ownerId) {
                metadata.ownerDisplayName = ownerDisplayName
            }
        }

        if let permissions = permissions.isNotEmpty {
            metadata.permissions = permissions
        }

        metadata.session = ""
        metadata.sessionError = ""
        metadata.sessionTaskIdentifier = 0
        metadata.status = self.global.metadataStatusNormal

        let results = await helperMetadataSuccess(metadata: metadata)

        await NCManageDatabase.shared.replaceMetadataAsync(ocId: metadata.ocIdTransfer, metadata: metadata)
        if let localFile = results.localFile {
            await NCManageDatabase.shared.addLocalFilesAsync(metadatas: [localFile])
        }
        if let tblAutoUpload = results.autoUpload {
            await NCManageDatabase.shared.addAutoUploadTransferAsync([tblAutoUpload])
        }
        if let livePhoto = results.livePhoto {
            await NCManageDatabase.shared.setLivePhotoVideo(account: livePhoto.account,
                                                            serverUrlFileName: livePhoto.serverUrlFileName,
                                                            fileId: livePhoto.fileId,
                                                            classFile: livePhoto.classFile)
#if !EXTENSION
            await NCNetworking.shared.setLivePhoto(account: metadata.account)
#endif
        }

        await self.transferDispatcher.notifyAllDelegates { delegate in
            delegate.transferChange(networkingStatus: self.global.networkingStatusUploaded,
                                    account: metadata.account,
                                    fileName: metadata.fileName,
                                    serverUrl: metadata.serverUrl,
                                    selector: metadata.sessionSelector,
                                    ocId: metadata.ocId,
                                    destination: nil,
                                    error: .success)
        }
    }

    // MARK: - UPLOAD ERROR

    func uploadError(withMetadata metadata: tableMetadata, error: NKError) async {
        nkLog(error: "Upload file: " + metadata.serverUrlFileName + ", result: error \(error.errorCode)")

        // Temporary failures are retried quietly with a growing delay. They must not mark the
        // whole account as "server in error" either (a single 503 used to stop every upload).
        if isTemporaryUploadError(error) {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: error.errorDescription,
                                                                  status: self.global.metadataStatusUploadError,
                                                                  errorCode: error.errorCode)
            #if !EXTENSION
            let delay = await NCAutoUploadCoordinator.shared.nextRetryDelay(ocId: metadata.ocId)
            let retryDate = Date().addingTimeInterval(delay - NCAutoUploadCoordinator.defaultRetryDelay)
            await NCManageDatabase.shared.setMetadataRetryDateAsync(ocId: metadata.ocId, date: retryDate)
            #endif
            return
        }

        // Storage full: a real error, but one quiet message instead of one banner per file.
        if error.errorCode == global.errorQuota {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: error.errorDescription,
                                                                  status: self.global.metadataStatusUploadError,
                                                                  errorCode: error.errorCode)
            #if !EXTENSION
            if await NCAutoUploadCoordinator.shared.shouldShowQuotaWarning(), !isAppInBackground {
                let windowScene = await SceneManager.shared.getWindow(sceneIdentifier: metadata.sceneIdentifier)?.windowScene
                await showErrorBanner(windowScene: windowScene,
                                      text: NSLocalizedString("_upload_quota_full_",
                                                              value: "Your storage is full, so uploads are paused. Free up space or upgrade your plan.",
                                                              comment: ""),
                                      errorCode: error.errorCode)
            }
            #endif
            return
        }

        await nkComm.appendServerErrorAccount(metadata.account, errorCode: error.errorCode)

        if error.errorCode == NSURLErrorCancelled {
            if metadata.sessionSelector == self.global.selectorUploadAutoUpload {
                await NCManageDatabase.shared.setMetadataSessionAsync(
                    ocId: metadata.ocId,
                    sessionTaskIdentifier: 0,
                    sessionError: error.errorDescription,
                    status: self.global.metadataStatusUploadError,
                    errorCode: error.errorCode
                )
            } else {
                await uploadCancelFile(metadata: metadata)
            }
        } else if (error.errorCode == self.global.errorBadRequest || error.errorCode == self.global.errorUnsupportedMediaType) && error.errorDescription.localizedCaseInsensitiveContains("virus") {
            await uploadCancelFile(metadata: metadata)
            #if !EXTENSION
            let windowScene = await SceneManager.shared.getWindow(sceneIdentifier: metadata.sceneIdentifier)?.windowScene
            await showErrorBanner(windowScene: windowScene, text: "_virus_detect_", errorCode: self.global.errorBadRequest)
            #endif
            // Client Diagnostic
            await NCManageDatabase.shared.addDiagnosticAsync(account: metadata.account, issue: self.global.diagnosticIssueVirusDetected)
        } else if error.errorCode == self.global.errorForbidden {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: error.errorDescription,
                                                                  status: self.global.metadataStatusUploadError,
                                                                  errorCode: error.errorCode)
#if !EXTENSION
            let capabilities = await NKCapabilities.shared.getCapabilities(for: metadata.account)
            if !isAppInBackground, metadata.sessionSelector != self.global.selectorUploadAutoUpload {
                if capabilities.termsOfService {
                    await termsOfService(metadata: metadata)
                } else {
                    await uploadForbidden(metadata: metadata, error: error)
                }
            }
#endif
        } else {
           await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                 sessionTaskIdentifier: 0,
                                                                 sessionError: error.errorDescription,
                                                                 status: self.global.metadataStatusUploadError,
                                                                 errorCode: error.errorCode)

            await self.transferDispatcher.notifyAllDelegates { delegate in
                delegate.transferChange(networkingStatus: self.global.networkingStatusUploaded,
                                        account: metadata.account,
                                        fileName: metadata.fileName,
                                        serverUrl: metadata.serverUrl,
                                        selector: metadata.sessionSelector,
                                        ocId: metadata.ocId,
                                        destination: nil,
                                        error: error)
            }

            // Client Diagnostic
            if error.errorCode == self.global.errorInternalServerError {
                await NCManageDatabase.shared.addDiagnosticAsync(account: metadata.account,
                                                                 issue: self.global.diagnosticIssueProblems,
                                                                 error: self.global.diagnosticProblemsBadResponse)
            } else {
                await NCManageDatabase.shared.addDiagnosticAsync(account: metadata.account,
                                                                 issue: self.global.diagnosticIssueProblems,
                                                                 error: self.global.diagnosticProblemsUploadServerError)
            }
        }
    }

    /// Puts an item back in the queue after a failed check before its upload (PROPFIND),
    /// without any alert: temporary errors get the quick backoff, others the normal 5 minutes.
    func uploadRetryLater(metadata: tableMetadata, error: NKError) async {
        if isTemporaryUploadError(error) {
            await uploadError(withMetadata: metadata, error: error)
        } else {
            await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                  sessionTaskIdentifier: 0,
                                                                  sessionError: error.errorDescription,
                                                                  status: global.metadataStatusUploadError,
                                                                  errorCode: error.errorCode)
        }
    }

    /// Errors that go away by themselves: file locked for a moment, server busy or restarting,
    /// the connection dropped or the app was suspended in the middle of the body, a stale cookie.
    func isTemporaryUploadError(_ error: NKError) -> Bool {
        switch error.errorCode {
        case 423, 412, 404, 408, 425, 429, 500, 502, 503, 504:
            return true
        case 400:
            // "Expected filesize X but read Y": the body was cut when iOS suspended the app.
            return error.errorDescription.localizedCaseInsensitiveContains("filesize") ||
                error.errorDescription.localizedCaseInsensitiveContains("file size")
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorBackgroundSessionWasDisconnected,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: -

    func uploadCancelFile(metadata: tableMetadata, directoryChunks: String? = nil) async {
        if let directoryChunks {
            await NCManageDatabase.shared.deleteChunksAsync(account: metadata.account,
                                                            ocId: metadata.ocId,
                                                            directory: directoryChunks)
        }
        self.utilityFileSystem.removeFile(
            atPath: self.utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocIdTransfer, userId: metadata.userId, urlBase: metadata.urlBase)
        )
        await NCManageDatabase.shared.deleteMetadataAsync(id: metadata.ocIdTransfer)
    }

#if !EXTENSION
    @MainActor
    func uploadForbidden(metadata: tableMetadata, error: NKError) async {
        let newFileName = self.utilityFileSystem.createFileName(metadata.fileName, serverUrl: metadata.serverUrl, account: metadata.account)
        let alertController = UIAlertController(title: error.errorDescription, message: NSLocalizedString("_change_upload_filename_", comment: ""), preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: String(format: NSLocalizedString("_save_file_as_", comment: ""), newFileName), style: .default, handler: { _ in
            Task {
                let atpath = self.utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                    userId: metadata.userId,
                                                                                    urlBase: metadata.urlBase) + "/" + metadata.fileName
                let toPath = self.utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                    userId: metadata.userId,
                                                                                    urlBase: metadata.urlBase) + "/" + newFileName
                await self.utilityFileSystem.moveFileAsync(atPath: atpath, toPath: toPath)
                await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                      newFileName: newFileName,
                                                                      sessionTaskIdentifier: 0,
                                                                      sessionError: "",
                                                                      status: self.global.metadataStatusWaitUpload,
                                                                      errorCode: error.errorCode)
            }
        }))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("_discard_changes_", comment: ""), style: .destructive, handler: { _ in
            Task {
                await self.uploadCancelFile(metadata: metadata)
            }
        }))

        self.getViewController(metadata: metadata)?.present(alertController, animated: true)

        // Client Diagnostic
        await NCManageDatabase.shared.addDiagnosticAsync(account: metadata.account,
                                                         issue: self.global.diagnosticIssueProblems,
                                                         error: self.global.diagnosticProblemsForbidden)
    }

    @MainActor
    func termsOfService(metadata: tableMetadata) async {
        let options = NKRequestOptions(checkInterceptor: false, queue: .main)
        let results = await NextcloudKit.shared.getTermsOfServiceAsync(account: metadata.account, options: options, taskHandler: { task in
            Task {
                let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                            name: "getTermsOfService")
                await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
            }
        })

        if results.error == .success, let tos = results.tos, !tos.hasUserSigned() {
            await self.uploadCancelFile(metadata: metadata)
            return
        }

        let newFileName = self.utilityFileSystem.createFileName(metadata.fileName, serverUrl: metadata.serverUrl, account: metadata.account)

        let alertController = UIAlertController(title: results.error.errorDescription, message: NSLocalizedString("_change_upload_filename_", comment: ""), preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: String(format: NSLocalizedString("_save_file_as_", comment: ""), newFileName), style: .default, handler: { _ in
            Task {
                let atpath = self.utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                    userId: metadata.userId,
                                                                                    urlBase: metadata.urlBase) + "/" + metadata.fileName
                let toPath = self.utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                    userId: metadata.userId,
                                                                                    urlBase: metadata.urlBase) + "/" + newFileName
                await self.utilityFileSystem.moveFileAsync(atPath: atpath, toPath: toPath)
                await NCManageDatabase.shared.setMetadataSessionAsync(ocId: metadata.ocId,
                                                                      newFileName: newFileName,
                                                                      sessionTaskIdentifier: 0,
                                                                      sessionError: "",
                                                                      status: self.global.metadataStatusWaitUpload,
                                                                      errorCode: results.error.errorCode)
            }
        }))

        alertController.addAction(UIAlertAction(title: NSLocalizedString("_discard_changes_", comment: ""), style: .destructive, handler: { _ in
            Task {
                await self.uploadCancelFile(metadata: metadata)
            }
        }))

        self.getViewController(metadata: metadata)?.present(alertController, animated: true)

        // Client Diagnostic
        await NCManageDatabase.shared.addDiagnosticAsync(account: metadata.account,
                                                         issue: self.global.diagnosticIssueProblems,
                                                         error: self.global.diagnosticProblemsForbidden)
    }

    private func getViewController(metadata: tableMetadata) -> UIViewController? {
        var controller = UIApplication.shared.mainAppWindow?.rootViewController
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for windowScene in windowScenes {
            if let rootViewController = windowScene.keyWindow?.rootViewController as? NCMainTabBarController,
               rootViewController.currentServerUrl() == metadata.serverUrl {
                controller = rootViewController
                break
            }
        }
        return controller
    }
#endif

    // MARK: - Helper

    func helperMetadataSuccess(metadata: tableMetadata) async -> (localFile: tableMetadata?,
                                                                  livePhoto: tableMetadata?,
                                                                  autoUpload: tableAutoUploadTransfer?) {
        let localFile: tableMetadata? = nil
        var livePhoto: tableMetadata?
        var autoUpload: tableAutoUploadTransfer?

        // File System Local file
        let fileNamePath = utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocIdTransfer,
                                                                             userId: metadata.userId,
                                                                             urlBase: metadata.urlBase)
        utilityFileSystem.removeFile(atPath: fileNamePath)

        // Live Photo
        let capabilities = await NKCapabilities.shared.getCapabilities(for: metadata.account)
        if capabilities.isLivePhotoServerAvailable,
           metadata.isLivePhoto {
            livePhoto = tableMetadata(value: metadata)
        }

        // Auto Upload
        if metadata.sessionSelector == self.global.selectorUploadAutoUpload,
           let serverUrlBase = metadata.autoUploadServerUrlBase {
            autoUpload = tableAutoUploadTransfer(account: metadata.account,
                                                 serverUrlBase: serverUrlBase,
                                                 fileName: metadata.fileNameView,
                                                 assetLocalIdentifier: metadata.assetLocalIdentifier,
                                                 date: metadata.creationDate as Date)
        }

        return (localFile: localFile, livePhoto: livePhoto, autoUpload: autoUpload)
    }
}
