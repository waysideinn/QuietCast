import Foundation
import PodcastCore

/// A cancellable display projection. Execution still goes through AppStore's live access gate.
struct LibraryPresentation: Sendable {
    var visibleEpisodeIDs: Set<String> = []
    var subscribed: [Podcast] = []
    var updates: [Episode] = []
    var unplayed: [Episode] = []
    var favorites: [Episode] = []
    var history: [Episode] = []
    var queue: [Episode] = []
    var episodesByShow: [String: [Episode]] = [:]
    var discovery: [String: [DiscoveryEntry]] = [:]

    static func build(library: LibraryState, snapshot: DiscoverySnapshot, filter: ContentFilter) -> Self {
        var value = Self()
        value.subscribed = library.subscriptions.compactMap { library.podcasts[$0] }
            .filter { filter.evaluate(show: $0).decision != .block }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var visible: [String: Episode] = [:]
        for episode in library.episodes.values {
            if Task.isCancelled { return Self() }
            guard let show = library.podcasts[episode.podcastID], filter.evaluate(show: show, episode: episode).decision != .block else { continue }
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
                guard entry.episodeID == nil || episode != nil, filter.evaluate(show: show, episode: episode).decision == .allow else { return false }
                return section.kind != .newShows || (!library.subscriptions.contains(show.id) && !heard.contains(show.id))
            }
        }
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
