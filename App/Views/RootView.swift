import PodcastCore
import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var fullPlayer = false
    var body: some View {
        RootTabs(player: store.player, expand: { fullPlayer = true })
            .tint(Color.listeningAccent)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = store.storageError { StorageErrorBanner(error: error) }
            }
            .fullScreenCover(isPresented: $fullPlayer) { PlayerView(player: store.player) }
            .modifier(AppMessages(enabled: !fullPlayer))
    }
}

@MainActor
private struct RootTabs: View {
    let player: PodcastPlayer
    let expand: () -> Void
    @AppStorage("navigation.selectedSection") private var selectedTab = AppSection.explore.rawValue
    @State private var visited: Set<AppSection>
    init(player: PodcastPlayer, expand: @escaping () -> Void) {
        self.player = player; self.expand = expand
        let fallback = AppSection.migrating(legacy: UserDefaults.standard.integer(forKey: "navigation.selectedTab"))
        let initial = UserDefaults.standard.string(forKey: "navigation.selectedSection").flatMap(AppSection.init(rawValue:)) ?? fallback
        _selectedTab = AppStorage(wrappedValue: fallback.rawValue, "navigation.selectedSection")
        _visited = State(initialValue: [initial])
    }
    var body: some View {
        PlayerNavigationContainer(player: player, selectedTab: $selectedTab, expand: expand) {
            ZStack {
                page(.explore) { HomeView() }
                page(.subscriptions) { SubscriptionsView() }
                page(.favorites) { EpisodeCollectionView(kind: .favorites) }
                page(.downloads) { DownloadPage() }
                page(.settings) { SettingsView() }
            }
        }
        .onAppear { if AppSection(rawValue: selectedTab) == nil { selectedTab = AppSection.explore.rawValue } }
        .onChange(of: selectedTab) { if let section = AppSection(rawValue: $0) { visited.insert(section) } }
    }
    @ViewBuilder private func page<C: View>(_ section: AppSection, @ViewBuilder content: () -> C) -> some View {
        if visited.contains(section) {
            NavigationStack { content() }
                .opacity(selectedTab == section.rawValue ? 1 : 0)
                .allowsHitTesting(selectedTab == section.rawValue)
                .accessibilityHidden(selectedTab != section.rawValue)
                .zIndex(selectedTab == section.rawValue ? 1 : 0)
        }
    }
}

/// The scroll viewport ends above the dock, including after scroll-view rubber banding settles.
@MainActor
struct PlayerNavigationContainer<Content: View>: View {
    let player: PodcastPlayer
    @Binding var selectedTab: String
    let expand: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped().captureLayout("page.viewport")
            PlayerNavigationDock(player: player, selectedTab: $selectedTab, expand: expand)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor private struct DownloadPage: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { DownloadsView(manager: store.downloads) }
}

/// The measured stack owns both bars, so system tab placement cannot put them on different edges.
@MainActor
private struct PlayerNavigationDock: View {
    @ObservedObject var player: PodcastPlayer
    @Binding var selectedTab: String
    let expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if player.episode != nil { MiniPlayer(player: player, expand: expand); Divider() }
            HStack(spacing: 0) {
                tab(.explore, title: "探索", icon: "house.fill")
                tab(.subscriptions, title: "订阅", icon: "square.stack.fill")
                tab(.favorites, title: "收藏", icon: "star.fill")
                tab(.downloads, title: "下载", icon: "arrow.down.circle.fill")
                tab(.settings, title: "设置", icon: "gearshape.fill")
            }.padding(.horizontal, 4).padding(.vertical, 4)
                .accessibilityElement(children: .contain).accessibilityLabel("标签栏").captureLayout("bottomTabs")
        }.background(.regularMaterial)
    }
    private func tab(_ section: AppSection, title: String, icon: String) -> some View {
        Button { selectedTab = section.rawValue } label: {
            VStack(spacing: 3) { Image(systemName: icon).font(.system(size: 20)); Text(title).font(.caption2).lineLimit(1).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(selectedTab == section.rawValue ? Color.listeningAccent : Color.secondary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(selectedTab == section.rawValue ? [.isSelected] : [])
            .accessibilityIdentifier("tab.\(section.rawValue)").captureLayout("tab.\(section.rawValue)")
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: icon) }
    }
}

/// Present from the currently visible layer, including the full-screen player.
@MainActor
struct AppMessages: ViewModifier {
    @EnvironmentObject private var store: AppStore
    var enabled = true
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { enabled ? store.unlockRequest : nil }, set: { if enabled { store.unlockRequest = $0 } })) { request in
                ParentAccessView { grant in UnlockView(request: request, grant: grant) }
            }
            .sheet(item: Binding(get: { enabled ? store.externalShow : nil }, set: { if enabled { store.externalShow = $0 } })) { show in
                NavigationStack { ShowDetailView(show: show).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { store.externalShow = nil } } } }
            }
            .alert("提示", isPresented: Binding(get: { enabled && store.message != nil }, set: { if enabled && !$0 { store.message = nil } })) {
                Button("好") { store.message = nil }
            } message: { Text(store.message ?? "") }
    }
}

@MainActor
struct StorageErrorBanner: View {
    @EnvironmentObject private var store: AppStore
    let error: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            Button("重新读取资料库") { store.retryStorage() }.frame(minHeight: 44)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
    }
}

@MainActor
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 58
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            RoundedRectangle(cornerRadius: 10).fill(Color.listeningAccent.opacity(0.12)).overlay { Image(systemName: "waveform").foregroundStyle(Color.listeningAccent) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}

@MainActor
struct ShowRow: View {
    let show: Podcast
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: show.artworkURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(show.title).font(.headline).lineLimit(2)
                if !show.author.isEmpty { Text(show.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

@MainActor
struct EpisodeRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let episode: Episode
    var entry: AccessEntry = .playback
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink { EpisodeDetailView(episode: episode, entry: entry) } label: {
                HStack(alignment: .top, spacing: 10) {
                    if !typeSize.isAccessibilitySize { Artwork(url: episode.artworkURL ?? store.library.podcasts[episode.podcastID]?.artworkURL, size: 48) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2).foregroundStyle(.primary)
                        Text(store.library.podcasts[episode.podcastID]?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { EpisodeMetadata(episode: episode).fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0); controls }
                VStack(alignment: .leading, spacing: 0) { EpisodeMetadata(episode: episode); HStack { Spacer(); controls } }
            }
            if let progress = store.library.progress[episode.id], progress.position > 0, progress.duration > 0 {
                ProgressView(value: min(1, progress.position / progress.duration)).accessibilityLabel("已播放 \(Int(min(1, progress.position / progress.duration) * 100))%")
            }
        }.padding(.vertical, 5)
    }
    private var controls: some View {
        HStack(spacing: 0) { EpisodePlayButton(player: store.player, episode: episode, entry: entry); EpisodeActionsMenu(episode: episode) }.fixedSize()
    }
}

@MainActor
struct EpisodeMetadata: View {
    @EnvironmentObject private var store: AppStore
    let episode: Episode
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { dateAndDuration; marks }
            VStack(alignment: .leading, spacing: 3) { dateAndDuration; marks }
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var dateAndDuration: some View {
        Text([episode.published.map { $0.formatted(.dateTime.month().day()) }, episode.duration.map(TimeText.format)].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
    }
    private var marks: some View {
        HStack(spacing: 6) {
            if store.library.progress[episode.id]?.completed == true { Image(systemName: "checkmark.circle.fill").accessibilityLabel("已播放") }
            if store.library.favorites.contains(episode.id) { Image(systemName: "star.fill").accessibilityLabel("已收藏") }
            DownloadBadge(manager: store.downloads, id: episode.id)
        }
    }
}

@MainActor
struct EpisodePlayButton: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var player: PodcastPlayer
    let episode: Episode
    var entry: AccessEntry = .playback
    private var active: Bool { player.episode?.id == episode.id && (player.isPlaying || player.wantsPlay) }
    var body: some View {
        Button {
            if player.episode?.id == episode.id { player.toggle() } else { store.play(episode, entry: entry) }
        } label: { Image(systemName: active ? "pause.circle.fill" : "play.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.borderless).accessibilityLabel("\(active ? "暂停" : "播放") \(episode.title)")
    }
}

@MainActor
struct EpisodeActionsMenu: View {
    @EnvironmentObject private var store: AppStore
    let episode: Episode
    var body: some View {
        Menu {
            Button { store.enqueue(episode) } label: { Label("加入队列", systemImage: "text.badge.plus") }
            DownloadMenuActions(manager: store.downloads, episode: episode)
            Button { store.favorite(episode) } label: { Label(store.library.favorites.contains(episode.id) ? "取消收藏" : "收藏", systemImage: "star") }
            Button { store.mark(episode, completed: store.library.progress[episode.id]?.completed != true) } label: { Label(store.library.progress[episode.id]?.completed == true ? "标为未播放" : "标为已播放", systemImage: "checkmark.circle") }
        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("\(episode.title)的更多操作")
    }
}

@MainActor
struct EmptyViewMessage: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title).foregroundStyle(Color.listeningAccent)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.padding(20).frame(maxWidth: .infinity)
    }
}

enum TimeText {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(min(seconds, Double(Int.max / 2))))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
