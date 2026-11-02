import Foundation
import PodcastModels
import ContentFiltering

public enum CacheFreshness {
    public static func isFresh(_ date: Date, ttl: TimeInterval, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(date); return age >= 0 && age < ttl
    }
}
public enum DiscoveryKind: String, Codable, CaseIterable, Sendable {
    case topShows, topEpisodes, personalized, newShows, category
}
public enum DiscoveryOrigin: String, Codable, Sendable {
    case appleShowsChart, appleEpisodesChart, appleCategoryChart, directoryDiscovery, directoryEpisodes, localRecommendation, localLibrary
    public var label: String {
        switch self {
        case .appleShowsChart: return "Apple 公开节目榜 · 已过滤"
        case .appleEpisodesChart: return "Apple 公开单集榜 · 已过滤"
        case .appleCategoryChart: return "Apple 公开分类榜 · 已过滤"
        case .directoryDiscovery: return "公开目录发现 · 非官方榜单"
        case .directoryEpisodes: return "目录节目中的新近单集 · 非单集榜"
        case .localRecommendation: return "依据本机订阅、收藏和收听记录"
        case .localLibrary: return "本机已加载且通过当前规则的节目"
        }
    }
}
public struct DiscoveryEntry: Codable, Identifiable, Equatable, Sendable {
    public var showID: String
    public var episodeID: String?
    public var rank: Int?
    public var id: String { episodeID ?? showID }
    public init(showID: String, episodeID: String? = nil, rank: Int? = nil) { self.showID = showID; self.episodeID = episodeID; self.rank = rank }
}
public struct DiscoverySection: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: DiscoveryKind
    public var title: String
    public var origin: DiscoveryOrigin
    public var sourceURL: URL?
    public var sourceTitle: String?
    public var country: String
    public var generatedAt: Date
    public var entries: [DiscoveryEntry]
    public var categoryKey: String?
    public var isPartial: Bool? = nil
}
public struct CachedDiscoveryFeed: Codable, Sendable {
    public var feed: Feed; public var fetchedAt: Date
    public init(feed: Feed, fetchedAt: Date) { self.feed = feed; self.fetchedAt = fetchedAt }
}
public struct DiscoverySnapshot: Codable, Sendable {
    public var version = 1
    public var revision: UInt64?
    public var sections: [String: DiscoverySection] = [:]
    public var feeds: [String: CachedDiscoveryFeed] = [:]
    public init() {}
}
public struct DiscoveryCacheStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> DiscoverySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return DiscoverySnapshot() }
        let result = try JSONDecoder().decode(DiscoverySnapshot.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw PodcastError.storage("发现缓存版本不支持") }; return result
    }
    public func save(_ snapshot: DiscoverySnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
public struct ChartReference: Sendable {
    public let showDirectoryID: String
    public let episodeDirectoryID: String?
    public let title: String
    public let rank: Int
    public let url: URL
}
public struct PublicChart: Sendable { public let title: String; public let url: URL; public let references: [ChartReference] }
public struct PublicChartsClient: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }
    private struct Modern: Decodable {
        struct Feed: Decodable { let title: String; let results: [Item] }
        struct Item: Decodable { let id: String; let name: String; let kind: String; let url: URL }
        let feed: Feed
    }
    public func chart(country: String = "CN", episodes: Bool = false, categoryID: String? = nil, force: Bool = false) async throws -> PublicChart {
        guard ["CN","HK","US"].contains(country.uppercased()), categoryID == nil || categoryID!.allSatisfy(\.isNumber) else { throw PodcastError.invalidURL }
        if categoryID != nil { return try await legacy(country: country, categoryID: categoryID, force: force) }
        let suffix = episodes ? "podcast-episodes" : "podcasts"
        let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country.lowercased())/podcasts/top/50/\(suffix).json")!
        do {
            let value = try JSONDecoder().decode(Modern.self, from: await http.get(url, force: force))
            let entries = value.feed.results.enumerated().compactMap { index, item -> ChartReference? in
                guard item.kind == suffix, item.url.host?.lowercased() == "podcasts.apple.com", case .directoryID(let id) = try? ExternalLink.resolve(item.url) else { return nil }
                let episodeID = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value
                guard !episodes || episodeID == item.id else { return nil }
                return ChartReference(showDirectoryID: id, episodeDirectoryID: episodes ? item.id : nil, title: item.name, rank: index + 1, url: item.url)
            }
            guard !entries.isEmpty else { throw PodcastError.invalidFeed("公开榜单没有可识别条目") }
            return PublicChart(title: value.feed.title, url: url, references: entries)
        } catch {
            if episodes || Task.isCancelled { throw error }
            return try await legacy(country: country, categoryID: nil, force: force)
        }
    }
    private func legacy(country: String, categoryID: String?, force: Bool) async throws -> PublicChart {
        let genre = categoryID.map { "/genre=\($0)" } ?? ""
        let url = URL(string: "https://itunes.apple.com/\(country.lowercased())/rss/toppodcasts/limit=50\(genre)/json")!
        let raw = try JSONSerialization.jsonObject(with: await http.get(url, directory: true, force: force)) as? [String: Any]
        guard let feed = raw?["feed"] as? [String: Any], let items = feed["entry"] as? [[String: Any]], !items.isEmpty else { throw PodcastError.invalidFeed("公开分类榜单不可用") }
        let references = items.enumerated().compactMap { index, item -> ChartReference? in
            guard let idValue = item["id"] as? [String: Any], let attrs = idValue["attributes"] as? [String: Any], let id = attrs["im:id"] as? String,
                  let label = idValue["label"] as? String, let link = URL(string: label), link.host == "podcasts.apple.com" else { return nil }
            return ChartReference(showDirectoryID: id, episodeDirectoryID: nil, title: (item["im:name"] as? [String: String])?["label"] ?? "", rank: index + 1, url: link)
        }
        guard !references.isEmpty else { throw PodcastError.invalidFeed("榜单条目格式不支持") }
        return PublicChart(title: (feed["title"] as? [String: String])?["label"] ?? "Apple Podcasts", url: url, references: references)
    }
    /// Verify the chart's exact Apple episode ID against the public Lookup GUID/enclosure, then match only within its actual RSS.
    public static func resolveEpisode(_ reference: ChartReference, in feed: Feed, identity: DirectoryEpisodeIdentity? = nil) -> Episode? {
        guard let identity, reference.episodeDirectoryID == identity.episodeDirectoryID, reference.showDirectoryID == identity.showDirectoryID else { return nil }
        let matches: [Episode]
        if let guid = identity.guid, !guid.isEmpty { matches = feed.episodes.filter { $0.guid == guid } }
        else if let url = identity.audioURL { matches = feed.episodes.filter { $0.audioURL == url } }
        else { return nil }
        return matches.count == 1 ? matches[0] : nil
    }
}

public enum LocalRecommender {
    public static func categories(for show: Podcast) -> Set<String> {
        let observations = show.classificationObservations ?? show.categories.map { ClassificationObservation(namespace: "rss.itunes.category", name: $0, source: .rss, sourceURL: show.feedURL) }
        return Set(observations.flatMap(PodcastCategories.matching).map(\.id))
    }
    public static func interests(library: LibraryState, now: Date = Date()) -> [String: Double] {
        var interests: [String: Double] = [:]
        func add(_ id: String, weight: Double) {
            guard let show = library.podcasts[id] else { return }
            for key in categories(for: show) { interests[key, default: 0] += weight }
        }
        for id in library.subscriptions { add(id, weight: 3) }
        for id in library.favorites { if let ep = library.episodes[id] { add(ep.podcastID, weight: 4) } }
        for (id, progress) in library.progress {
            guard let ep = library.episodes[id], let date = progress.lastPlayed else { continue }
            let days = max(0, now.timeIntervalSince(date) / 86400)
            add(ep.podcastID, weight: 2 * exp(-days / 14) * (1 + log1p(Double(min(20, progress.playCount ?? 0)))))
        }
        return interests
    }
    public static func ranked(_ candidates: [Podcast], library: LibraryState, filter: ContentFilter, limit: Int = 12) -> [Podcast] {
        let profile = interests(library: library, now: filter.now)
        var seen = Set<String>()
        var pool = candidates.filter { seen.insert($0.id).inserted && !library.subscriptions.contains($0.id) && filter.evaluate(show: $0).decision == .allow }
        var output: [Podcast] = []; var publisherCounts: [String:Int] = [:]; var categoryCounts: [String:Int] = [:]
        func publisher(_ p: Podcast) -> String { p.publisherIdentities?.first(where: { $0.id != nil }).map { $0.namespace + ":" + $0.id! } ?? IdentityName.normalize(p.author) }
        let categoryKeys = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, categories(for: $0)) })
        let publisherKeys = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, publisher($0)) })
        while !pool.isEmpty && output.count < limit {
            var ranked: [(Podcast, Double)] = []
            for p in pool {
                let keys = categoryKeys[p.id, default: []]
                var interest = 0.0; var categoryPenalty = 0.0
                for key in keys { interest += profile[key, default: 0]; categoryPenalty += Double(categoryCounts[key, default: 0]) * 1.5 }
                let publisherPenalty = Double(publisherCounts[publisherKeys[p.id, default: ""], default: 0]) * 3
                ranked.append((p, interest - categoryPenalty - publisherPenalty))
            }
            ranked.sort { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1 }
            guard let chosen = ranked.first(where: { let id = publisherKeys[$0.0.id, default: ""]; return id.isEmpty || publisherCounts[id, default: 0] < 2 })?.0 else { break }
            output.append(chosen); publisherCounts[publisherKeys[chosen.id, default: ""], default: 0] += 1
            for key in categoryKeys[chosen.id, default: []] { categoryCounts[key, default: 0] += 1 }
            pool.removeAll { $0.id == chosen.id }
        }
        return output
    }
}

public enum DiscoveryPresentation {
    public static func entries(_ section: DiscoverySection, feeds: [String: CachedDiscoveryFeed], filter: ContentFilter) -> [DiscoveryEntry] {
        if let key = section.categoryKey, let category = PodcastCategories.category(key), !filter.isCategoryAllowed(category) { return [] }
        var seen = Set<String>()
        return section.entries.filter { entry in
            guard seen.insert(entry.id).inserted, let feed = feeds[entry.showID]?.feed else { return false }
            let episode = entry.episodeID.flatMap { id in feed.episodes.first { $0.id == id } }
            guard entry.episodeID == nil || episode != nil else { return false }
            return filter.evaluate(show: feed.podcast, episode: episode).decision == .allow
        }
    }
}

public struct DiscoveryLoad: Sendable { public var snapshot: DiscoverySnapshot; public var error: String?; public var fromCache: Bool }
public actor DiscoveryService {
    public static let dailyTTL: TimeInterval = 86400
    private let directory: DirectoryClient
    private let rss: FeedClient
    private let charts: PublicChartsClient
    private let categoryDirectory: DirectoryClient
    private let categoryRSS: FeedClient
    private let categoryCharts: PublicChartsClient
    private let disk: DiscoveryCacheStore
    private var cache: DiscoverySnapshot
    private var loaded = false
    private var attempts: [String: Date] = [:]
    private let candidateLimit: Int
    public init(http: HTTPClient, interactiveHTTP: HTTPClient? = nil, cacheURL: URL, candidateLimit: Int = 8) {
        self.candidateLimit = min(40, max(4, candidateLimit))
        directory = DirectoryClient(http: http); rss = FeedClient(http: http); charts = PublicChartsClient(http: http)
        let interactive = interactiveHTTP ?? http
        categoryDirectory = DirectoryClient(http: interactive); categoryRSS = FeedClient(http: interactive); categoryCharts = PublicChartsClient(http: interactive)
        disk = DiscoveryCacheStore(url: cacheURL); cache = DiscoverySnapshot()
    }
    public static func key(_ kind: DiscoveryKind, country: String, category: PodcastCategory? = nil) -> String { country.uppercased() + ":" + kind.rawValue + ":" + (category?.id ?? "all") }
    private func ensureLoaded() {
        guard !loaded else { return }; loaded = true
        cache = (try? disk.load()) ?? DiscoverySnapshot()
    }
    public func cached() -> DiscoverySnapshot { ensureLoaded(); return cache }
    public func load(_ kind: DiscoveryKind, category: PodcastCategory? = nil, library: LibraryState, filter: ContentFilter, country: String = "CN", force: Bool = false, onUpdate: (@Sendable (DiscoveryLoad) async -> Void)? = nil) async -> DiscoveryLoad {
        ensureLoaded()
        if kind == .category, let category { return await loadCategory(category, library: library, filter: filter, country: country, force: force, onUpdate: onUpdate) }
        let key = Self.key(kind, country: country, category: category)
        if let previous = cache.sections[key], !force && CacheFreshness.isFresh(previous.generatedAt, ttl: Self.dailyTTL) {
            return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true)
        }
        if let last = attempts[key], Date().timeIntervalSince(last) < 60 { return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true) }
        attempts[key] = Date()
        do {
            try Task.checkCancellation()
            if let category, !filter.isCategoryAllowed(category) { return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true) }
            var chart: PublicChart?
            var chartFailure: Error?
            var supplementWarning: String?
            if kind == .topShows || kind == .topEpisodes || (kind == .category && category?.appleID != nil) {
                do { chart = try await charts.chart(country: country, episodes: kind == .topEpisodes, categoryID: category?.appleID, force: force) }
                catch { chartFailure = error; if cache.sections[key] != nil { throw error } }
            }
            var candidates: [Podcast] = []
            var entries: [DiscoveryEntry] = []
            var origin: DiscoveryOrigin = .directoryDiscovery
            var sourceURL: URL?; var sourceTitle: String?
            var title = kind == .newShows ? "发现新节目" : kind == .personalized ? "你可能喜欢" : "播客发现"
            if let selectedChart = chart {
              do {
                let chart = selectedChart
                let refs = Array(chart.references.prefix(candidateLimit))
                let shows = try await directory.lookupMany(refs.map(\.showDirectoryID), country: country)
                let episodeIdentities = kind == .topEpisodes ? try await directory.lookupEpisodeIdentities(refs.map(\.showDirectoryID), country: country) : [:]
                let feeds = try await hydrate(shows, force: force)
                var byDirectoryID: [String: String] = [:]
                for show in shows { if let url = show.directoryURL, case .directoryID(let id) = try? ExternalLink.resolve(url) { byDirectoryID[id] = show.id } }
                for reference in refs {
                    guard let feedID = byDirectoryID[reference.showDirectoryID], let feed = feeds.first(where: { $0.podcast.id == feedID }) else { continue }
                    let ep = kind == .topEpisodes ? PublicChartsClient.resolveEpisode(reference, in: feed, identity: reference.episodeDirectoryID.flatMap { episodeIdentities[reference.showDirectoryID + ":" + $0] }) : nil
                    if kind == .topEpisodes && ep == nil { continue }
                    guard filter.evaluate(show: feed.podcast, episode: ep).decision == .allow else { continue }
                    entries.append(DiscoveryEntry(showID: feedID, episodeID: ep?.id, rank: reference.rank))
                    if let ep { remember(feed, extra: ep, fetchedAt: cache.feeds[feedID]?.fetchedAt ?? Date()) }
                }
                candidates = feeds.map(\.podcast)
                origin = kind == .topEpisodes ? .appleEpisodesChart : kind == .category ? .appleCategoryChart : .appleShowsChart
                title = kind == .topEpisodes ? "热门单集" : kind == .category ? "\(category?.title ?? "分类") · 分类榜" : "热门播客"
                sourceURL = chart.url; sourceTitle = chart.title
              } catch {
                if cache.sections[key] != nil { throw error }
                chartFailure = error; chart = nil; entries = []
              }
            }
            if chart == nil || entries.count < 8 {
              do {
                let interest = LocalRecommender.interests(library: library).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                let picks = interest.compactMap { PodcastCategories.category($0.key) }.filter { filter.isCategoryAllowed($0) }
                let available = PodcastCategories.featured.filter { filter.isCategoryAllowed($0) }
                let day = Int(Date().timeIntervalSince1970 / 86400)
                let seed = category ?? (kind == .personalized ? picks.first : nil) ?? (available.isEmpty ? nil : available[day % available.count])
                let query = seed?.title ?? "访谈"
                let shows = try await directory.search(query, country: country)
                let feeds = try await hydrate(shows, force: false)
                candidates += feeds.map(\.podcast)
                if chart == nil {
                    if kind == .topEpisodes { origin = .directoryEpisodes; title = "新近单集" }
                    else if kind == .personalized { origin = .localRecommendation }
                    else { origin = .directoryDiscovery; if kind == .category { title = "\(category?.title ?? "分类") · 目录发现" } }
                    if kind == .personalized {
                        entries = LocalRecommender.ranked(candidates + cache.feeds.values.map { $0.feed.podcast }, library: library, filter: filter).map { DiscoveryEntry(showID: $0.id) }
                    } else {
                        entries = feeds.filter { feed in filter.evaluate(show: feed.podcast).decision == .allow && (kind != .newShows || (!library.subscriptions.contains(feed.podcast.id) && !library.progress.keys.contains { library.episodes[$0]?.podcastID == feed.podcast.id })) }.compactMap { feed in
                            let ep = origin == .directoryEpisodes ? feed.episodes.first : nil
                            guard origin != .directoryEpisodes || ep != nil else { return nil }
                            return DiscoveryEntry(showID: feed.podcast.id, episodeID: ep?.id)
                        }
                    }
                }
                if chart != nil && entries.count < 8 {
                    let existing = Set(entries.map(\.showID))
                    let additional = feeds.filter { !existing.contains($0.podcast.id) && filter.evaluate(show: $0.podcast).decision == .allow }
                    let supplementKey = country.uppercased() + ":supplement:all"
                    if !additional.isEmpty {
                        cache.sections[supplementKey] = DiscoverySection(id: supplementKey, kind: .newShows, title: "更多播客发现", origin: .directoryDiscovery, country: country, generatedAt: Date(), entries: additional.prefix(12).map { DiscoveryEntry(showID: $0.podcast.id) })
                    }
                }
                // Extra candidates never acquire a claimed official rank.
              } catch {
                if chart == nil || Task.isCancelled { throw error }
                supplementWarning = "补充目录发现暂不可用，仍显示已取得的真实榜单。"
              }
            }
            if let category {
                entries = entries.filter { entry in guard let show = cache.feeds[entry.showID]?.feed.podcast else { return false }; return LocalRecommender.categories(for: show).contains(category.id) || (show.classificationObservations ?? []).flatMap(PodcastCategories.matching).contains { $0.path.starts(with: category.path) } }
            }
            var seen = Set<String>(); entries = entries.filter { seen.insert($0.id).inserted }
            let section = DiscoverySection(id: key, kind: kind, title: title, origin: origin, sourceURL: sourceURL, sourceTitle: sourceTitle, country: country, generatedAt: Date(), entries: Array(entries.prefix(30)), categoryKey: category?.id)
            cache.sections[key] = section; prune(); cache.revision = (cache.revision ?? 0) &+ 1; try disk.save(cache)
            return DiscoveryLoad(snapshot: cache, error: chartFailure.map { "公开榜单暂不可用，显示目录发现：\($0.localizedDescription)" } ?? supplementWarning, fromCache: false)
        } catch {
            return DiscoveryLoad(snapshot: cache, error: "更新失败，保留上次有效内容：\(error.localizedDescription)", fromCache: true)
        }
    }
    private func matches(_ show: Podcast, category: PodcastCategory) -> Bool {
        LocalRecommender.categories(for: show).contains(category.id) || (show.classificationObservations ?? []).flatMap(PodcastCategories.matching).contains { $0.path.starts(with: category.path) }
    }
    private func loadCategory(_ category: PodcastCategory, library: LibraryState, filter: ContentFilter, country: String, force: Bool, onUpdate: (@Sendable (DiscoveryLoad) async -> Void)?) async -> DiscoveryLoad {
        let key = Self.key(.category, country: country, category: category)
        guard filter.isCategoryAllowed(category) else { return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true) }
        if let previous = cache.sections[key], previous.origin != .localLibrary, previous.isPartial != true, !force, CacheFreshness.isFresh(previous.generatedAt, ttl: Self.dailyTTL) {
            return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true)
        }
        // Reuse already verified RSS immediately, including shows loaded through search/details.
        if cache.sections[key] == nil {
            var known = cache.feeds.mapValues(\.feed)
            let grouped = Dictionary(grouping: library.episodes.values, by: \.podcastID)
            for show in library.podcasts.values where show.hasRSSMetadata && matches(show, category: category) {
                if let cached = known[show.id], (cached.podcast.rssFetchedAt ?? .distantPast) > (show.rssFetchedAt ?? .distantPast) { continue }
                known[show.id] = Feed(podcast: show, episodes: Array((grouped[show.id] ?? []).sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }.prefix(24)))
            }
            let eligible = known.values.filter { matches($0.podcast, category: category) && filter.evaluate(show: $0.podcast).decision == .allow }
                .sorted { $0.podcast.title.localizedStandardCompare($1.podcast.title) == .orderedAscending }.prefix(12)
            if !eligible.isEmpty {
                for feed in eligible { remember(feed, fetchedAt: feed.podcast.rssFetchedAt ?? .distantPast) }
                cache.sections[key] = DiscoverySection(id: key, kind: .category, title: category.title, origin: .localLibrary, country: country, generatedAt: Date(), entries: eligible.map { DiscoveryEntry(showID: $0.podcast.id) }, categoryKey: category.id)
                cache.revision = (cache.revision ?? 0) &+ 1
                await onUpdate?(DiscoveryLoad(snapshot: cache, error: nil, fromCache: true))
            }
        }
        if let last = attempts[key], Date().timeIntervalSince(last) < 60 { return DiscoveryLoad(snapshot: cache, error: nil, fromCache: true) }
        attempts[key] = Date()
        do {
            try Task.checkCancellation()
            var chart: PublicChart?
            do { if category.appleID != nil { chart = try await categoryCharts.chart(country: country, categoryID: category.appleID, force: force) } }
            catch { if cache.sections[key]?.origin == .appleCategoryChart { throw error } }
            let shows: [Podcast]
            if let chart { shows = try await categoryDirectory.lookupMany(Array(chart.references.prefix(candidateLimit)).map(\.showDirectoryID), country: country) }
            else { shows = try await categoryDirectory.search(category.title, country: country, timeout: 6, retries: 0) }
            var seen = Set<String>()
            let candidates = Array(shows.filter { seen.insert($0.id).inserted }.prefix(candidateLimit))
            var ranks: [String: Int] = [:]
            for show in candidates {
                if let url = show.directoryURL, case .directoryID(let id) = try? ExternalLink.resolve(url), let rank = chart?.references.first(where: { $0.showDirectoryID == id })?.rank { ranks[show.id] = rank }
            }
            let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.id, $0.offset) })
            var feeds: [Feed] = [], missing: [Podcast] = []
            for show in candidates {
                if let old = cache.feeds[show.id], !force, CacheFreshness.isFresh(old.fetchedAt, ttl: Self.dailyTTL) {
                    var feed = old.feed
                    if let current = library.podcasts[show.id], (current.rssFetchedAt ?? .distantPast) > (feed.podcast.rssFetchedAt ?? .distantPast) { feed.podcast = current }
                    feed.podcast = feed.podcast.mergingDirectoryMetadata(from: show)
                    feeds.append(feed); remember(feed, fetchedAt: old.fetchedAt)
                } else { missing.append(show) }
            }
            await publishCategory(feeds, category: category, country: country, chart: chart, ranks: ranks, order: order, filter: filter, onUpdate: onUpdate)
            await withTaskGroup(of: Feed?.self) { group in
                var remaining = missing.makeIterator()
                func enqueue(_ show: Podcast) {
                    group.addTask { [rss = categoryRSS] in
                        guard var feed = try? await rss.fetch(show.feedURL, force: force, timeout: 6, retries: 0) else { return nil }
                        feed.podcast = feed.podcast.mergingDirectoryMetadata(from: show); return feed
                    }
                }
                for _ in 0..<4 { if let show = remaining.next() { enqueue(show) } }
                for await feed in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    if let show = remaining.next() { enqueue(show) }
                    guard let feed else { continue }
                    remember(feed); feeds.append(feed)
                    await publishCategory(feeds, category: category, country: country, chart: chart, ranks: ranks, order: order, filter: filter, onUpdate: onUpdate)
                }
            }
            try Task.checkCancellation()
            if feeds.isEmpty && !candidates.isEmpty { throw PodcastError.invalidFeed("暂时无法读取新节目，已保留可用缓存") }
            if cache.sections[key] == nil {
                cache.sections[key] = DiscoverySection(id: key, kind: .category, title: category.title, origin: chart == nil ? .directoryDiscovery : .appleCategoryChart, country: country, generatedAt: Date(), entries: [], categoryKey: category.id)
                cache.revision = (cache.revision ?? 0) &+ 1
            }
            if cache.sections[key]?.isPartial == true {
                cache.sections[key]?.isPartial = false
                cache.revision = (cache.revision ?? 0) &+ 1
            }
            prune(); try disk.save(cache)
            return DiscoveryLoad(snapshot: cache, error: nil, fromCache: cache.sections[key]?.origin == .localLibrary)
        } catch {
            if Task.isCancelled { attempts[key] = nil }
            try? disk.save(cache)
            return DiscoveryLoad(snapshot: cache, error: "更新失败，保留可用内容：\(error.localizedDescription)", fromCache: true)
        }
    }
    private func publishCategory(_ feeds: [Feed], category: PodcastCategory, country: String, chart: PublicChart?, ranks: [String: Int], order: [String: Int], filter: ContentFilter, onUpdate: (@Sendable (DiscoveryLoad) async -> Void)?) async {
        let entries = feeds.filter { matches($0.podcast, category: category) && filter.evaluate(show: $0.podcast).decision == .allow && (chart == nil || ranks[$0.podcast.id] != nil) }
            .map { DiscoveryEntry(showID: $0.podcast.id, rank: ranks[$0.podcast.id]) }
            .sorted { ($0.rank ?? order[$0.showID, default: 0]) < ($1.rank ?? order[$1.showID, default: 0]) }
        guard !entries.isEmpty else { return }
        let key = Self.key(.category, country: country, category: category)
        cache.sections[key] = DiscoverySection(id: key, kind: .category, title: category.title, origin: chart == nil ? .directoryDiscovery : .appleCategoryChart, sourceURL: chart?.url, sourceTitle: chart?.title, country: country, generatedAt: Date(), entries: entries, categoryKey: category.id)
        cache.sections[key]?.isPartial = true
        cache.revision = (cache.revision ?? 0) &+ 1
        await onUpdate?(DiscoveryLoad(snapshot: cache, error: nil, fromCache: false))
    }
    private func hydrate(_ shows: [Podcast], force: Bool) async throws -> [Feed] {
        var output: [Feed] = []
        var seen = Set<String>(); let unique = Array(shows.filter { seen.insert($0.id).inserted }.prefix(candidateLimit))
        for start in stride(from: 0, to: unique.count, by: 4) {
            try Task.checkCancellation()
            let chunk = Array(unique[start..<min(start + 4, unique.count)])
            var missing: [Podcast] = []
            for show in chunk {
                if let cached = cache.feeds[show.id], !force, CacheFreshness.isFresh(cached.fetchedAt, ttl: Self.dailyTTL) {
                    var feed = cached.feed; feed.podcast = feed.podcast.mergingDirectoryMetadata(from: show); output.append(feed); remember(feed, fetchedAt: cached.fetchedAt)
                } else { missing.append(show) }
            }
            let loaded = await withTaskGroup(of: Feed?.self) { group in
                for show in missing {
                    group.addTask { [rss] in
                        guard var feed = try? await rss.fetch(show.feedURL, force: force, timeout: 6, retries: 0) else { return nil }
                        feed.podcast = feed.podcast.mergingDirectoryMetadata(from: show); return feed
                    }
                }
                var values: [Feed] = []; for await feed in group { if let feed { values.append(feed) } }; return values
            }
            for feed in loaded { remember(feed) }; output += loaded
            for show in missing where !loaded.contains(where: { $0.podcast.id == show.id }) {
                if let old = cache.feeds[show.id] {
                    var fallback = old.feed
                    fallback.podcast = fallback.podcast.mergingDirectoryMetadata(from: show)
                    remember(fallback, fetchedAt: old.fetchedAt); output.append(fallback)
                }
            }
        }
        if output.isEmpty && !unique.isEmpty { throw PodcastError.invalidFeed("暂时无法读取节目的 RSS，请稍后重试或更换目录地区") }
        return output
    }
    private func remember(_ feed: Feed, extra: Episode? = nil, fetchedAt: Date = Date()) {
        var compact = feed; compact.episodes = Array(feed.episodes.prefix(24))
        let previousExtras = cache.feeds[feed.podcast.id]?.feed.episodes.filter { old in !compact.episodes.contains { $0.id == old.id } } ?? []
        for episode in previousExtras + (extra.map { [$0] } ?? []) where !compact.episodes.contains(where: { $0.id == episode.id }) { compact.episodes.append(episode) }
        compact.episodes = Array(compact.episodes.prefix(64))
        cache.feeds[feed.podcast.id] = CachedDiscoveryFeed(feed: compact, fetchedAt: fetchedAt)
    }
    private func prune() {
        let staleSections = cache.sections.sorted { $0.value.generatedAt < $1.value.generatedAt }
        for (id,_) in staleSections.prefix(max(0,cache.sections.count - 40)) { cache.sections.removeValue(forKey: id) }
        let oldest = cache.feeds.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
        let removed = Set(oldest.prefix(max(0,cache.feeds.count - 160)).map(\.key))
        for id in removed { cache.feeds.removeValue(forKey: id) }
        if !removed.isEmpty {
            for id in cache.sections.keys {
                if cache.sections[id]!.entries.contains(where: { removed.contains($0.showID) }) {
                    cache.sections[id]?.entries.removeAll { removed.contains($0.showID) }
                    cache.sections[id]?.generatedAt = .distantPast
                }
            }
        }
    }
}
