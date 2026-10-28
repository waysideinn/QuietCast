import SwiftUI
import PodcastCore

@MainActor
struct SubscriptionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var onlyUnplayed = true
    @State private var importRSS = false
    @State private var limit = 100
    private var items: [Episode] { onlyUnplayed ? store.presentation.unplayed : store.presentation.updates }
    var body: some View {
        List {
            Section {
                if store.presentation.subscribed.isEmpty {
                    EmptyViewMessage(icon: "square.stack", title: "还没有订阅节目", detail: "在探索中找到喜欢的节目，或点右上角添加链接。")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(store.presentation.subscribed.prefix(8))) { show in
                                NavigationLink { ShowDetailView(show: show) } label: {
                                    VStack(alignment: .leading, spacing: 6) { Artwork(url: show.artworkURL, size: 64); Text(show.title).font(.caption).lineLimit(2).frame(width: 76, alignment: .leading) }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } header: {
                HStack { Text("已订阅节目"); Spacer(); NavigationLink("全部节目") { SubscribedShowsView() } }
            }
            Section("最近更新") {
                Picker("更新范围", selection: $onlyUnplayed) { Text("未播放").tag(true); Text("全部").tag(false) }.pickerStyle(.segmented)
                if store.refreshing { ProgressView("正在更新订阅…") }
                if store.preparingPresentation && items.isEmpty { ProgressView("正在整理单集…") }
                else if items.isEmpty { Text(onlyUnplayed ? "最近更新的单集都已听完" : "订阅节目暂无可显示单集").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12) }
                ForEach(Array(items.prefix(limit))) { EpisodeRow(episode: $0) }
                if items.count > limit { Button("显示更多单集") { limit += 100 }.frame(minHeight: 44) }
            }
            if let date = store.library.subscriptionRefreshedAt { Text("上次更新 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("订阅").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .task { await store.refreshIfNeeded() }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    NavigationLink { EpisodeCollectionView(kind: .history) } label: { Image(systemName: "clock").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("收听历史")
                    Button { importRSS = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("添加 RSS 或节目链接")
                }
            }.sheet(isPresented: $importRSS) { RSSImportView() }
    }
}

@MainActor
struct SubscribedShowsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        List {
            ForEach(store.presentation.subscribed) { show in NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) } }
            if store.presentation.subscribed.isEmpty { EmptyViewMessage(icon: "square.stack", title: "还没有订阅节目", detail: "订阅后会在这里保留。") }
        }.navigationTitle("已订阅节目").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct EpisodeCollectionView: View {
    enum Kind { case favorites, history, queue }
    @EnvironmentObject private var store: AppStore
    let kind: Kind
    @State private var limit = 100
    private var title: String { switch kind { case .favorites: return "收藏"; case .history: return "收听历史"; case .queue: return "播放队列" } }
    private var items: [Episode] { switch kind { case .favorites: return store.presentation.favorites; case .history: return store.presentation.history; case .queue: return store.presentation.queue } }
    var body: some View {
        List {
            if store.preparingPresentation && items.isEmpty { ProgressView("正在整理…") }
            else if items.isEmpty { EmptyViewMessage(icon: kind == .favorites ? "star" : kind == .history ? "clock" : "text.line.first.and.arrowtriangle.forward", title: "这里还没有内容", detail: kind == .favorites ? "收藏喜欢的单集，之后可以在这里找到。" : kind == .history ? "播放过的单集会保留进度。" : "在单集菜单中加入播放队列。") }
            if kind == .queue {
                ForEach(items) { EpisodeRow(episode: $0, entry: .queue) }
                    .onDelete { offsets in let ids = Set(offsets.map { items[$0].id }); store.change { $0.queue.removeAll { ids.contains($0) } } }
                    .onMove { source, destination in var ids = items.map(\.id); ids.move(fromOffsets: source, toOffset: destination); store.change { $0.queue = ids } }
            } else {
                ForEach(Array(items.prefix(limit))) { EpisodeRow(episode: $0, entry: .history) }
                if items.count > limit { Button("显示更多单集") { limit += 100 }.frame(minHeight: 44) }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { if kind == .queue { EditButton() } }
    }
}
