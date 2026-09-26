// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2025 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RealmSwift
import NextcloudKit
#if !EXTENSION
import UIKit
#endif

// Global flag used to control Realm write/read operations
var isSuspendingDatabaseOperation: Bool = false

final class NCManageDatabaseCore: @unchecked Sendable {
    static let realmQueueKey = DispatchSpecificKey<Void>()

    let realmQueue: DispatchQueue

    init() {
        let queue = DispatchQueue(label: "com.nextcloud.realmQueue", qos: .userInitiated)
        queue.setSpecific(key: NCManageDatabaseCore.realmQueueKey, value: ())
        self.realmQueue = queue
    }

    // MARK: - Write assertion

    // The database lives in the App Group container. If iOS suspends the app while a write
    // transaction holds the file lock, it kills the app with 0xdead10cc (seen in 1.0.1 (8):
    // the Photos listing was being written when the screen went off). Every write therefore
    // holds a background task, so iOS waits for the transaction to finish before suspending.
    #if !EXTENSION
    private let writeAssertionLock = NSLock()
    private var writeAssertionCount = 0
    private var writeAssertionID: UIBackgroundTaskIdentifier = .invalid

    private func beginWriteAssertion() {
        writeAssertionLock.lock()
        defer { writeAssertionLock.unlock() }
        writeAssertionCount += 1
        guard writeAssertionCount == 1 else {
            return
        }
        writeAssertionID = UIApplication.shared.beginBackgroundTask(withName: "RealmWrite") { [weak self] in
            self?.endWriteAssertion(force: true)
        }
    }

    private func endWriteAssertion(force: Bool = false) {
        writeAssertionLock.lock()
        defer { writeAssertionLock.unlock() }
        if force {
            writeAssertionCount = 0
        } else {
            writeAssertionCount = max(0, writeAssertionCount - 1)
        }
        guard writeAssertionCount == 0, writeAssertionID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(writeAssertionID)
        writeAssertionID = .invalid
    }
    #else
    private func beginWriteAssertion() { }
    private func endWriteAssertion(force: Bool = false) { }
    #endif

    //
    // MANUAL MIGRATIONS (custom logic required)
    //
    func migrationSchema(_ migration: Migration, _ oldSchemaVersion: UInt64) {
        if oldSchemaVersion < 390 {
            migration.enumerateObjects(ofType: tableCapabilities.className()) { oldObject, newObject in
                guard let oldObject,
                      let newObject,
                      let oldData = oldObject.value("jsondata", as: Data.self)
                else {
                    return
                }

                newObject.setValueSafely(oldData, for: "capabilities")
            }
        }

        if oldSchemaVersion < 393 {
            migration.enumerateObjects(ofType: tableMetadata.className()) { oldObject, newObject in
                guard let oldObject,
                      let newObject,
                      let oldServerUrlFileName = oldObject.value("serveUrlFileName", as: String.self)
                else {
                    return
                }

                newObject.setValueSafely(oldServerUrlFileName, for: "serverUrlFileName")
            }
        }

        if oldSchemaVersion < 373 {
            // Fix from version 6.2.5
        } else if oldSchemaVersion < 403 {
            migration.enumerateObjects(ofType: tableAccount.className()) { oldObject, newObject in
                guard let oldObject,
                      let newObject
                else {
                    return
                }

                let onlyNew = oldObject.value("autoUploadOnlyNew", as: Bool.self) ?? false

                guard onlyNew else {
                    newObject.setValueSafely(nil, for: "autoUploadSinceDate")
                    return
                }

                let oldSinceDate = oldObject.value("autoUploadOnlyNewSinceDate", as: Date.self)
                newObject.setValueSafely(oldSinceDate, for: "autoUploadSinceDate")
            }
        }

        //
        // AUTOMATIC / DEFENSIVE MIGRATIONS
        //

        if oldSchemaVersion < databaseSchemaVersion {
            migration.enumerateObjects(ofType: tableDirectory.className()) { _, newObject in
                newObject?.setValueSafely("", for: "etag")
            }
        }
    }

    // MARK: - performRealmRead, performRealmWrite

    @discardableResult
    func performRealmRead<T>(_ block: @escaping (Realm) throws -> T?, sync: Bool = true, completion: ((T?) -> Void)? = nil) -> T? {
        // Skip execution if app is suspending
        guard !isSuspendingDatabaseOperation else {
            completion?(nil)
            return nil
        }
        let isOnRealmQueue = DispatchQueue.getSpecific(key: NCManageDatabaseCore.realmQueueKey) != nil

        if sync {
            if isOnRealmQueue {
                // Avoid deadlock if already inside the queue
                do {
                    let realm = try Realm()
                    return try block(realm)
                } catch {
                    nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm read error (sync, reentrant): \(error)")
                    return nil
                }
            } else {
                return realmQueue.sync {
                    do {
                        let realm = try Realm()
                        return try block(realm)
                    } catch {
                        nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm read error (sync): \(error)")
                        return nil
                    }
                }
            }
        } else {
            realmQueue.async(qos: .userInitiated, flags: .enforceQoS) {
                autoreleasepool {
                    do {
                        let realm = try Realm()
                        let result = try block(realm)
                        completion?(result)
                    } catch {
                        nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm read error (async): \(error)")
                        completion?(nil)
                    }
                }
            }
            return nil
        }
    }

    func performRealmWrite(sync: Bool = true, _ block: @escaping (Realm) throws -> Void) {
        // Skip execution if app is suspending
        guard !isSuspendingDatabaseOperation else {
            return
        }
        let isOnRealmQueue = DispatchQueue.getSpecific(key: NCManageDatabaseCore.realmQueueKey) != nil

        beginWriteAssertion()
        let executionBlock: @Sendable () -> Void = {
            defer {
                self.endWriteAssertion()
            }
            autoreleasepool {
                do {
                    let realm = try Realm()
                    try realm.write {
                        try block(realm)
                    }
                } catch {
                    nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm write error: \(error)")
                }
            }
        }

        if sync {
            if isOnRealmQueue {
                // Avoid deadlock
                executionBlock()
            } else {
                realmQueue.sync(execute: executionBlock)
            }
        } else {
            realmQueue.async(qos: .userInitiated, flags: .enforceQoS, execute: executionBlock)
        }
    }

    // MARK: - performRealmRead async/await, performRealmWrite async/await

    func performRealmReadAsync<T>(_ block: @escaping (Realm) throws -> T?) async -> T? {
        // Skip execution if app is suspending
        guard !isSuspendingDatabaseOperation else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            realmQueue.async(qos: .userInitiated, flags: .enforceQoS) {
                autoreleasepool {
                    do {
                        let realm = try Realm()
                        let result = try block(realm)
                        continuation.resume(returning: result)
                    } catch {
                        nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm read async error: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    func performRealmWriteAsync(_ block: @escaping (Realm) throws -> Void) async {
        // Skip execution if app is suspending
        guard !isSuspendingDatabaseOperation else {
            return
        }

        beginWriteAssertion()
        await withCheckedContinuation { continuation in
            realmQueue.async(qos: .userInitiated, flags: .enforceQoS) {
                autoreleasepool {
                    do {
                        let realm = try Realm()
                        try realm.write {
                            try block(realm)
                        }
                    } catch {
                        nkLog(tag: NCGlobal.shared.logTagDatabase, emoji: .error, message: "Realm write async error: \(error)")
                    }
                    self.endWriteAssertion()
                    continuation.resume()
                }
            }
        }
    }
}

class NCKeyValue: Object {
    @Persisted var key: String = ""
    @Persisted var value: String?
}

private extension MigrationObject {
    // Returns true when the dynamic Realm object contains the requested property.
    func hasProperty(_ name: String) -> Bool {
        objectSchema[name] != nil
    }

    // Safely reads a typed property from a dynamic Realm object.
    func value<T>(_ name: String, as type: T.Type = T.self) -> T? {
        guard hasProperty(name) else { return nil }
        return self[name] as? T
    }

    // Safely writes a value only when the destination property exists.
    func setValueSafely(_ value: Any?, for name: String) {
        guard hasProperty(name) else { return }
        self[name] = value
    }
}
