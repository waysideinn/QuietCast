import SwiftUI
import PodcastCore

@MainActor
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var submitted = ""
    @State private var importRSS = false
    @State private var searchScope = SearchScope.all
    private enum SearchScope: String, CaseIterable { case all = "综合", shows = "节目", episodes = "单集" }
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8).captureLayout("home.searchBar")
            if (store.homeRefreshing || store.refreshing) && !hasQuery {
                ProgressView("正在更新内容…").font(.footnote).padding(.bottom, 8).accessibilityIdentifier("home.refreshing")
            }
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.rules?.status == "example" {
                            NavigationLink { RuleInformationView() } label: {
                                Label("示例规则 · 正式词库未接入", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        if let error = store.securityError { Label(error, systemImage: "lock.shield").font(.footnote).foregroundStyle(.red) }
                        DiscoveryShelf(kind: .topShows)
                        DiscoveryShelf(kind: .topEpisodes)
                        DiscoveryShelf(kind: .personalized)
                        DiscoveryShelf(kind: .newShows)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("分类探索").font(.title3.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                                ForEach(PodcastCategories.roots.filter { $0.appleID != "1483" && store.filter.isCategoryAllowed($0) }) { category in
                                    NavigationLink { CategoryPage(category: category) } label: {
                                        Text(category.title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 6).background(Color.listeningAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.captureLayout("home.categories")
                        Color.clear.frame(height: 1).captureLayout("home.bottom")
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }.scrollDismissesKeyboard(.interactively)
                    .refreshable { await store.refreshHome() }
                    .opacity(hasQuery ? 0 : 1).allowsHitTesting(!hasQuery).accessibilityHidden(hasQuery)
                    .captureLayout("home.viewport")
                if hasQuery {
                    ScrollView { searchResults.padding(16) }.scrollDismissesKeyboard(.interactively).refreshable { submitSearch() }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("探索").navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { value in if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submitted = ""; store.search("") } }
        .task(id: store.discoveryCountry) { await store.loadHome() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if hasQuery { Button("取消") { cancelSearch() } }
                else { Button { importRSS = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("添加 RSS 或节目链接") }
            }
        }
        .sheet(isPresented: $importRSS) { RSSImportView() }
    }
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
                PodcastSearchField(text: $query, onSubmit: submitSearch)
                    .frame(minHeight: 44)
                if hasQuery { Button { cancelSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("清除搜索") }
            }.padding(.leading, 12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("搜索") { submitSearch(query) }.frame(minWidth: 44, minHeight: 44).disabled(!hasQuery).accessibilityIdentifier("explore.submitSearch")
        }
    }
    private var searchResults: some View {
        let current = store.searchTerm == query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shows = current ? store.results.filter(store.visible) : []
        let episodes = current ? store.episodeResults.filter(store.visibleSearchHit) : []
        return LazyVStack(alignment: .leading, spacing: 12) {
            Picker("搜索类型", selection: $searchScope) { ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("search.scope")
            if current && store.searching { ProgressView(shows.isEmpty && episodes.isEmpty ? "正在搜索节目和单集…" : "正在补充搜索结果…").frame(maxWidth: .infinity, minHeight: 44) }
            if let warning = store.searchWarning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
            if let error = store.searchError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("重新搜索") { submitSearch() }.frame(minHeight: 44)
            }
            if searchScope != .episodes && !shows.isEmpty {
                Text("节目").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ForEach(shows) { show in
                    NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }.buttonStyle(.plain)
                    Divider()
                }
            }
            if searchScope != .shows && !episodes.isEmpty {
                Text("单集").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ForEach(episodes) { hit in SearchEpisodeRow(hit: hit); Divider() }
            }
            if current && submitted == store.searchTerm && !store.searching && store.searchError == nil && (searchScope == .shows ? shows.isEmpty : searchScope == .episodes ? episodes.isEmpty : shows.isEmpty && episodes.isEmpty) {
                EmptyViewMessage(icon: "magnifyingglass", title: searchScope == .episodes ? "没有可显示的匹配单集" : searchScope == .shows ? "没有可显示的节目" : "没有可显示的结果", detail: "可换一个关键词再试。单集搜索覆盖本机已加载内容及公开目录，可能不含全部历史单集。")
            }
            if current && !submitted.isEmpty { Text("单集来自本机已加载 RSS 与 Apple 公开目录；目录覆盖因地区而异。目录单集在打开或播放时验证对应 RSS，仍需遵守家长权限。").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func submitSearch() { submitSearch(query) }
    private func submitSearch(_ text: String) { Keyboard.dismiss(); query = text; submitted = text.trimmingCharacters(in: .whitespacesAndNewlines); store.search(submitted) }
    private func cancelSearch() { query = ""; submitted = ""; store.search(""); Keyboard.dismiss() }
}

@MainActor
struct SearchEpisodeRow: View {
    @EnvironmentObject private var store: AppStore
    let hit: SearchEpisodeHit
    @State private var playRequested = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink { SearchEpisodeDetailView(hit: hit) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Artwork(url: store.library.podcasts[hit.show.id]?.artworkURL, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.episode.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text(store.library.podcasts[hit.show.id]?.title ?? hit.show.title).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain).accessibilityIdentifier("search.episode.\(hit.id)")
            ViewThatFits(in: .horizontal) {
                HStack { EpisodeMetadata(episode: hit.episode); Spacer(); playButton }
                VStack(alignment: .leading) { EpisodeMetadata(episode: hit.episode); playButton }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
            .task(id: playRequested) {
                guard playRequested else { return }
                defer { playRequested = false }
                do { let episode = try await store.resolveSearchEpisode(hit); try Task.checkCancellation(); store.play(episode) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
    }
    private var playButton: some View {
        Button { error = nil; playRequested = true } label: {
            if playRequested { ProgressView().frame(width: 44, height: 44) }
            else { Image(systemName: "play.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44) }
        }.buttonStyle(.borderless).disabled(playRequested).accessibilityLabel("播放 \(hit.episode.title)")
    }
}

@MainActor
struct SearchEpisodeDetailView: View {
    @EnvironmentObject private var store: AppStore
    let hit: SearchEpisodeHit
    @State private var episode: Episode?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let episode { EpisodeDetailView(episode: episode) }
            else if !store.visibleSearchHit(hit) { EmptyViewMessage(icon: "lock.shield", title: "内容已受家长规则限制", detail: "") }
            else {
                List {
                    Section { Text(hit.episode.title).font(.headline); Text(hit.show.title); EpisodeMetadata(episode: hit.episode) }
                    Section {
                        if let error { Text(error); Button("重试") { attempt += 1 } }
                        else { ProgressView("正在验证单集 RSS…") }
                        NavigationLink("查看所属节目") { ShowDetailView(show: hit.show) }
                    }
                }
            }
        }.navigationTitle("单集详情").navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                error = nil
                do { let value = try await store.resolveSearchEpisode(hit); try Task.checkCancellation(); episode = value }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
    }
}

struct RuleInformationView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Form {
            Section("当前规则状态") {
                if store.rules?.status == "example" { Text("当前使用示例规则，正式研究词库尚未接入，不能视为正式儿童内容防护。") }
                else if let rules = store.rules { Text("当前规则版本：\(rules.ruleVersion)") }
                else { Text("规则无法读取，过滤保持锁定，请家长恢复有效规则。").foregroundStyle(.red) }
            }
            Section("过滤范围") { Text("家长过滤依赖节目标题、简介、分类和发布身份等元数据，不能识别音频中未写入元数据的内容。") }
            Section { Text("查看或修改具体家长规则，请前往设置并验证家长 PIN。") }
        }.navigationTitle("过滤规则说明").navigationBarTitleDisplayMode(.inline)
    }
}
