import PodcastModels
import ContentFiltering
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 45
            c.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 32_000_000)
            self.session = URLSession(configuration: c)
        }
    }
    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PodcastError.http(0) }
        return (data, response)
    }
}
public actor HTTPClient {
    private struct CacheEntry { let data: Data; let expires: Date }
    private var cache: [URL: CacheEntry] = [:]
    private var nextDirectoryRequest = Date.distantPast
    private let transport: any HTTPTransport
    private let directoryInterval: TimeInterval
    private let defaultTimeout: TimeInterval
    private let defaultRetries: Int
    public init(transport: any HTTPTransport = URLSessionTransport(), directoryInterval: TimeInterval = 3.2, defaultTimeout: TimeInterval = 20, defaultRetries: Int = 1) {
        self.transport = transport; self.directoryInterval = directoryInterval
        self.defaultTimeout = defaultTimeout; self.defaultRetries = defaultRetries
    }
    public func get(_ url: URL, directory: Bool = false, force: Bool = false, timeout: TimeInterval? = nil, retries: Int? = nil) async throws -> Data {
        _ = try PublicURL.validate(url)
        if !force, let value = cache[url], value.expires > Date() { return value.data }
        let retryCount = min(1, max(0, retries ?? defaultRetries))
        for attempt in 0...retryCount {
            try Task.checkCancellation()
            if directory {
                // Reserve only when actually sending. Cancelled searches must not leave future slots occupied.
                while nextDirectoryRequest > Date() {
                    let delay = nextDirectoryRequest.timeIntervalSinceNow
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    try Task.checkCancellation()
                }
                nextDirectoryRequest = Date().addingTimeInterval(directoryInterval)
            }
            var request = URLRequest(url: url, cachePolicy: force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: timeout ?? defaultTimeout)
            request.setValue("QuietCast/1.0 (podcast RSS client)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await transport.fetch(request)
                if response.statusCode == 429 || response.statusCode >= 500 {
                    if attempt < retryCount {
                        let delay = min(30, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); continue
                    }
                }
                guard (200..<300).contains(response.statusCode) else { throw PodcastError.http(response.statusCode) }
                guard data.count <= 8 * 1024 * 1024 else { throw PodcastError.oversized }
                if cache.count >= 64 { cache.removeValue(forKey: cache.min { $0.value.expires < $1.value.expires }!.key) }
                cache[url] = CacheEntry(data: data, expires: Date().addingTimeInterval(directory ? 600 : 300))
                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let error = error as? URLError, [.timedOut,.networkConnectionLost,.cannotConnectToHost,.notConnectedToInternet].contains(error.code), attempt < retryCount {
                    try await Task.sleep(nanoseconds: 500_000_000); continue
                }
                throw error
            }
        }
        throw PodcastError.http(503)
    }
}

public struct DirectoryClient: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }
    private struct Response: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let collectionName: String?; let trackName: String?; let artistName: String?
        let feedUrl: String?; let artworkUrl600: String?; let collectionViewUrl: String?; let genres: [String]?
        let genreIds: [FlexibleID]?; let artistId: FlexibleID?; let primaryGenreName: String?
    }
    private struct FlexibleID: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s } else { value = String(try c.decode(Int64.self)) }
        }
    }
    public func search(_ term: String, country: String = "CN", timeout: TimeInterval? = nil, retries: Int? = nil) async throws -> [Podcast] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: trimmed), .init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"), .init(name: "country", value: country), .init(name: "limit", value: "20"), .init(name: "version", value: "2")]
        return try await results(c.url!, source: .appleSearch, timeout: timeout, retries: retries)
    }
    public func lookup(_ id: String, country: String = "CN") async throws -> Podcast {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw PodcastError.invalidURL }
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [.init(name: "id", value: id), .init(name: "entity", value: "podcast"), .init(name: "country", value: country)]
        guard let show = try await results(c.url!, source: .appleLookup).first else { throw PodcastError.invalidFeed("目录中未找到节目") }
        return show
    }
    public func lookupMany(_ ids: [String], country: String = "CN") async throws -> [Podcast] {
        let clean = Array(Set(ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) })).sorted()
        guard !clean.isEmpty else { return [] }
        var all: [Podcast] = []
        for offset in stride(from: 0, to: clean.count, by: 40) {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = [.init(name: "id", value: clean[offset..<min(offset + 40, clean.count)].joined(separator: ",")), .init(name: "entity", value: "podcast"), .init(name: "country", value: country)]
            all += try await results(c.url!, source: .appleLookup)
        }
        return all
    }
    public func lookupEpisodeIdentities(_ ids: [String], country: String = "CN") async throws -> [String: DirectoryEpisodeIdentity] {
        struct Response: Decodable { let results: [Row] }
        struct Row: Decodable { let kind: String?; let trackId: FlexibleID?; let collectionId: FlexibleID?; let episodeGuid: String?; let episodeUrl: URL? }
        let clean = Array(Set(ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) })).sorted()
        var output: [String: DirectoryEpisodeIdentity] = [:]
        for offset in stride(from: 0, to: clean.count, by: 8) {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = [.init(name: "id", value: clean[offset..<min(offset + 8, clean.count)].joined(separator: ",")), .init(name: "entity", value: "podcastEpisode"), .init(name: "limit", value: "100"), .init(name: "country", value: country)]
            let rows = try JSONDecoder().decode(Response.self, from: await http.get(c.url!, directory: true)).results
            for row in rows where row.kind == "podcast-episode" {
                guard let showID = row.collectionId?.value, let episodeID = row.trackId?.value else { continue }
                let identity = DirectoryEpisodeIdentity(showDirectoryID: showID, episodeDirectoryID: episodeID, guid: row.episodeGuid, audioURL: row.episodeUrl, sourceURL: c.url!)
                output[showID + ":" + episodeID] = identity
            }
        }
        return output
    }
    private func results(_ url: URL, source: MetadataSource, timeout: TimeInterval? = nil, retries: Int? = nil) async throws -> [Podcast] {
        let response = try JSONDecoder().decode(Response.self, from: await http.get(url, directory: true, timeout: timeout, retries: retries))
        var seen = Set<String>()
        return response.results.compactMap { item in
            guard let feed = item.feedUrl, let url = try? PublicURL.parse(feed) else { return nil }
            var p = Podcast(feedURL: url, title: item.collectionName ?? item.trackName ?? "未命名节目", author: item.artistName ?? "", categories: item.genres ?? [], artworkURL: nil, directoryURL: item.collectionViewUrl.flatMap(URL.init(string:)))
            p.directoryTitle = p.title
            let ids = item.genreIds?.map(\.value) ?? []
            let names = item.genres ?? []
            p.classificationObservations = ids.enumerated().map { index, id in
                let name = ids.count == names.count ? names[index] : ""
                return ClassificationObservation(namespace: "apple.podcasts.genre", id: id, name: name, primary: item.primaryGenreName.map { $0 == name }, source: source, sourceURL: url)
            }
            if ids.isEmpty { p.classificationObservations = names.map { name in ClassificationObservation(namespace: "apple.podcasts.genre", name: name, primary: item.primaryGenreName.map { $0 == name }, source: source, sourceURL: url) } }
            if item.artistId != nil || item.artistName != nil {
                p.publisherIdentities = [PublisherIdentity(namespace: "apple.podcasts.artist", id: item.artistId?.value, name: item.artistName ?? "", source: source, sourceURL: url)]
            }
            // Artwork is obtained from the publisher RSS after loading details, not reused as a detached iTunes asset.
            return seen.insert(p.id).inserted ? p : nil
        }
    }
}

public struct FeedClient: Sendable {
    public let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }
    public func fetch(_ url: URL, force: Bool = false, timeout: TimeInterval = 20, retries: Int = 1) async throws -> Feed {
        try RSSParser.parse(await http.get(url, force: force, timeout: timeout, retries: retries), feedURL: url)
    }
}

public enum ExternalLink: Equatable, Sendable {
    case rss(URL), directoryID(String)
    public static func resolve(_ url: URL) throws -> ExternalLink {
        if url.scheme?.lowercased() == "quietcast" {
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard url.host == "feed", let text = c?.queryItems?.first(where: { $0.name == "url" })?.value else { throw PodcastError.invalidURL }
            return try resolve(PublicURL.parse(text))
        }
        _ = try PublicURL.validate(url)
        if url.host?.lowercased() == "podcasts.apple.com" || url.host?.lowercased() == "itunes.apple.com" {
            guard let part = url.pathComponents.last(where: { $0.hasPrefix("id") }), part.dropFirst(2).allSatisfy(\.isNumber), part.count > 2 else { throw PodcastError.invalidURL }
            return .directoryID(String(part.dropFirst(2)))
        }
        guard !["mp3","m4a","mp4","aac","wav"].contains(url.pathExtension.lowercased()) else { throw PodcastError.invalidURL }
        return .rss(url)
    }
}

public struct DirectoryEpisodeIdentity: Sendable {
    public let showDirectoryID: String
    public let episodeDirectoryID: String
    public let guid: String?
    public let audioURL: URL?
    public let sourceURL: URL
}
