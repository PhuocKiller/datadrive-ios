// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One file still waiting to be backed up, with the reason in plain words.
struct NCAutoUploadStatusItem: Identifiable, Equatable {
    let id: String
    let fileName: String
    let isVideo: Bool
    let reason: String
}
