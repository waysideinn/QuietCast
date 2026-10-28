import PodcastCore
import SwiftUI
import AVKit

@MainActor
struct MiniPlayer: View {
    @ObservedObject var player: PodcastPlayer
    @Environment(\.dynamicTypeSize) private var typeSize
    let expand: () -> Void
    private var active: Bool { player.isPlaying || player.wantsPlay }
    var body: some View {
        if let episode = player.episode {
            HStack(spacing: 8) {
                Button(action: expand) {
                    HStack(spacing: 10) {
                        Artwork(url: episode.artworkURL ?? player.show?.artworkURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title).font(.subheadline.bold()).lineLimit(1)
                            Text(player.show?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("展开播放器：\(episode.title)").accessibilityIdentifier("miniPlayer.expand")
                    .accessibilityShowsLargeContentViewer { VStack { Text(episode.title); Text(player.show?.title ?? "") } }
                Button { player.toggle() } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: active ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 44, height: 44)
                        if player.buffering { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    }
                }.buttonStyle(.plain).foregroundStyle(Color.listeningAccent).accessibilityLabel(active ? "暂停" : "播放").accessibilityIdentifier("miniPlayer.playPause")
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(alignment: .top) { ProgressView(value: player.duration > 0 ? min(1, player.position / player.duration) : 0).tint(Color.listeningAccent).accessibilityHidden(true) }
                .accessibilityElement(children: .contain).captureLayout("miniPlayer")
        }
    }
}

@MainActor
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = UIColor.listeningAccent; view.prioritizesVideoDevices = false; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

@MainActor
struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var player: PodcastPlayer
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var jump = ""
    @State private var showJump = false
    private var active: Bool { player.isPlaying || player.wantsPlay }
    private var show: Podcast? { player.episode.flatMap { store.library.podcasts[$0.podcastID] } ?? player.show }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 10) {
                        if let episode = player.episode {
                            Artwork(url: episode.artworkURL ?? show?.artworkURL, size: PlayerLayout.artwork(width: geometry.size.width - 32, height: geometry.size.height, accessibility: typeSize.isAccessibilitySize))
                                .padding(.top, 4)
                            Text(episode.title).font(.title3.bold()).multilineTextAlignment(.center)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                            if let show {
                                NavigationLink { ShowDetailView(show: show) } label: {
                                    VStack(spacing: 2) {
                                        Text(show.title).font(.subheadline.bold()).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                        HStack(spacing: 4) { Text(show.author.isEmpty ? "查看节目" : show.author); Image(systemName: "chevron.right").font(.caption2) }.font(.caption).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                    }.frame(maxWidth: .infinity, minHeight: 44)
                                }.buttonStyle(.plain).foregroundStyle(Color.listeningAccent).accessibilityLabel("\(show.author.isEmpty ? show.title : show.author)，查看当前播客的节目详情").accessibilityIdentifier("player.show")
                            }
                            progress
                            transport
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
                                Button { store.favorite(episode) } label: { PlayerActionLabel(icon: store.library.favorites.contains(episode.id) ? "star.fill" : "star", title: store.library.favorites.contains(episode.id) ? "已收藏" : "收藏") }
                                    .accessibilityIdentifier("player.favorite").captureLayout("player.favorite")
                                speedMenu
                                sleepMenu
                                DownloadControl(manager: store.downloads, episode: episode)
                            }.buttonStyle(.plain).foregroundStyle(Color.listeningAccent).accessibilityIdentifier("player.actions").captureLayout("player.actions")
                            HStack(spacing: 10) {
                                if player.buffering { ProgressView().controlSize(.small); Text(player.wantsPlay ? "正在缓冲…" : "正在准备音频…").font(.caption) }
                                else { Text(player.isPlaying ? "正在播放" : "已暂停").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("蓝牙和 AirPlay 输出")
                                NavigationLink { EpisodeCollectionView(kind: .queue) } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("编辑播放队列")
                            }
                            Divider()
                            DisclosureGroup("单集简介") { Text(episode.summary.isEmpty ? "暂无单集简介" : episode.summary).font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                                .font(.headline).padding(.vertical, 4)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text("接下来播放").font(.headline); Spacer(); NavigationLink("编辑队列") { EpisodeCollectionView(kind: .queue) }.font(.subheadline).frame(minHeight: 44) }
                                ForEach(Array(store.presentation.queue.prefix(3))) { EpisodeRow(episode: $0, entry: .queue) }
                                if store.presentation.queue.isEmpty { Text("在单集菜单中加入播放队列").font(.subheadline).foregroundStyle(.secondary) }
                            }
                        } else { EmptyViewMessage(icon: "waveform", title: "尚未播放", detail: "从节目中选择一个单集开始收听。") }
                    }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 20)
                }.background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { if let error = store.storageError { StorageErrorBanner(error: error) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("收起播放器") }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { store.previous() } label: { Label("上一集", systemImage: "backward.end") }
                        Button { store.next(automatic: false) } label: { Label("下一集", systemImage: "forward.end") }
                        Button { jump = ""; showJump = true } label: { Label("跳到指定时间", systemImage: "timer") }
                        if let episode = player.episode { Button { store.enqueue(episode) } label: { Label("加入队列", systemImage: "text.badge.plus") } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("更多播放工具")
                }
            }
            .alert("跳到指定时间", isPresented: $showJump) {
                TextField("分钟:秒，例如 12:30", text: $jump).keyboardType(.numbersAndPunctuation)
                Button("跳转") { Keyboard.dismiss(); if let time = RSSParser.duration(jump) { player.seek(time) } else { store.message = "请输入有效时间，例如 12:30。" } }
                Button("取消", role: .cancel) {}
            } message: { Text("输入 秒、分:秒 或 时:分:秒") }
        }.tint(Color.listeningAccent).modifier(AppMessages())
    }
    private var progress: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { scrubbing ? scrubValue : min(player.position, max(1, player.duration)) }, set: { scrubValue = $0 }), in: 0...max(1, player.duration), onEditingChanged: { editing in
                if editing { scrubValue = player.position; scrubbing = true } else { player.seek(scrubValue); scrubbing = false }
            }).accessibilityLabel("播放进度").accessibilityValue("\(TimeText.format(player.position))，共\(TimeText.format(player.duration))").disabled(player.duration <= 0)
            HStack { Text(TimeText.format(scrubbing ? scrubValue : player.position)); Spacer(); Text("−" + TimeText.format(max(0, player.duration - (scrubbing ? scrubValue : player.position)))) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.skip(forward: false) } label: { VStack(spacing: 2) { Image(systemName: "gobackward").font(.title2); Text("\(Int(store.library.preferences.backwardSeconds))").font(.caption) }.frame(minWidth: 52, minHeight: 56) }.accessibilityLabel("快退\(Int(store.library.preferences.backwardSeconds))秒")
            Button { player.toggle() } label: { Image(systemName: active ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)).frame(minWidth: 64, minHeight: 64) }.accessibilityLabel(active ? "暂停" : "播放").accessibilityIdentifier("player.playPause")
            Button { player.skip(forward: true) } label: { VStack(spacing: 2) { Image(systemName: "goforward").font(.title2); Text("\(Int(store.library.preferences.forwardSeconds))").font(.caption) }.frame(minWidth: 52, minHeight: 56) }.accessibilityLabel("快进\(Int(store.library.preferences.forwardSeconds))秒")
        }.buttonStyle(.plain).foregroundStyle(Color.listeningAccent).frame(maxWidth: .infinity)
    }
    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.75),1,1.25,1.5,1.75,2,2.5,3], id: \.self) { speed in
                Button { if store.change({ $0.preferences.speed = speed }) { player.setSpeed(speed) } } label: {
                    if player.speed == speed { Label("\(String(format: "%g", speed))×", systemImage: "checkmark") }
                    else { Text("\(String(format: "%g", speed))×") }
                }
            }
        } label: { VStack(spacing: 5) { Text("\(String(format: "%g", player.speed))×").font(.headline); Text("倍速").font(.caption) }.frame(maxWidth: .infinity, minHeight: 54) }.accessibilityLabel("倍速，当前\(String(format: "%g", player.speed))倍").accessibilityIdentifier("player.speed").captureLayout("player.speed")
    }
    private var sleepMenu: some View {
        Menu {
            ForEach([5,15,30,45,60], id: \.self) { minutes in Button("\(minutes) 分钟") { player.setSleep(minutes: minutes) } }
            if player.sleepDeadline != nil { Button("关闭定时器") { player.setSleep(minutes: nil) } }
        } label: {
            VStack(spacing: 5) {
                if let deadline = player.sleepDeadline { Text(deadline, style: .timer).font(.subheadline.monospacedDigit()) }
                else { Image(systemName: "moon").font(.title3) }
                Text("睡眠").font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 54)
        }.accessibilityLabel(player.sleepDeadline == nil ? "睡眠倒计时，未开启" : "睡眠倒计时，已开启").accessibilityIdentifier("player.sleep").captureLayout("player.sleep")
    }
}

struct PlayerActionLabel: View {
    let icon: String
    let title: String
    var body: some View { VStack(spacing: 5) { Image(systemName: icon).font(.title3); Text(title).font(.caption) }.frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle()) }
}

@MainActor
struct EpisodeDetailView: View {
    @EnvironmentObject private var store: AppStore
    let episode: Episode
    var entry: AccessEntry = .detail
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.visible(episode) {
                    Text(episode.title).font(.title2.bold())
                    if let show = store.library.podcasts[episode.podcastID] { NavigationLink { ShowDetailView(show: show) } label: { Label(show.title, systemImage: "square.stack") }.frame(minHeight: 44) }
                    EpisodeMetadata(episode: episode)
                    HStack { EpisodePlayButton(player: store.player, episode: episode, entry: entry); Spacer(); Button { store.favorite(episode) } label: { Label(store.library.favorites.contains(episode.id) ? "已收藏" : "收藏", systemImage: store.library.favorites.contains(episode.id) ? "star.fill" : "star") }.frame(minHeight: 44); Spacer(); DownloadControl(manager: store.downloads, episode: episode) }
                    Text(episode.summary.isEmpty ? "暂无单集简介" : episode.summary).font(.body)
                } else {
                    EmptyViewMessage(icon: "lock.shield", title: "内容已受家长规则限制", detail: "")
                    Button("申请家长解锁") { _ = store.authorizeEpisode(episode.id, entry: entry) }.frame(minHeight: 44)
                }
            }.padding(16)
        }.navigationTitle("单集详情").navigationBarTitleDisplayMode(.inline)
    }
}
