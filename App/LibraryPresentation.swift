import Foundation
import PodcastCore
import CryptoKit

/// A cancellable display projection. Execution still goes through AppStore's live access gate.
struct LibraryPresentation: Sendable {
    var builtAt = Date()
    var validUntil: Date?
    var visibleEpisodeIDs: Set<String> = []
    var subscribed: [Podcast] = []
    var updates: [Episode] = []
    var unplayed: [Episode] = []
    var favorites: [Episode] = []
    var history: [Episode] = []
    var queue: [Episode] = []
    var episodesByShow: [String: [Episode]] = [:]
    var discovery: [String: [DiscoveryEntry]] = [:]

    static func build(library: LibraryState, snapshot: DiscoverySnapshot, filter: ContentFilter, decide: ((Podcast, Episode?) -> Decision)? = nil) -> Self {
        let decision = decide ?? { filter.evaluate(show: $0, episode: $1).decision }
        var value = Self()
        value.subscribed = library.subscriptions.compactMap { library.podcasts[$0] }
            .filter { decision($0, nil) != .block }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var visible: [String: Episode] = [:]
        for episode in library.episodes.values {
            if Task.isCancelled { return Self() }
            guard let show = library.podcasts[episode.podcastID], decision(show, episode) != .block else { continue }
            visible[episode.id] = episode
            value.episodesByShow[show.id, default: []].append(episode)
        }
        value.visibleEpisodeIDs = Set(visible.keys)
        func recent(_ a: Episode, _ b: Episode) -> Bool {
            let left = a.published ?? .distantPast, right = b.published ?? .distantPast
            return left == right ? a.id < b.id : left > right
        }
        for id in value.episodesByShow.keys { value.episodesByShow[id]?.sort(by: recent) }
        // Pick the newest eligible episode first. Completing it must not backfill an older episode.
        value.updates = value.subscribed.compactMap { value.episodesByShow[$0.id]?.first }.sorted(by: recent)
        value.unplayed = value.updates.filter { library.progress[$0.id]?.completed != true }
        value.favorites = library.favorites.compactMap { visible[$0] }.sorted(by: recent)
        // A manually marked completion is not a listening-history event.
        value.history = visible.values.filter { library.progress[$0.id]?.lastPlayed != nil }.sorted {
            let a = library.progress[$0.id]?.lastPlayed ?? .distantPast, b = library.progress[$1.id]?.lastPlayed ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
        value.queue = library.queue.compactMap { visible[$0] }
        let heard = Set(library.progress.filter { $0.value.lastPlayed != nil }.keys.compactMap { library.episodes[$0]?.podcastID })
        let candidates = snapshot.feeds.values.map { library.podcasts[$0.feed.podcast.id] ?? $0.feed.podcast }
        for section in snapshot.sections.values {
            if Task.isCancelled { return Self() }
            if let key = section.categoryKey, let category = PodcastCategories.category(key), !filter.isCategoryAllowed(category) { continue }
            let entries = section.kind == .personalized
                ? LocalRecommender.ranked(candidates, library: library, filter: filter).map { DiscoveryEntry(showID: $0.id) }
                : section.entries
            var seen = Set<String>()
            value.discovery[section.id] = entries.filter { entry in
                guard seen.insert(entry.id).inserted, let show = library.podcasts[entry.showID] ?? snapshot.feeds[entry.showID]?.feed.podcast else { return false }
                let episode = entry.episodeID.flatMap { library.episodes[$0] ?? snapshot.feeds[entry.showID]?.feed.episodes.first(where: { $0.id == entry.episodeID }) }
                guard entry.episodeID == nil || episode != nil, decision(show, episode) == .allow else { return false }
                return section.kind != .newShows || (!library.subscriptions.contains(show.id) && !heard.contains(show.id))
            }
        }
        return value
    }
}

/// Only display decisions are cached. Playback/download/queue/link gates always evaluate live policy.
/// Metadata fingerprints, complete rules, policy, clock rollback and rule expiry all invalidate reuse.
actor LibraryPresentationWorker {
    private struct Entry: Codable { var fingerprint: String; var decision: Decision }
    private struct Cache: Codable {
        var version = 1
        var rules: String
        var policy: ParentalPolicy
        var createdAt: Date
        var validUntil: Date?
        var entries: [String: Entry] = [:]
    }
    private let url: URL
    private var cache: Cache?
    private var epoch: UInt64?
    private var showInputs: [String: Podcast] = [:]
    private var showDigests: [String: String] = [:]
    private var episodeInputs: [String: Episode] = [:]
    private var episodeDigests: [String: String] = [:]
    private(set) var evaluationCount = 0
    private(set) var buildCount = 0
    init(url: URL) { self.url = url }
    private func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? Data(SHA256.hash(data: encoder.encode(value))).base64EncodedString()) ?? UUID().uuidString
    }
    func build(library: LibraryState, snapshot: DiscoverySnapshot, filter: ContentFilter, epoch: UInt64, priorityIDs: Set<String> = [], onPartial: (@Sendable (LibraryPresentation) -> Void)? = nil) -> LibraryPresentation {
        buildCount += 1
        if self.epoch == nil, let data = try? Data(contentsOf: url) { cache = try? JSONDecoder().decode(Cache.self, from: data) }
        let rules = self.epoch == epoch ? cache?.rules ?? digest(filter.rules) : digest(filter.rules)
        let valid = cache.map { $0.version == 1 && $0.rules == rules && $0.policy == filter.policy && $0.createdAt <= filter.now && ($0.validUntil ?? .distantFuture) > filter.now } ?? false
        var dirty = !valid
        if !valid { cache = Cache(rules: rules, policy: filter.policy, createdAt: filter.now) }
        self.epoch = epoch
        var prepared: [String: PreparedShowFilter] = [:]
        func decision(_ show: Podcast, _ episode: Episode?) -> Decision {
            let id = show.id
            if showInputs[id] != show {
                showInputs[id] = show; showDigests[id] = digest(show); dirty = true
            }
            let key: String, fingerprint: String
            if let episode {
                key = episode.id
                if episodeInputs[key] != episode { episodeInputs[key] = episode; episodeDigests[key] = digest(episode); dirty = true }
                fingerprint = showDigests[id, default: ""] + episodeDigests[key, default: ""]
            } else { key = "show:" + id; fingerprint = showDigests[id, default: ""] }
            if let entry = cache?.entries[key], entry.fingerprint == fingerprint { return entry.decision }
            if prepared[id] == nil { prepared[id] = filter.prepare(show: show) }
            let result = prepared[id]!.evaluate(episode: episode).decision
            evaluationCount += 1; dirty = true
            cache?.entries[key] = Entry(fingerprint: fingerprint, decision: result)
            return result
        }
        if library.episodes.count > 1000 && (buildCount == 1 || !valid), let onPartial {
            // First paint uses freshly checked local essentials, then the rest is prepared off the UI actor.
            var newest: [String: (String, Episode)] = [:]
            for (id, episode) in library.episodes {
                if newest[episode.podcastID] == nil || (episode.published ?? .distantPast) > (newest[episode.podcastID]!.1.published ?? .distantPast) { newest[episode.podcastID] = (id, episode) }
            }
            var ids = Set(newest.values.map { $0.0 }).union(library.queue)
            ids.formUnion(priorityIDs.sorted().prefix(100)); ids.formUnion(library.favorites.sorted().prefix(100))
            if let id = library.currentEpisodeID { ids.insert(id) }
            var initial = library; initial.episodes = library.episodes.filter { ids.contains($0.key) }
            let partial = LibraryPresentation.build(library: initial, snapshot: snapshot, filter: filter, decide: decision)
            if !Task.isCancelled { onPartial(partial) }
        }
        var value = LibraryPresentation.build(library: library, snapshot: snapshot, filter: filter, decide: decision)
        guard !Task.isCancelled else { return value }
        if dirty {
            let shows = Array(library.podcasts.values) + snapshot.feeds.values.map { $0.feed.podcast }
            cache?.validUntil = filter.nextChangeDate(shows: shows)
            // Bound the disposable cache to current content without touching the actual library.
            let ids = Set(library.episodes.keys).union(snapshot.feeds.values.flatMap { $0.feed.episodes.map(\.id) })
            let showIDs = Set(library.podcasts.keys).union(snapshot.feeds.keys)
            let retained = cache?.entries.filter { $0.key.hasPrefix("show:") ? showIDs.contains(String($0.key.dropFirst(5))) : ids.contains($0.key) } ?? [:]
            cache?.entries = retained
            episodeInputs = episodeInputs.filter { ids.contains($0.key) }; episodeDigests = episodeDigests.filter { ids.contains($0.key) }
            showInputs = showInputs.filter { showIDs.contains($0.key) }; showDigests = showDigests.filter { showIDs.contains($0.key) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let cache, let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        }
        value.builtAt = filter.now; value.validUntil = cache?.validUntil
        return value
    }
}

enum AppSection: String, CaseIterable {
    case explore, subscriptions, favorites, downloads, settings
    static func migrating(legacy: Int) -> Self {
        switch legacy { case 2: return .subscriptions; case 3: return .downloads; case 4: return .settings; default: return .explore }
    }
}

/// Size from the available viewport, never from a phone model or physical screen singleton.
enum PlayerLayout {
    static func artwork(width: Double, height: Double, accessibility: Bool) -> Double {
        if accessibility { return min(100, max(64, width * 0.22)) }
        return max(72, min(200, min(width * 0.46, height * 0.28)))
    }
}

enum CatalogRegion {
    static func title(_ code: String) -> String {
        switch code.uppercased() { case "HK": return "香港"; case "US": return "美国"; default: return "中国" }
    }
}
