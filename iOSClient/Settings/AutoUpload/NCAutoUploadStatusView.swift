// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Phuoc Tran
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Summary shown at the top of the auto upload screen: overall progress, photos and videos
/// counted separately, and a link to what is still waiting. No technical wording, no alerts.
struct NCAutoUploadStatusView: View {
    @ObservedObject var model: NCAutoUploadStatusModel
    let tint: Color

    var body: some View {
        Section(content: {
            if model.isAllDone {
                VStack(alignment: .leading, spacing: 4) {
                    Label(NSLocalizedString("_autoupload_status_all_done_", value: "All photos and videos are backed up", comment: ""),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(model.progressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.progressText)
                        .font(.body)
                    ProgressView(value: model.progress)
                        .tint(tint)
                    Text(model.stateText)
                        .font(.footnote)
                        .foregroundStyle(model.autoUploadStart ? Color.secondary : Color.orange)
                }
                .padding(.vertical, 4)
            }

            countRow(systemImage: "photo",
                     title: NSLocalizedString("_autoupload_status_photos_", value: "Photos", comment: ""),
                     enabled: model.photosEnabled,
                     done: model.donePhotos,
                     total: model.totalPhotos)

            countRow(systemImage: "video",
                     title: NSLocalizedString("_autoupload_status_videos_", value: "Videos", comment: ""),
                     enabled: model.videosEnabled,
                     done: model.doneVideos,
                     total: model.totalVideos)

            if !model.pendingItems.isEmpty {
                NavigationLink {
                    NCAutoUploadPendingView(model: model)
                } label: {
                    Text(String(format: NSLocalizedString("_autoupload_status_pending_", value: "Waiting (%@)", comment: ""),
                                NCAutoUploadStatusModel.formatted(model.pendingItems.count)))
                        .font(.body)
                }
            }
        }, header: {
            Text(NSLocalizedString("_autoupload_status_title_", value: "Backup status", comment: ""))
        })
    }

    private func countRow(systemImage: String, title: String, enabled: Bool, done: Int, total: Int) -> some View {
        HStack {
            Image(systemName: systemImage)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            if enabled {
                Text(NCAutoUploadStatusModel.formatted(done) + " / " + NCAutoUploadStatusModel.formatted(total))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if total > 0, done >= total {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            } else {
                Text(NSLocalizedString("_autoupload_status_off_", value: "Not backed up", comment: ""))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }
}
