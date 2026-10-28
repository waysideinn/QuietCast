import Foundation
import CryptoKit

public enum Identity {
    public static func feed(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        return c.url?.absoluteString ?? url.absoluteString
    }
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct Podcast: Codable, Identifiable, Equatable, Sendable {
    public var id: String { Identity.feed(feedURL) }
    public var feedURL: URL
    public var title: String
    public var author: String
    public var summary: String
    public var categories: [String]
    public var artworkURL: URL?
    public var directoryURL: URL?
    public var metadata: String
    public var rssFetchedAt: Date?
    public var directoryTitle: String?
    public var classificationObservations: [ClassificationObservation]?
    public var publisherIdentities: [PublisherIdentity]?
    public var hasRSSMetadata: Bool
    public init(feedURL: URL, title: String, author: String = "", summary: String = "", categories: [String] = [], artworkURL: URL? = nil, directoryURL: URL? = nil, metadata: String = "", hasRSSMetadata: Bool = false, classificationObservations: [ClassificationObservation]? = nil, publisherIdentities: [PublisherIdentity]? = nil, rssFetchedAt: Date? = nil, directoryTitle: String? = nil) {
        self.feedURL = feedURL; self.title = title; self.author = author; self.summary = summary
        self.categories = categories; self.artworkURL = artworkURL; self.directoryURL = directoryURL
        self.metadata = metadata; self.hasRSSMetadata = hasRSSMetadata
        self.classificationObservations = classificationObservations; self.publisherIdentities = publisherIdentities
        self.rssFetchedAt = rssFetchedAt; self.directoryTitle = directoryTitle
    }
}

public struct Episode: Codable, Identifiable, Equatable, Sendable {
    public var id: String { Identity.hash(podcastID + "\n" + guid) }
    public var podcastID: String
    public var guid: String
    public var title: String
    public var summary: String
    public var audioURL: URL
    public var artworkURL: URL?
    public var published: Date?
    public var duration: Double?
    public var metadata: String
    public init(podcastID: String, guid: String, title: String, summary: String = "", audioURL: URL, artworkURL: URL? = nil, published: Date? = nil, duration: Double? = nil, metadata: String = "") {
        self.podcastID = podcastID; self.guid = guid; self.title = title; self.summary = summary
        self.audioURL = audioURL; self.artworkURL = artworkURL; self.published = published
        self.duration = duration; self.metadata = metadata
    }
}

public struct Feed: Codable, Equatable, Sendable {
    public var podcast: Podcast
    public var episodes: [Episode]
    public init(podcast: Podcast, episodes: [Episode]) { self.podcast = podcast; self.episodes = episodes }
}

public struct EpisodeProgress: Codable, Equatable, Sendable {
    public var position: Double = 0
    public var duration: Double = 0
    public var completed: Bool = false
    public var playCount: Int?
    public var lastPlayed: Date?
    public init(position: Double = 0, duration: Double = 0, completed: Bool = false, lastPlayed: Date? = nil, playCount: Int? = nil) {
        self.position = position; self.duration = duration; self.completed = completed; self.lastPlayed = lastPlayed; self.playCount = playCount
    }
}

public struct PlayerPreferences: Codable, Equatable, Sendable {
    public var speed: Float = 1
    public var forwardSeconds: Double = 30
    public var backwardSeconds: Double = 15
    public var continuous: Bool = true
    public var downloadLimitGB: Int = 3
    public init() {}
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var version = 1
    public var podcasts: [String: Podcast] = [:]
    public var episodes: [String: Episode] = [:]
    public var subscriptions: Set<String> = []
    public var favorites: Set<String> = []
    public var progress: [String: EpisodeProgress] = [:]
    public var queue: [String] = []
    public var subscriptionRefreshAttemptAt: Date?
    public var subscriptionRefreshedAt: Date?
    public var currentEpisodeID: String?
    public var searchHistory: [String] = []
    public var preferences = PlayerPreferences()
    public init() {}
    public mutating func merge(_ feed: Feed) {
        let previous = podcasts[feed.podcast.id]
        let older = previous?.hasRSSMetadata == true && (!feed.podcast.hasRSSMetadata || (previous?.rssFetchedAt ?? .distantPast) > (feed.podcast.rssFetchedAt ?? .distantPast))
        let base = older ? previous! : feed.podcast
        podcasts[feed.podcast.id] = base.mergingDirectoryMetadata(from: older ? feed.podcast : previous)
        for ep in feed.episodes where !older || episodes[ep.id] == nil { episodes[ep.id] = ep }
    }
    public mutating func beginPlayback(episodeID: String, now: Date = Date()) {
        guard episodes[episodeID] != nil else { return }
        var p = progress[episodeID] ?? EpisodeProgress()
        p.playCount = min(10_000, (p.playCount ?? 0) + 1); p.lastPlayed = now; progress[episodeID] = p
    }
    public mutating func record(episodeID: String, position: Double, duration: Double, finished: Bool = false, now: Date = Date()) {
        guard episodes[episodeID] != nil, position.isFinite, position >= 0 else { return }
        var p = progress[episodeID] ?? EpisodeProgress()
        p.duration = duration.isFinite && duration > 0 ? duration : p.duration
        p.position = p.duration > 0 ? min(position, p.duration) : position
        p.completed = finished || p.completed || (p.duration > 0 && p.position / p.duration >= 0.98)
        p.lastPlayed = now
        progress[episodeID] = p
    }
}

public enum PodcastError: LocalizedError, Equatable {
    case invalidURL, invalidFeed(String), http(Int), oversized, blocked(String), storage(String), rule(String), pin(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的公开 HTTPS 或 HTTP RSS 地址。"
        case .invalidFeed(let detail): return "RSS 无法解析：\(detail)"
        case .http(let status): return "服务器返回 HTTP \(status)，请稍后重试。"
        case .oversized: return "数据超出允许大小。"
        case .blocked(let reason): return "内容需要家长授权：\(reason)"
        case .storage(let reason): return "无法保存数据：\(reason)"
        case .rule(let reason): return "规则无效：\(reason)"
        case .pin(let reason): return reason
        }
    }
}

public enum PublicURL {
    public static func validate(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw PodcastError.invalidURL }
        return url
    }
    public static func parse(_ string: String) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PodcastError.invalidURL }
        return try validate(url)
    }
}
