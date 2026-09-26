// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The files still waiting to be backed up, each with its reason, and a "Retry now" button.
struct NCAutoUploadPendingView: View {
    @ObservedObject var model: NCAutoUploadStatusModel
    @State private var isRetrying = false

    var body: some View {
        List {
            Section {
                Button {
                    isRetrying = true
                    Task {
                        await model.retryNow()
                        isRetrying = false
                    }
                } label: {
                    HStack {
                        Label(NSLocalizedString("_autoupload_status_retry_now_", value: "Retry now", comment: ""),
                              systemImage: "arrow.clockwise")
                        if isRetrying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRetrying)
            }

            Section {
                ForEach(model.pendingItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isVideo ? "video" : "photo")
                            .frame(width: 26)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(format: NSLocalizedString("_autoupload_status_pending_", value: "Waiting (%@)", comment: ""),
                                NCAutoUploadStatusModel.formatted(model.pendingItems.count)))
        .navigationBarTitleDisplayMode(.inline)
    }
}
