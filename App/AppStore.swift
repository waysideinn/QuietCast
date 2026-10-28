import PodcastCore
import Foundation
import SwiftUI
import UIKit

struct UnlockRequest: Identifiable {
    let id = UUID()
    let show: Podcast
    let episode: Episode?
    let result: FilterResult
}

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var library = LibraryState()
    @Published private(set) var rules: RuleSet?
    @Published private(set) var policy = ParentalPolicy()
    @Published private(set) var results: [Podcast] = []
    @Published private(set) var discoverySnapshot = DiscoverySnapshot()
    @Published private(set) var discoveryLoading: Set<String> = []
    @Published private(set) var discoveryErrors: [String: String] = [:]
    @Published private(set) var discoveryUsingCache: Set<String> = []
    @Published var discoveryCountry = "CN"
    @Published private(set) var presentation = LibraryPresentation()
    @Published private(set) var preparingPresentation = false
    private var presentationTask: Task<Void, Never>?
    private var presentationRevision: UInt64 = 0
    @Published private(set) var searching = false
    @Published private(set) var refreshing = false
    @Published private(set) var searchTerm = ""
    @Published private(set) var searchWarning: String?
    @Published private(set) var searchError: String?
    @Published private(set) var securityError: String?
    @Published private(set) var storageError: String?
    @Published var message: String?
    @Published var unlockRequest: UnlockRequest?
    @Published var externalShow: Podcast?
    @Published private(set) var blockEvents: [BlockEvent] = []
    let baseURL: URL
    private var searchJournal = SearchJournal()
    private var searchJournalError: String?
    private let searchJournalStore: SearchJournalStore
    private let persistence: AtomicLibraryStore
    private let libraryWriter: LibraryWriter
    private var libraryRevision: UInt64 = 0
    private var pendingWrite: Task<Void, Never>?
    private let directory: DirectoryClient
    private let feedClient: FeedClient
    private let discovery: DiscoveryService
    private(set) var authority: ParentAuthority?
    let downloads: DownloadManager
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var grants: ParentGrant?
    lazy var player: PodcastPlayer = {
        let p = PodcastPlayer()
        p.authorize = { [weak self] id, entry in self?.authorizeEpisode(id, entry: entry) ?? false }
        p.onStarted = { [weak self] id in self?.change { $0.beginPlayback(episodeID: id) } }
        p.onProgress = { [weak self] id, position, duration, finished in
            self?.change { $0.record(episodeID: id, position: position, duration: duration, finished: finished) }
        }
        p.onNext = { [weak self] in self?.next(automatic: true) }
        p.onPrevious = { [weak self] in self?.previous() }
        p.onError = { [weak self] text in self?.message = text }
        return p
    }()
    init(rootURL: URL? = nil, http: HTTPClient = HTTPClient(), parentAuthority: ParentAuthority? = nil, discoveryHTTP: HTTPClient? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuietCast", isDirectory: true)
        searchJournalStore = SearchJournalStore(url: root.appendingPathComponent("search-journal.json"))
        baseURL = root; persistence = AtomicLibraryStore(url: root.appendingPathComponent("library.json"))
        libraryWriter = LibraryWriter(url: root.appendingPathComponent("library.json"))
        directory = DirectoryClient(http: http); feedClient = FeedClient(http: http)
        // Discovery must neither reserve user-search rate-limit slots nor retry a slow source indefinitely.
        discovery = DiscoveryService(http: discoveryHTTP ?? HTTPClient(defaultTimeout: 8, defaultRetries: 0), interactiveHTTP: discoveryHTTP ?? HTTPClient(defaultTimeout: 6, defaultRetries: 0), cacheURL: root.appendingPathComponent("discovery.json"))
        downloads = DownloadManager(directory: root.appendingPathComponent("Audio", isDirectory: true))
        do { searchJournal = try searchJournalStore.load() } catch { searchJournalError = error.localizedDescription }
        do { library = try persistence.load() } catch { storageError = error.localizedDescription }
        do { if let parentAuthority { authority = parentAuthority } else { authority = try ParentAuthority() }; policy = authority!.policy } catch { securityError = error.localizedDescription }
        do {
            if let data = authority?.importedRules { rules = try RulesLoader.decode(data) }
            else if let url = Bundle.main.url(forResource: "content-filter", withExtension: "json") { rules = try RulesLoader.decode(FileRulesProvider(url: url).load()) }
            else { throw PodcastError.rule("缺少内置规则资源") }
        } catch { securityError = error.localizedDescription; rules = nil }
        if let data = try? Data(contentsOf: root.appendingPathComponent("blocked.json")), let logs = try? JSONDecoder().decode([BlockEvent].self, from: data) { blockEvents = logs }
        downloads.authorize = { [weak self] id in self?.authorizeEpisode(id, entry: .download, requestUnlock: false) ?? false }
        downloads.onError = { [weak self] text in self?.message = text }
        downloads.storageLimit = Int64(library.preferences.downloadLimitGB) * 1_000_000_000
        if let saved = try? DiscoveryCacheStore(url: root.appendingPathComponent("discovery.json")).load() {
            discoverySnapshot = saved
            if !saved.feeds.isEmpty { change { state in for cached in saved.feeds.values { state.merge(cached.feed) } } }
        }
        restorePlayer()
        rebuildPresentation()
    }
    var filter: ContentFilter { ContentFilter(rules: authority == nil ? nil : rules, policy: authority == nil ? ParentalPolicy() : policy) }
    func result(show: Podcast, episode: Episode? = nil) -> FilterResult { filter.evaluate(show: (library.podcasts[show.id] ?? show).mergingDirectoryMetadata(from: show), episode: episode) }
    func visible(_ show: Podcast) -> Bool { result(show: show).decision != .block }
    func visible(_ episode: Episode) -> Bool {
        guard let show = library.podcasts[episode.podcastID] else { return false }
        return result(show: show, episode: episode).decision != .block
    }
    var subscribed: [Podcast] { library.subscriptions.compactMap { library.podcasts[$0] }.filter(visible).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var history: [Episode] { library.progress.sorted { ($0.value.lastPlayed ?? .distantPast) > ($1.value.lastPlayed ?? .distantPast) }.compactMap { library.episodes[$0.key] }.filter(visible) }
    var newEpisodes: [Episode] { presentation.unplayed }
    func episodes(for show: Podcast) -> [Episode] { library.episodes.values.filter { $0.podcastID == show.id && visible($0) }.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) } }
    @discardableResult func change(_ transform: (inout LibraryState) -> Void) -> Bool {
        guard storageError == nil else { message = storageError; return false }
        var candidate = library; transform(&candidate)
        // Publish immediately. JSON encoding and the atomic multi-MB write run on the writer actor.
        library = candidate; libraryRevision &+= 1
        rebuildPresentation()
        let revision = libraryRevision, snapshot = candidate, writer = libraryWriter
        pendingWrite = Task { [weak self] in
            do { try await writer.save(snapshot, revision: revision) }
            catch { self?.storageError = error.localizedDescription; self?.message = error.localizedDescription }
        }
        return true
    }
    func flushPersistence() async { await pendingWrite?.value }
    var childCategories: [PodcastCategory] { PodcastCategories.featured.filter { filter.isCategoryAllowed($0) } }
    func discoverySection(_ kind: DiscoveryKind, category: PodcastCategory? = nil) -> DiscoverySection? {
        discoverySnapshot.sections[DiscoveryService.key(kind, country: discoveryCountry, category: category)]
    }
    func discoveryEntries(_ section: DiscoverySection) -> [DiscoveryEntry] {
        presentation.discovery[section.id] ?? []
    }
    func rebuildPresentation(clear: Bool = false) {
        presentationTask?.cancel(); presentationRevision &+= 1
        if clear { presentation = LibraryPresentation() }
        preparingPresentation = true
        let revision = presentationRevision, state = library, snapshot = discoverySnapshot, currentFilter = filter
        let worker = Task.detached(priority: .userInitiated) {
            LibraryPresentation.build(library: state, snapshot: snapshot, filter: currentFilter)
        }
        presentationTask = Task { [weak self] in
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.presentationRevision == revision else { return }
            self.presentation = value; self.preparingPresentation = false
        }
    }
    func waitForPresentation() async { await presentationTask?.value }
    func discoveryShow(_ id: String) -> Podcast? { library.podcasts[id] ?? discoverySnapshot.feeds[id]?.feed.podcast }
    func discoveryEpisode(_ entry: DiscoveryEntry) -> Episode? {
        guard let id = entry.episodeID else { return nil }
        return library.episodes[id] ?? discoverySnapshot.feeds[entry.showID]?.feed.episodes.first { $0.id == id }
    }
    func loadDiscovery(_ kind: DiscoveryKind, category: PodcastCategory? = nil, force: Bool = false) async {
        let country = discoveryCountry
        let key = DiscoveryService.key(kind, country: country, category: category)
        guard !discoveryLoading.contains(key) else { return }
        if let category, !filter.isCategoryAllowed(category) { return }
        discoveryLoading.insert(key); defer { discoveryLoading.remove(key) }
        let result = await discovery.load(kind, category: category, library: library, filter: filter, country: country, force: force) { [weak self] partial in
            await self?.applyDiscovery(partial, key: key)
        }
        guard !Task.isCancelled else { return }
        applyDiscovery(result, key: key)
    }
    private func applyDiscovery(_ result: DiscoveryLoad, key: String) {
        guard !Task.isCancelled, (result.snapshot.revision ?? 0) >= (discoverySnapshot.revision ?? 0) else { return }
        discoverySnapshot = result.snapshot
        discoveryErrors[key] = result.error
        if result.fromCache { discoveryUsingCache.insert(key) } else { discoveryUsingCache.remove(key) }
        // Only merge changed feeds; progressive category updates must not rewrite every cached episode.
        let changed = result.snapshot.feeds.values.map(\.feed).filter { feed in
            library.podcasts[feed.podcast.id] != feed.podcast || feed.episodes.contains { library.episodes[$0.id] != $0 }
        }
        if !changed.isEmpty { change { state in for feed in changed { state.merge(feed) } } }
        revalidate()
    }
    func loadHome(force: Bool = false) async {
        if !force && discoverySnapshot.sections.isEmpty { discoverySnapshot = await discovery.cached() }
        let shouldRefreshSubscriptions = force || Date().timeIntervalSince(library.subscriptionRefreshAttemptAt ?? library.subscriptionRefreshedAt ?? .distantPast) >= 3600
        await withTaskGroup(of: Void.self) { group in
            if shouldRefreshSubscriptions { group.addTask { await self.refresh() } }
            for kind in [DiscoveryKind.topShows, .topEpisodes, .personalized, .newShows] {
                group.addTask { await self.loadDiscovery(kind, force: force) }
            }
        }
    }
    func retryStorage() {
        do { library = try persistence.load(); storageError = nil; restorePlayer(); rebuildPresentation(clear: true) } catch { storageError = error.localizedDescription }
    }
    func search(_ text: String, country: String? = nil) {
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTerm = term; searchError = nil; searchWarning = nil; results = []
        searching = !term.isEmpty
        guard !term.isEmpty else { searchTask = nil; return }
        recordSearch(term)
        searchTask = Task { [self, directory] in
            do {
                if let country {
                    let found = try await directory.search(term, country: country)
                    acceptSearch(found, generation: generation)
                } else {
                    let found = try await UnifiedDirectorySearch(directory: directory).search(term) { [weak self] batch in
                        await self?.acceptSearch(batch.shows, generation: generation)
                    }
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    if found.failedSources > 0 { searchWarning = "部分目录暂时无法连接，已保留可用结果。" }
                }
            } catch is CancellationError { }
            catch { if searchGeneration == generation { searchError = error.localizedDescription } }
            if searchGeneration == generation { searching = false }
        }
    }
    private func recordSearch(_ term: String) {
        guard searchJournalError == nil else { return }
        var next = searchJournal; next.record(term)
        do { try searchJournalStore.save(next); searchJournal = next }
        catch { searchJournalError = error.localizedDescription }
    }
    func parentSearchRecords(grant: ParentGrant) throws -> [SearchRecord] {
        guard authority?.isAuthorized(grant) == true else { throw PodcastError.pin("家长授权已过期，请重新验证 PIN") }
        if let searchJournalError { throw PodcastError.storage(searchJournalError) }
        return searchJournal.entries
    }
    func deleteSearchRecords(ids: Set<String>? = nil, grant: ParentGrant) throws {
        guard authority?.isAuthorized(grant) == true else { throw PodcastError.pin("家长授权已过期，请重新验证 PIN") }
        var next = searchJournal
        if let ids {
            if let searchJournalError { throw PodcastError.storage(searchJournalError) }
            next.remove(ids: ids)
        } else { next = SearchJournal() }
        try searchJournalStore.save(next)
        searchJournal = next; searchJournalError = nil
        objectWillChange.send()
    }
    private func acceptSearch(_ found: [Podcast], generation: UUID) {
        guard !Task.isCancelled, searchGeneration == generation else { return }
        if !found.isEmpty {
            change { state in for show in found { state.merge(Feed(podcast: show, episodes: [])) } }
            revalidate()
        }
        results = found.map { library.podcasts[$0.id] ?? $0 }.filter(visible)
    }
    @discardableResult func load(_ show: Podcast, force: Bool = false, entry: AccessEntry = .detail) async throws -> Podcast {
        let feed = try await feedClient.fetch(show.feedURL, force: force)
        var full = feed; full.podcast = feed.podcast.mergingDirectoryMetadata(from: show).mergingDirectoryMetadata(from: library.podcasts[show.id])
        guard change({ $0.merge(full) }) else { throw PodcastError.storage(storageError ?? "无法保存节目") }
        revalidate()
        let verdict = result(show: full.podcast)
        if verdict.decision != .allow { log(full.podcast, nil, entry, verdict) }
        return full.podcast
    }
    func addRSS(_ text: String) async throws -> Podcast {
        let link = try ExternalLink.resolve(PublicURL.parse(text))
        let candidate: Podcast
        switch link {
        case .rss(let url): candidate = Podcast(feedURL: url, title: "")
        case .directoryID(let id): candidate = try await directory.lookup(id, country: discoveryCountry)
        }
        let full = try await load(candidate, entry: .rssImport)
        guard authorize(show: full, entry: .rssImport, requestUnlock: false) else { throw PodcastError.blocked("RSS 已校验，请家长解锁后再添加") }
        _ = subscribe(full); return full
    }
    @discardableResult func subscribe(_ show: Podcast) -> Bool {
        guard authorize(show: show, entry: .subscription) else { return false }
        return change { $0.subscriptions.insert(show.id) }
    }
    func unsubscribe(_ show: Podcast) { change { $0.subscriptions.remove(show.id) } }
    func refreshIfNeeded() async {
        if Date().timeIntervalSince(library.subscriptionRefreshAttemptAt ?? library.subscriptionRefreshedAt ?? .distantPast) >= 3600 { await refresh() }
    }
    func refresh() async {
        guard !refreshing, Date().timeIntervalSince(library.subscriptionRefreshAttemptAt ?? .distantPast) >= 60 else { return }
        refreshing = true; defer { refreshing = false }
        change { $0.subscriptionRefreshAttemptAt = Date() }
        var failures = 0
        for id in library.subscriptions {
            guard let show = library.podcasts[id] else { continue }
            do { _ = try await load(show, force: true) } catch { failures += 1 }
        }
        if failures == 0 { change { $0.subscriptionRefreshedAt = Date() } }
        if failures > 0 { message = "\(failures) 个节目暂时无法更新，已保留之前的数据。" }
    }
    @discardableResult func authorize(show: Podcast, episode: Episode? = nil, entry: AccessEntry, requestUnlock: Bool = true) -> Bool {
        let verdict = result(show: show, episode: episode)
        guard verdict.decision == .allow else {
            log(show, episode, entry, verdict)
            if requestUnlock { unlockRequest = UnlockRequest(show: show, episode: episode, result: verdict) }
            return false
        }
        return true
    }
    func authorizeEpisode(_ id: String, entry: AccessEntry, requestUnlock: Bool = true) -> Bool {
        guard let ep = library.episodes[id], let show = library.podcasts[ep.podcastID] else { return false }
        return authorize(show: show, episode: ep, entry: entry, requestUnlock: requestUnlock)
    }
    func play(_ episode: Episode, entry: AccessEntry = .playback) {
        guard authorizeEpisode(episode.id, entry: entry) else { return }
        if player.episode?.id == episode.id { player.resume(); return }
        let progress = library.progress[episode.id]
        let initial = progress?.completed == true ? 0 : progress?.position ?? 0
        player.load(episode, show: library.podcasts[episode.podcastID]!, localURL: downloads.localURL(episode.id), position: initial, preferences: library.preferences, autoplay: true)
        change { $0.currentEpisodeID = episode.id }
    }
    func enqueue(_ episode: Episode) {
        guard authorizeEpisode(episode.id, entry: .queue) else { return }
        change { if !$0.queue.contains(episode.id) { $0.queue.append(episode.id) } }
    }
    func next(automatic: Bool) {
        if automatic && !library.preferences.continuous { player.pause(); return }
        let entry: AccessEntry = automatic ? .autoplay : .playback
        var queue = library.queue
        while !queue.isEmpty {
            let id = queue.removeFirst(); change { $0.queue = queue }
            if authorizeEpisode(id, entry: entry, requestUnlock: !automatic), let ep = library.episodes[id] { play(ep, entry: entry); return }
        }
        if let current = player.episode, let show = library.podcasts[current.podcastID] {
            let all = episodes(for: show).sorted { ($0.published ?? .distantPast) < ($1.published ?? .distantPast) }
            if let index = all.firstIndex(where: { $0.id == current.id }) {
                for ep in all.dropFirst(index + 1) where library.progress[ep.id]?.completed != true {
                    if authorizeEpisode(ep.id, entry: entry, requestUnlock: !automatic) { play(ep, entry: entry); return }
                }
            }
        }
        player.pause()
    }
    func previous() {
        guard let current = player.episode, let show = library.podcasts[current.podcastID] else { return }
        let all = episodes(for: show).sorted { ($0.published ?? .distantPast) < ($1.published ?? .distantPast) }
        if let index = all.firstIndex(where: { $0.id == current.id }), index > 0 { play(all[index - 1]) }
        else { player.seek(0) }
    }
    func download(_ episode: Episode) {
        guard authorizeEpisode(episode.id, entry: .download) else { return }
        downloads.storageLimit = Int64(library.preferences.downloadLimitGB) * 1_000_000_000
        downloads.start(episode)
    }
    func favorite(_ episode: Episode) { guard authorizeEpisode(episode.id, entry: .history) else { return }; change { if !$0.favorites.insert(episode.id).inserted { $0.favorites.remove(episode.id) } } }
    func mark(_ episode: Episode, completed: Bool) { change { var p = $0.progress[episode.id] ?? EpisodeProgress(); p.completed = completed; if !completed { p.position = 0 }; $0.progress[episode.id] = p } }
    func handle(_ url: URL) async {
        do {
            let show: Podcast
            switch try ExternalLink.resolve(url) {
            case .rss(let url): show = Podcast(feedURL: url, title: "")
            case .directoryID(let id): show = try await directory.lookup(id)
            }
            let loaded = try await load(show, entry: .externalLink)
            guard authorize(show: loaded, entry: .externalLink) else { return }
            externalShow = loaded
        } catch { message = error.localizedDescription }
    }
    func retrySecurity() {
        do {
            let restored = try ParentAuthority()
            authority = restored; policy = restored.policy
            let data: Data
            if let imported = restored.importedRules { data = imported }
            else if let url = Bundle.main.url(forResource: "content-filter", withExtension: "json") { data = try FileRulesProvider(url: url).load() }
            else { throw PodcastError.rule("缺少内置规则") }
            let loaded = try RulesLoader.decode(data)
            authority = restored; policy = restored.policy; rules = loaded; securityError = nil
        } catch { rules = nil; securityError = error.localizedDescription }
        rebuildPresentation(clear: true)
        revalidate()
    }
    func lockParent() { authority?.lock(); grants = nil; objectWillChange.send() }
    func authenticate(pin: String, confirm: String = "", acknowledged: Bool = false) throws -> ParentGrant {
        guard let authority else { throw PodcastError.pin(securityError ?? "Keychain 不可用") }
        let grant = try authority.configured ? authority.authenticate(pin: pin) : authority.setup(pin: pin, confirmation: confirm, recoveryAcknowledged: acknowledged)
        grants = grant; return grant
    }
    func updatePolicy(_ value: ParentalPolicy, grant: ParentGrant) throws {
        guard let authority else { throw PodcastError.pin("安全存储不可用") }
        if value.enabled, !value.enabledCategoryIDs.isSubset(of: Set(rules?.categories.filter(\.enabled).map(\.id) ?? [])) { throw PodcastError.rule("所选类别没有有效词库") }
        try authority.updatePolicy(value, grant: grant); policy = authority.policy; rebuildPresentation(clear: true); revalidate(); objectWillChange.send()
    }
    func setException(show: Podcast, episode: Episode?, allow: Bool, grant: ParentGrant) throws {
        var value = policy
        if let ep = episode {
            if allow { value.episodeBlocklist.remove(ep.id); value.episodeAllowlist.insert(ep.id) }
            else { value.episodeAllowlist.remove(ep.id); value.episodeBlocklist.insert(ep.id) }
        } else {
            if allow { value.showBlocklist.remove(show.id); value.showAllowlist.insert(show.id) }
            else { value.showAllowlist.remove(show.id); value.showBlocklist.insert(show.id) }
        }
        try updatePolicy(value, grant: grant)
    }
    func importRules(_ url: URL, grant: ParentGrant) throws {
        guard let authority else { throw PodcastError.pin("安全存储不可用") }
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try FileRulesProvider(url: url).load()
        let candidate = try authority.importRules(data, grant: grant)
        rules = candidate; securityError = nil; rebuildPresentation(clear: true); revalidate(); objectWillChange.send()
    }
    func revalidate() {
        let allowedQueue = library.queue.filter { id in guard let ep = library.episodes[id], let show = library.podcasts[ep.podcastID] else { return false }; return filter.evaluate(show: show, episode: ep).decision == .allow }
        if allowedQueue != library.queue { change { $0.queue = allowedQueue } }
        if let ep = player.episode, !authorizeEpisode(ep.id, entry: .playback, requestUnlock: false) { player.unload(); change { $0.currentEpisodeID = nil } }
        downloads.revalidate()
        rebuildPresentation()
    }
    func sceneBackground() {
        player.save(); lockParent()
        let write = pendingWrite
        var backgroundID = UIBackgroundTaskIdentifier.invalid
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Save listening progress") {
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
        }
        Task {
            await write?.value
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
        }
    }
    private func restorePlayer() {
        guard let id = library.currentEpisodeID, let ep = library.episodes[id], let show = library.podcasts[ep.podcastID], result(show: show, episode: ep).decision == .allow else { return }
        player.load(ep, show: show, localURL: downloads.localURL(id), position: library.progress[id]?.position ?? 0, preferences: library.preferences, autoplay: false)
    }
    private func log(_ show: Podcast, _ episode: Episode?, _ entry: AccessEntry, _ result: FilterResult) {
        if let last = blockEvents.first, last.show.id == show.id, last.episode?.id == episode?.id, last.entry == entry, Date().timeIntervalSince(last.date) < 60 { return }
        blockEvents.insert(BlockEvent(show: show, episode: episode, entry: entry, result: result), at: 0)
        blockEvents = Array(blockEvents.prefix(300))
        do { try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true); try JSONEncoder().encode(blockEvents).write(to: baseURL.appendingPathComponent("blocked.json"), options: .atomic) } catch { message = "拦截仍然生效，但记录无法保存：\(error.localizedDescription)" }
    }
}
