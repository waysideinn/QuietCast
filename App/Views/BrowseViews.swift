import PodcastCore
import SwiftUI

@MainActor
struct RSSImportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/feed.xml", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).onSubmit { subscribe() }
                Text("粘贴公开 RSS 或 Apple Podcasts 节目链接。加载并校验内容后才会订阅。").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button { subscribe() } label: { if busy { ProgressView() } else { Text("验证并订阅") } }.disabled(busy || address.isEmpty)
            }.navigationTitle("添加节目").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func subscribe() {
        Keyboard.dismiss()
        guard !busy, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task { do { _ = try await store.addRSS(address); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
    }

}
@MainActor
struct ShowDetailView: View {
    @EnvironmentObject private var store: AppStore
    let show: Podcast
    @State private var loading = false
    @State private var error: String?
    @State private var parentActions = false
    @State private var episodeLimit = 100
    private var listedEpisodes: [Episode] { store.presentation.episodesByShow[show.id] ?? [] }
    private var actual: Podcast { store.library.podcasts[show.id] ?? show }
    private var verdict: FilterResult { store.result(show: actual) }
    var body: some View {
        List {
            if verdict.decision == .block {
                Section { EmptyViewMessage(icon: "lock.shield", title: "内容已受家长规则限制", detail: "播放、下载和订阅前都会重新验证权限。"); Button("申请家长解锁") { store.unlockRequest = UnlockRequest(show: actual, episode: nil, result: verdict) } }
            } else {
                Section {
                    HStack(alignment: .top, spacing: 16) { Artwork(url: actual.artworkURL, size: 100); VStack(alignment: .leading, spacing: 8) { Text(actual.title).font(.title2.bold()); Text(actual.author).foregroundStyle(.secondary) } }
                    DisclosureGroup("节目简介") { Text(actual.summary.isEmpty ? "加载 RSS 后显示简介" : actual.summary).font(.subheadline) }
                    if !actual.categories.isEmpty { Text(actual.categories.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    if let url = actual.directoryURL { Link("在 Apple Podcasts 查看目录条目", destination: url).font(.footnote) }
                    if verdict.decision == .review { Label("需要完整信息或家长确认后才能播放", systemImage: "person.badge.key").font(.footnote) }
                    Button(store.library.subscriptions.contains(actual.id) ? "取消订阅" : "订阅") {
                        if store.library.subscriptions.contains(actual.id) { store.unsubscribe(actual) } else { store.subscribe(actual) }
                    }.buttonStyle(.borderedProminent).disabled(!actual.hasRSSMetadata)
                }
                Section("单集") {
                    ForEach(Array(listedEpisodes.prefix(episodeLimit))) { EpisodeRow(episode: $0) }
                    if listedEpisodes.count > episodeLimit { Button("显示更多单集") { episodeLimit += 100 }.frame(minHeight: 44).accessibilityIdentifier("show.moreEpisodes").captureLayout("show.moreEpisodes") }
                    if listedEpisodes.isEmpty && !loading && !store.preparingPresentation { Text("暂无可显示单集").foregroundStyle(.secondary) }
                }
            }
            if loading { ProgressView("加载 RSS…") }
            if let error { Section { Text(error).foregroundStyle(.red); Button("重试") { Task { await reload() } } } }
        }.navigationTitle("节目详情").navigationBarTitleDisplayMode(.inline)
            .task(id: show.id) { await reload() }
            .refreshable { await reload(force: true) }
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { parentActions = true } label: { Image(systemName: "lock.shield") }.accessibilityLabel("家长规则操作") } }
            .sheet(isPresented: $parentActions) { ParentAccessView { grant in ShowParentActions(show: actual, grant: grant) } }
    }
    private func reload(force: Bool = false) async {
        guard !loading else { return }; loading = true; error = nil
        do { _ = try await store.load(actual, force: force) } catch { self.error = error.localizedDescription }
        loading = false
    }
}
