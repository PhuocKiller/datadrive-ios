// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import NextcloudKit
@testable import Nextcloud

@Suite("Auto upload retry and status")
struct NCAutoUploadRetryTests {

    @Test("Temporary server and network errors are retried quietly", arguments: [423, 412, 500, 502, 503, 504, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut])
    func temporaryErrors(code: Int) {
        let error = NKError(errorCode: code, errorDescription: "")
        #expect(NCNetworking.shared.isTemporaryUploadError(error))
    }

    @Test("Real errors are not treated as temporary", arguments: [401, 403, 507])
    func realErrors(code: Int) {
        let error = NKError(errorCode: code, errorDescription: "")
        #expect(!NCNetworking.shared.isTemporaryUploadError(error))
    }

    @Test("A body cut in the middle (400 Expected filesize) is temporary, other 400 are not")
    func badRequest() {
        #expect(NCNetworking.shared.isTemporaryUploadError(NKError(errorCode: 400, errorDescription: "Expected filesize of 100 bytes but read 20")))
        #expect(!NCNetworking.shared.isTemporaryUploadError(NKError(errorCode: 400, errorDescription: "Virus detected")))
    }

    @Test("Retry delays grow, then fall back to the normal 5 minutes")
    func retryDelays() async {
        let coordinator = NCAutoUploadCoordinator()
        var delays: [TimeInterval] = []
        for _ in 0..<(NCAutoUploadCoordinator.retryDelays.count + 1) {
            delays.append(await coordinator.nextRetryDelay(ocId: "a"))
        }
        for (index, base) in NCAutoUploadCoordinator.retryDelays.enumerated() {
            #expect(delays[index] >= base && delays[index] <= base * 1.3)
        }
        #expect(delays.last == NCAutoUploadCoordinator.defaultRetryDelay)

        await coordinator.resetRetry(ocId: "a")
        let first = await coordinator.nextRetryDelay(ocId: "a")
        #expect(first <= NCAutoUploadCoordinator.retryDelays[0] * 1.3)
    }

    @Test("One path at a time per item, per file and per photo library asset")
    func claims() async {
        let coordinator = NCAutoUploadCoordinator()
        #expect(await coordinator.claim(ocId: "1", serverUrlFileName: "/a.jpg", assetLocalIdentifier: "X"))
        #expect(!(await coordinator.claim(ocId: "2", serverUrlFileName: "/b.jpg", assetLocalIdentifier: "X")))
        #expect(!(await coordinator.claim(ocId: "3", serverUrlFileName: "/a.jpg")))
        await coordinator.release(ocId: "1", serverUrlFileName: "/a.jpg", assetLocalIdentifier: "X")
        #expect(await coordinator.claim(ocId: "2", serverUrlFileName: "/b.jpg", assetLocalIdentifier: "X"))
    }

    @Test("Status screen tells photos and videos apart by extension")
    func videoByExtension() {
        #expect(NCAutoUploadStatusModel.isVideo(fileName: "25-04-15 10-02-18 0004.mov"))
        #expect(NCAutoUploadStatusModel.isVideo(fileName: "03.mp4"))
        #expect(!NCAutoUploadStatusModel.isVideo(fileName: "IMG_0001.jpg"))
        #expect(!NCAutoUploadStatusModel.isVideo(fileName: "IMG_0001.HEIC"))
    }
}
