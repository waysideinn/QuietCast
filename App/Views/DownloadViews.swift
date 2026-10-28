import SwiftUI
import PodcastCore

@MainActor
struct DownloadBadge: View {
    @ObservedObject var manager: DownloadManager
    let id: String
    var body: some View {
        if let record = manager.records[id] {
            Image(systemName: DownloadAppearance.icon(record.status)).accessibilityLabel(DownloadAppearance.title(record.status))
        }
    }
}

enum DownloadAppearance {
    static func title(_ status: DownloadRecord.Status) -> String {
        switch status { case .downloading: return "下载中"; case .paused: return "已暂停"; case .failed: return "重试下载"; case .downloaded: return "已下载" }
    }
    static func icon(_ status: DownloadRecord.Status) -> String {
        switch status { case .downloading: return "pause.circle"; case .paused: return "arrow.down.circle"; case .failed: return "arrow.clockwise.circle"; case .downloaded: return "checkmark.circle.fill" }
    }
}

@MainActor
struct DownloadControl: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: DownloadManager
    let episode: Episode
    var body: some View {
        Group {
            if manager.records[episode.id]?.status == .downloaded {
                Menu { DownloadMenuActions(manager: manager, episode: episode) } label: { PlayerActionLabel(icon: "checkmark.circle.fill", title: "已下载") }
            } else {
                Button {
                    if manager.records[episode.id]?.status == .downloading { manager.pause(episode.id) }
                    else { store.download(episode) }
                } label: { PlayerActionLabel(icon: manager.records[episode.id].map { DownloadAppearance.icon($0.status) } ?? "arrow.down.circle", title: manager.records[episode.id].map { DownloadAppearance.title($0.status) } ?? "下载") }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("player.download").captureLayout("player.download")
            .accessibilityLabel(manager.records[episode.id]?.status == .downloading ? "暂停下载" : manager.records[episode.id].map { DownloadAppearance.title($0.status) } ?? "下载单集")
    }
}

@MainActor
struct DownloadMenuActions: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: DownloadManager
    let episode: Episode
    var body: some View {
        if let record = manager.records[episode.id] {
            switch record.status {
            case .downloading:
                Button { manager.pause(episode.id) } label: { Label("暂停下载", systemImage: "pause.circle") }
            case .paused, .failed:
                Button { store.download(episode) } label: { Label(record.status == .failed ? "重试下载" : "继续下载", systemImage: "arrow.down.circle") }
            case .downloaded: EmptyView()
            }
            Button(role: .destructive) { manager.delete(episode.id) } label: { Label(record.status == .downloaded ? "删除下载" : "取消下载", systemImage: "trash") }
        } else {
            Button { store.download(episode) } label: { Label("下载", systemImage: "arrow.down.circle") }
        }
    }
}

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: DownloadManager
    private var visibleRecords: [DownloadRecord] { manager.orderedIDs.compactMap { manager.records[$0] }.filter { store.presentation.visibleEpisodeIDs.contains($0.id) } }
    private var completed: [DownloadRecord] { visibleRecords.filter { $0.status == .downloaded && manager.availableDownloadIDs.contains($0.id) } }
    private var transfers: [DownloadRecord] { visibleRecords.filter { $0.status != .downloaded } }
    var body: some View {
        List {
            Section { Text("已使用 \(ByteCountFormatter.string(fromByteCount: manager.diskUsage, countStyle: .file)) / \(store.library.preferences.downloadLimitGB) GB").font(.footnote).foregroundStyle(.secondary) }
            Section("已下载") {
                if !completed.isEmpty {
                    Text("这些是已经下载到本地的节目，无需网络即可收听").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(completed) { record in EpisodeRow(episode: record.episode, entry: .download) }
                } else if store.preparingPresentation { ProgressView("正在整理下载…") }
                else { EmptyViewMessage(icon: "arrow.down.circle", title: "还没有已完成的下载", detail: "下载完成后会显示在这里。") }
            }
            if !transfers.isEmpty {
                Section("下载任务") {
                    ForEach(transfers) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            EpisodeRow(episode: record.episode, entry: .download)
                            if record.status == .downloading {
                                if record.expected > 0 { ProgressView(value: record.progress).accessibilityLabel("已下载\(Int(record.progress * 100))%") }
                                else { ProgressView("已接收 \(ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file))") }
                            }
                            HStack {
                                Text(DownloadAppearance.title(record.status)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if record.status == .downloading { Button("暂停") { manager.pause(record.id) }.frame(minHeight: 44) }
                                else { Button(record.status == .failed ? "重试" : "继续") { store.download(record.episode) }.frame(minHeight: 44) }
                            }
                            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
            if !completed.isEmpty {
                Section { Button("清理已播放完的下载", role: .destructive) { manager.cleanup(completedIDs: Set(store.library.progress.filter { $0.value.completed }.keys), currentID: store.player.episode?.id) }.frame(minHeight: 44) }
            }
        }.navigationTitle("下载").navigationBarTitleDisplayMode(.inline)
            .task { await manager.validateLocalFiles() }
            .refreshable { await manager.validateLocalFiles() }
    }
}
