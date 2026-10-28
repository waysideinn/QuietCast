import SwiftUI
import PodcastCore

@MainActor
struct DiscoveryShelf: View {
    @EnvironmentObject private var store: AppStore
    let kind: DiscoveryKind
    var category: PodcastCategory? = nil
    @State private var sourceInfo = false
    private var key: String { DiscoveryService.key(kind, country: store.discoveryCountry, category: category) }
    private var section: DiscoverySection? { store.discoverySection(kind, category: category) }
    private var isChart: Bool { kind == .topShows || kind == .topEpisodes }
    private var hasChart: Bool { section?.origin == .appleShowsChart || section?.origin == .appleEpisodesChart }
    private var entries: [DiscoveryEntry] {
        if isChart { return hasChart ? section.map(store.discoveryEntries) ?? [] : [] }
        var values = section.map(store.discoveryEntries) ?? []
        if kind == .newShows {
            let otherKeys = [store.discoveryCountry.uppercased() + ":supplement:all", DiscoveryService.key(.topShows, country: store.discoveryCountry), DiscoveryService.key(.topEpisodes, country: store.discoveryCountry)]
            for other in otherKeys {
                guard let part = store.discoverySnapshot.sections[other], part.origin == .directoryDiscovery || part.origin == .directoryEpisodes else { continue }
                values += store.discoveryEntries(part).map { DiscoveryEntry(showID: $0.showID) }
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert(kind == .newShows ? $0.showID : $0.id).inserted }
    }
    private var title: String {
        switch kind { case .topShows: return "热门播客"; case .topEpisodes: return "热门单集"; case .personalized: return "你可能喜欢"; case .newShows: return "发现新节目"; case .category: return category?.title ?? "分类节目" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { Text(title).font(.title3.bold()); Spacer(); moreLink }
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.title3.bold()); moreLink }
            }
            if !entries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(entries.prefix(6))) { item in DiscoveryCard(entry: item) }
                    }.padding(.vertical, 2)
                }
                Button { sourceInfo = true } label: {
                    HStack(spacing: 5) { Text(sourceLabel); if store.discoveryUsingCache.contains(key) { Text("· 缓存") }; Image(systemName: "info.circle") }
                        .font(.caption).foregroundStyle(.secondary).frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("查看\(title)的内容来源")
            } else if store.discoveryLoading.contains(key) || store.preparingPresentation {
                HStack(spacing: 12) { ProgressView(); Text("正在加载…").font(.subheadline).foregroundStyle(.secondary) }.frame(minHeight: 70)
            } else {
                Text(isChart && !hasChart ? "公开榜单暂不可用" : "当前暂无可显示内容").font(.subheadline).foregroundStyle(.secondary)
            }
            if store.discoveryLoading.contains(key) && !entries.isEmpty { ProgressView("正在更新…").font(.caption) }
            if let error = store.discoveryErrors[key] { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if !store.discoveryLoading.contains(key), entries.isEmpty || store.discoveryErrors[key] != nil {
                Button("重新加载") { Task { await store.loadDiscovery(kind, category: category, force: true) } }.font(.subheadline).frame(minHeight: 44)
            }
        }.accessibilityElement(children: .contain)
            .sheet(isPresented: $sourceInfo) {
                NavigationStack { SourceInformationView(section: section, isChart: isChart).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sourceInfo = false } } } }
            }
    }
    private var moreLink: some View {
        NavigationLink { DiscoveryListView(title: title, entries: entries, category: category) } label: {
            Label("查看更多", systemImage: "chevron.right").font(.subheadline).frame(minHeight: 44)
        }.disabled(entries.isEmpty)
    }
    private var sourceLabel: String {
        if kind == .personalized { return "依据本机收听偏好" }
        if kind == .newShows { return "对你而言的新节目 · 公开目录" }
        if section?.origin == .localLibrary { return "本机已加载的节目" }
        if section?.origin == .directoryDiscovery { return "公开目录发现 · 非榜单" }
        return "Apple 公开榜单 · \(CatalogRegion.title(store.discoveryCountry))"
    }
}

@MainActor
private struct DiscoveryCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: DiscoveryEntry
    @ScaledMetric(relativeTo: .subheadline) private var showWidth: CGFloat = 124
    @ScaledMetric(relativeTo: .subheadline) private var episodeWidth: CGFloat = 244
    var body: some View {
        if let episode = store.discoveryEpisode(entry) {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink { EpisodeDetailView(episode: episode, entry: .charts) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Artwork(url: episode.artworkURL ?? store.discoveryShow(entry.showID)?.artworkURL, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(episode.title).font(.subheadline.bold()).lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                            Text(store.discoveryShow(entry.showID)?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                HStack {
                    if let rank = entry.rank { Text("#\(rank)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    EpisodePlayButton(player: store.player, episode: episode, entry: .charts)
                    EpisodeActionsMenu(episode: episode)
                }
            }.padding(12).frame(width: min(episodeWidth, 330), alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        } else if let show = store.discoveryShow(entry.showID) {
            NavigationLink { ShowDetailView(show: show) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Artwork(url: show.artworkURL, size: min(showWidth, 170))
                    Text(show.title).font(.subheadline.bold()).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let rank = entry.rank { Text("#\(rank)").font(.caption).foregroundStyle(.secondary) }
                }.frame(width: min(showWidth, 170), alignment: .leading)
            }.buttonStyle(.plain)
        }
    }
}

@MainActor
private struct DiscoveryListView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let entries: [DiscoveryEntry]
    var category: PodcastCategory?
    var body: some View {
        List {
            if let category, !store.filter.isCategoryAllowed(category) { Label("此分类已由家长禁用", systemImage: "lock.shield") }
            else {
                ForEach(entries) { item in
                    if let episode = store.discoveryEpisode(item), let show = store.discoveryShow(item.showID), store.result(show: show, episode: episode).decision == .allow { EpisodeRow(episode: episode, entry: .charts) }
                    else if item.episodeID == nil, let show = store.discoveryShow(item.showID), store.result(show: show).decision == .allow {
                        NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }
                    }
                }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct SourceInformationView: View {
    @EnvironmentObject private var store: AppStore
    let section: DiscoverySection?
    let isChart: Bool
    var body: some View {
        Form {
            if let section {
                Text(section.origin.label)
                if let name = section.sourceTitle { LabeledContent("来源标题", value: name) }
                LabeledContent("目录地区", value: CatalogRegion.title(section.country))
                LabeledContent("获取时间", value: section.generatedAt.formatted(date: .abbreviated, time: .shortened))
                if let url = section.sourceURL { Link("查看公开来源", destination: url) }
                if isChart { Text("显示原始榜单名次；过滤后可能缺号，不重新排名。") }
            }
            Text("目录补充不计作官方榜单。“发现新节目”指尚未订阅或收听的节目，不表示刚刚发布。")
            if store.rules?.status == "example" { Text("当前示例规则不能视为正式儿童内容防护。") }
        }.navigationTitle("内容来源").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct CategoryPage: View {
    @EnvironmentObject private var store: AppStore
    let category: PodcastCategory
    var body: some View {
        Group {
            if !store.filter.isCategoryAllowed(category) { EmptyViewMessage(icon: "lock.shield", title: "此分类已由家长禁用", detail: "") }
            else if category.children.isEmpty { CategoryShowsView(category: category) }
            else {
                List {
                    NavigationLink("全部\(category.title)节目") { CategoryShowsView(category: category) }
                    ForEach(category.children.filter { store.filter.isCategoryAllowed($0) }) { child in NavigationLink(child.title) { CategoryPage(category: child) } }
                }
            }
        }.navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct CategoryShowsView: View {
    @EnvironmentObject private var store: AppStore
    let category: PodcastCategory
    var body: some View {
        ScrollView {
            if store.filter.isCategoryAllowed(category) { DiscoveryShelf(kind: .category, category: category).padding(16) }
            else { EmptyViewMessage(icon: "lock.shield", title: "此分类已由家长禁用", detail: "") }
        }.navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
            .task { await store.loadDiscovery(.category, category: category) }
            .refreshable { await store.loadDiscovery(.category, category: category, force: true) }
    }
}
