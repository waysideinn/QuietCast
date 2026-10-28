import SwiftUI
import PodcastCore

@MainActor
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var submitted = ""
    @State private var importRSS = false
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8).captureLayout("home.searchBar")
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
                    .refreshable { await store.loadHome(force: true) }
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
        VStack(alignment: .leading, spacing: 12) {
            if store.searching { ProgressView(store.results.isEmpty ? "正在搜索节目…" : "正在补充搜索结果…").frame(maxWidth: .infinity, minHeight: 44) }
            if let warning = store.searchWarning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
            if let error = store.searchError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("重新搜索") { submitSearch() }.frame(minHeight: 44)
            }
            ForEach(store.searchTerm == query.trimmingCharacters(in: .whitespacesAndNewlines) ? store.results.filter(store.visible) : []) { show in
                NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }.buttonStyle(.plain)
                Divider()
            }
            if submitted == query.trimmingCharacters(in: .whitespacesAndNewlines) && !store.searching && store.searchError == nil && store.results.filter(store.visible).isEmpty {
                EmptyViewMessage(icon: "magnifyingglass", title: "没有可显示的结果", detail: "可换一个关键词再试。")
            }
        }
    }
    private func submitSearch() { submitSearch(query) }
    private func submitSearch(_ text: String) { Keyboard.dismiss(); query = text; submitted = text.trimmingCharacters(in: .whitespacesAndNewlines); store.search(submitted) }
    private func cancelSearch() { query = ""; submitted = ""; store.search(""); Keyboard.dismiss() }
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
