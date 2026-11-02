import Foundation
import PodcastModels
import ContentFiltering

public struct UnifiedSearchResult: Sendable {
    public var shows: [Podcast]
    public var completedSources: Int
    public var failedSources: Int
    public var episodes: [SearchEpisodeHit] = []
}

/// Federates the three supported storefronts without fetching any RSS or merging homonymous shows.
public struct UnifiedDirectorySearch: Sendable {
    private let directory: DirectoryClient
    public init(directory: DirectoryClient) { self.directory = directory }
    private struct RegionalResult: Sendable { var shows: [Podcast] = []; var episodes: [SearchEpisodeHit] = []; var failed = false }
    public func search(_ text: String, countries: [String] = ["CN", "HK", "US"], includeEpisodes: Bool = false, onUpdate: (@Sendable (UnifiedSearchResult) async -> Void)? = nil) async throws -> UnifiedSearchResult {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return UnifiedSearchResult(shows: [], completedSources: 0, failedSources: 0) }
        let result = await withTaskGroup(of: RegionalResult?.self) { group in
            for country in countries {
                group.addTask { [directory] in
                    do { return RegionalResult(shows: try await directory.search(term, country: country, timeout: 8, retries: 0), failed: false) }
                    catch { return Task.isCancelled ? nil : RegionalResult(shows: [], failed: true) }
                }
                if includeEpisodes {
                    group.addTask { [directory] in
                        do { return RegionalResult(episodes: try await directory.searchEpisodes(term, country: country)) }
                        catch { return Task.isCancelled ? nil : RegionalResult(failed: true) }
                    }
                }
            }
            var merged = UnifiedSearchResult(shows: [], completedSources: 0, failedSources: 0)
            var seen = Set<String>()
            for await regional in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                guard let regional else { continue }
                merged.completedSources += 1
                if regional.failed { merged.failedSources += 1 }
                // Stable first-seen order prevents late storefronts moving rows while people browse them.
                for show in regional.shows where seen.insert(show.id).inserted { merged.shows.append(show) }
                merged.episodes = EpisodeSearch.deduplicated(merged.episodes + regional.episodes)
                await onUpdate?(merged)
            }
            return merged
        }
        try Task.checkCancellation()
        if result.failedSources == countries.count * (includeEpisodes ? 2 : 1) { throw SearchUnavailable() }
        return result
    }
    private struct SearchUnavailable: LocalizedError {
        var errorDescription: String? { "搜索暂时无法连接，请检查网络后重试。" }
    }
}

/// Directory metadata is a discovery candidate, never a playable library episode.
public struct SearchEpisodeHit: Identifiable, Sendable {
    public let show: Podcast
    public let episode: Episode
    public let identity: DirectoryEpisodeIdentity?
    public let country: String
    // Compute the SHA-backed local ID once in the background, not on every SwiftUI/render lookup.
    public let id: String
    fileprivate let guidKey: String?
    fileprivate let enclosureKey: String
    public init(show: Podcast, episode: Episode, identity: DirectoryEpisodeIdentity? = nil, country: String = "CN") {
        self.show = show; self.episode = episode; self.identity = identity; self.country = country
        self.id = identity.map { "apple:\($0.showDirectoryID):\($0.episodeDirectoryID)" } ?? episode.id
        let guid = identity?.guid ?? (identity == nil ? episode.guid : "")
        let showID = show.id
        self.guidKey = guid.isEmpty ? nil : showID + "\n" + guid
        self.enclosureKey = showID + "\n" + episode.audioURL.absoluteString
    }
}

public enum EpisodeSearch {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    /// Every query token must occur in this episode's own text; a show title alone is insufficient.
    public static func matches(_ episode: Episode, query: String) -> Bool {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return false }
        let text = normalized(episode.title + "\n" + episode.summary + "\n" + episode.metadata)
        return tokens.allSatisfy { text.contains($0) }
    }
    public static func local(_ query: String, library: LibraryState, filter: ContentFilter, visibleIDs: Set<String>? = nil) -> [SearchEpisodeHit] {
        var prepared: [String: PreparedShowFilter] = [:]
        let matches = library.episodes.values.filter { episode in
            !Task.isCancelled && (visibleIDs?.contains(episode.id) ?? true) && Self.matches(episode, query: query)
        }.sorted {
            if $0.published != $1.published { return ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            return $0.id < $1.id
        }
        return matches.compactMap { episode in
            guard !Task.isCancelled else { return nil }
            guard let show = library.podcasts[episode.podcastID] else { return nil }
            if visibleIDs == nil {
                if prepared[show.id] == nil { prepared[show.id] = filter.prepare(show: show) }
                guard prepared[show.id]!.evaluate(episode: episode).decision != .block else { return nil }
            }
            return SearchEpisodeHit(show: show, episode: episode)
        }
    }
    public static func resolve(_ hit: SearchEpisodeHit, in feed: Feed) -> Episode? {
        guard hit.show.id == feed.podcast.id else { return nil }
        guard let identity = hit.identity else { return feed.episodes.first { $0.id == hit.episode.id } }
        let matches: [Episode]
        if let guid = identity.guid, !guid.isEmpty { matches = feed.episodes.filter { $0.guid == guid && $0.podcastID == feed.podcast.id } }
        else if let url = identity.audioURL { matches = feed.episodes.filter { $0.audioURL == url && $0.podcastID == feed.podcast.id } }
        else { return nil }
        return matches.count == 1 ? matches[0] : nil
    }
    public static func deduplicated(_ hits: [SearchEpisodeHit]) -> [SearchEpisodeHit] {
        var directoryIDs = Set<String>(), guids = Set<String>(), enclosures = Set<String>()
        return hits.filter { hit in
            let duplicate = directoryIDs.contains(hit.id) || (hit.guidKey.map { guids.contains($0) } ?? false) || enclosures.contains(hit.enclosureKey)
            directoryIDs.insert(hit.id)
            if let key = hit.guidKey { guids.insert(key) }
            enclosures.insert(hit.enclosureKey)
            return !duplicate
        }
    }
}
