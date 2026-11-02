import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

actor RegionalSearchTransport: HTTPTransport {
    let failCountry: String?
    var requests: [URLRequest] = []
    var dates: [Date] = []
    init(failCountry: String? = nil) { self.failCountry = failCountry }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request); dates.append(Date())
        let url = request.url!
        let country = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value ?? "CN"
        if country == failCountry { throw URLError(.timedOut) }
        // One common RSS across all stores, plus two homonymous but distinct RSS feeds.
        let ids = country == "CN" ? ["shared", "cn"] : country == "HK" ? ["shared", "hk"] : ["shared", "us"]
        let body = try JSONSerialization.data(withJSONObject: ["results": ids.map { ["collectionName": "同名科学节目", "feedUrl": "https://search.example/\($0)", "genres": ["Science"]] as [String: Any] }])
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SearchUpdates {
    var values: [UnifiedSearchResult] = []
    func append(_ value: UnifiedSearchResult) { values.append(value) }
}

private actor CategoryUpdates {
    var values: [DiscoveryLoad] = []
    func append(_ value: DiscoveryLoad) { values.append(value) }
}

private actor GatedCategoryTransport: HTTPTransport {
    let base = DiscoveryTransport()
    var holdChart: Bool
    var holdSlowRSS: Bool
    var requests: [URLRequest] = []
    init(holdChart: Bool = false, holdSlowRSS: Bool = false) { self.holdChart = holdChart; self.holdSlowRSS = holdSlowRSS }
    func release() { holdChart = false; holdSlowRSS = false }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        while (holdChart && (url.host == "rss.marketingtools.apple.com" || url.path.contains("/rss/"))) || (holdSlowRSS && url.host == "feeds.example" && url.lastPathComponent == "4") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if url.path.contains("/rss/") {
            let entries = (1...4).map { id -> [String: Any] in
                ["id": ["attributes": ["im:id": "\(id)"], "label": "https://podcasts.apple.com/cn/podcast/test/id\(id)"], "im:name": ["label": "科学节目\(id)"]]
            }
            let body = try JSONSerialization.data(withJSONObject: ["feed": ["entry": entries, "title": ["label": "科学分类榜单"]]])
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return try await base.fetch(request)
    }
}

final class AcceptanceRegressionTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Acceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func filter(_ policy: ParentalPolicy = ParentalPolicy()) throws -> ContentFilter {
        ContentFilter(rules: try RulesLoader.decode(Data(contentsOf: Bundle.module.url(forResource: "example-multisource", withExtension: "json", subdirectory: "Fixtures")!)), policy: policy)
    }
    func testUnifiedSearchMergesStoresByRSSWithoutMergingHomonymsOrFetchingRSS() async throws {
        let transport = RegionalSearchTransport(), updates = SearchUpdates()
        let search = UnifiedDirectorySearch(directory: DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0)))
        let result = try await search.search("  科学  ") { await updates.append($0) }
        XCTAssertEqual(result.completedSources, 3); XCTAssertEqual(result.failedSources, 0)
        XCTAssertEqual(Set(result.shows.map(\.id)), Set(["shared", "cn", "hk", "us"].map { "https://search.example/" + $0 }))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3); XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/search" && $0.timeoutInterval == 8 })
        let batches = await updates.values
        XCTAssertEqual(batches.count, 3)
        for pair in zip(batches, batches.dropFirst()) { XCTAssertTrue(pair.1.shows.map(\.id).starts(with: pair.0.shows.map(\.id))) }
        for request in requests {
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value, "科学")
        }
    }
    func testUnavailableStoreStillLeavesResultsFromOtherStores() async throws {
        let transport = RegionalSearchTransport(failCountry: "US")
        let result = try await UnifiedDirectorySearch(directory: DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0))).search("科学")
        XCTAssertEqual(result.failedSources, 1); XCTAssertEqual(result.completedSources, 3); XCTAssertEqual(result.shows.count, 3)
    }
    func testAllSearchSourcesUnavailableReportsFailureInsteadOfNoResults() async throws {
        let transport = StubTransport([.timeout, .timeout, .timeout])
        do {
            _ = try await UnifiedDirectorySearch(directory: DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0))).search("科学")
            XCTFail("A total network failure cannot be presented as an empty successful search")
        } catch { XCTAssertTrue(error.localizedDescription.contains("搜索暂时无法连接")) }
        let count = await transport.count; XCTAssertEqual(count, 3)
    }
    func testCancelledSearchesDoNotReserveFutureDirectorySlotsAndRateLimitStillHolds() async throws {
        let transport = RegionalSearchTransport()
        let throttled = HTTPClient(transport: transport, directoryInterval: 0.1)
        _ = try await throttled.get(URL(string: "https://itunes.apple.com/search?term=first")!, directory: true)
        let cancelled = (0..<8).map { index in Task { try await throttled.get(URL(string: "https://itunes.apple.com/search?term=cancel\(index)")!, directory: true) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        for task in cancelled { task.cancel() }
        for task in cancelled { _ = try? await task.value }
        _ = try await throttled.get(URL(string: "https://itunes.apple.com/search?term=next")!, directory: true)
        let dates = await transport.dates, calls = await transport.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertGreaterThanOrEqual(dates[1].timeIntervalSince(dates[0]), 0.09)
        XCTAssertLessThan(dates[1].timeIntervalSince(dates[0]), 0.5, "Eight cancelled searches must not leave eight future slots")
    }
    func testCategoryPublishesFastRSSBeforeSlowRSSAndDoesNotRunSupplementalSearch() async throws {
        let transport = GatedCategoryTransport(holdSlowRSS: true), updates = CategoryUpdates()
        let service = DiscoveryService(http: HTTPClient(transport: transport, directoryInterval: 0), cacheURL: try temporary().appendingPathComponent("cache.json"), candidateLimit: 4)
        let category = PodcastCategories.category("1533")!, filter = try filter()
        let key = DiscoveryService.key(.category, country: "CN", category: category)
        let task = Task { await service.load(.category, category: category, library: LibraryState(), filter: filter) { await updates.append($0) } }
        let deadline = Date().addingTimeInterval(3)
        while await updates.values.last?.snapshot.sections[key]?.entries.count ?? 0 < 3, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let early = await updates.values
        XCTAssertEqual(early.last?.snapshot.sections[key]?.entries.count, 3, "Fast sources must appear while the fourth RSS is still held")
        XCTAssertEqual(early.last?.snapshot.sections[key]?.isPartial, true)
        await transport.release()
        let final = await task.value
        XCTAssertNil(final.error); XCTAssertEqual(final.snapshot.sections[key]?.entries.count, 4)
        XCTAssertEqual(final.snapshot.sections[key]?.isPartial, false)
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { $0.url?.host == "feeds.example" }.count, 4)
        XCTAssertFalse(calls.contains { $0.url?.path == "/search" })
        let reused = await service.load(.category, category: category, library: LibraryState(), filter: filter)
        XCTAssertTrue(reused.fromCache)
        let after = await transport.requests; XCTAssertEqual(after.count, calls.count)
    }
    func testCategoryShowsLocalValidatedRSSBeforeNetworkAndRechecksPolicy() async throws {
        let transport = GatedCategoryTransport(holdChart: true), updates = CategoryUpdates()
        let root = try temporary(), url = root.appendingPathComponent("cache.json")
        var fresh = Podcast(feedURL: URL(string: "https://feeds.example/local")!, title: "新科学标题", categories: ["Science"], hasRSSMetadata: true, rssFetchedAt: Date())
        var snapshot = DiscoverySnapshot(); snapshot.feeds[fresh.id] = CachedDiscoveryFeed(feed: Feed(podcast: fresh, episodes: []), fetchedAt: Date())
        try DiscoveryCacheStore(url: url).save(snapshot)
        fresh.title = "旧科学标题"; fresh.rssFetchedAt = Date().addingTimeInterval(-86400)
        var library = LibraryState(); library.merge(Feed(podcast: fresh, episodes: []))
        let service = DiscoveryService(http: HTTPClient(transport: transport, directoryInterval: 0), cacheURL: url)
        let category = PodcastCategories.category("1533")!, key = DiscoveryService.key(.category, country: "CN", category: category), filter = try filter()
        let capturedLibrary = library
        let task = Task { await service.load(.category, category: category, library: capturedLibrary, filter: filter) { await updates.append($0) } }
        let deadline = Date().addingTimeInterval(3)
        while await updates.values.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let first = await updates.values.first
        XCTAssertEqual(first?.snapshot.sections[key]?.origin, .localLibrary)
        XCTAssertEqual(first?.snapshot.sections[key]?.entries.map(\.showID), [fresh.id])
        XCTAssertEqual(first?.snapshot.feeds[fresh.id]?.feed.podcast.title, "新科学标题", "An older library snapshot cannot replace fresher cached RSS")
        task.cancel(); await transport.release(); _ = await task.value
        var policy = ParentalPolicy(); policy.blockedAppleCategories = ["1533"]
        let before = await transport.requests.count
        _ = await service.load(.category, category: category, library: library, filter: try self.filter(policy), force: true)
        let after = await transport.requests.count; XCTAssertEqual(before, after)
    }
    func testCategoryLaneIsIndependentOfBackgroundDiscovery() async throws {
        let background = GatedCategoryTransport(holdChart: true), foreground = DiscoveryTransport()
        let service = DiscoveryService(http: HTTPClient(transport: background, directoryInterval: 0), interactiveHTTP: HTTPClient(transport: foreground, directoryInterval: 0), cacheURL: try temporary().appendingPathComponent("cache.json"), candidateLimit: 4)
        let filter = try filter(), category = PodcastCategories.category("1533")!
        let home = Task { await service.load(.topShows, library: LibraryState(), filter: filter) }
        let categoryResult = await service.load(.category, category: category, library: LibraryState(), filter: filter)
        XCTAssertEqual(categoryResult.snapshot.sections[DiscoveryService.key(.category, country: "CN", category: category)]?.entries.count, 4)
        home.cancel(); await background.release(); _ = await home.value
    }
    func testInterruptedCategoryCacheContinuesLoadingWhenReopened() async throws {
        let transport = GatedCategoryTransport(holdSlowRSS: true), updates = CategoryUpdates()
        let url = try temporary().appendingPathComponent("cache.json")
        let service = DiscoveryService(http: HTTPClient(transport: transport, directoryInterval: 0), cacheURL: url, candidateLimit: 4)
        let filter = try filter(), category = PodcastCategories.category("1533")!
        let key = DiscoveryService.key(.category, country: "CN", category: category)
        let task = Task { await service.load(.category, category: category, library: LibraryState(), filter: filter) { await updates.append($0) } }
        let deadline = Date().addingTimeInterval(3)
        while await updates.values.last?.snapshot.sections[key]?.entries.count ?? 0 < 3, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel(); _ = await task.value
        let partial = try DiscoveryCacheStore(url: url).load()
        XCTAssertEqual(partial.sections[key]?.isPartial, true); XCTAssertEqual(partial.sections[key]?.entries.count, 3)
        let nextTransport = GatedCategoryTransport()
        let reopened = DiscoveryService(http: HTTPClient(transport: nextTransport, directoryInterval: 0), cacheURL: url, candidateLimit: 4)
        let completed = await reopened.load(.category, category: category, library: LibraryState(), filter: filter)
        XCTAssertNil(completed.error); XCTAssertEqual(completed.snapshot.sections[key]?.entries.count, 4)
        XCTAssertEqual(completed.snapshot.sections[key]?.isPartial, false)
        let requests = await nextTransport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "feeds.example" }.count, 1, "Reuse three completed RSS feeds; only fetch the missing one")
    }
}

// Routes by endpoint/entity so simultaneous show and episode channels cannot accidentally share fixtures.
actor EpisodeSearchTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var failEpisodes = false
    var failAll = false
    var holdOld = false
    var released = false
    var wrongGUID = false
    func configure(failEpisodes: Bool = false, failAll: Bool = false, holdOld: Bool = false, wrongGUID: Bool = false) {
        self.failEpisodes = failEpisodes; self.failAll = failAll; self.holdOld = holdOld; self.wrongGUID = wrongGUID
    }
    func release() { released = true }
    static func row(show: Int = 100, episode: Int = 200, title: String = "黑洞之旅", guid: String? = "g-one") -> [String: Any] {
        var value: [String: Any] = ["kind": "podcast-episode", "collectionId": show, "trackId": episode, "collectionName": "黑洞科学访谈", "trackName": title, "feedUrl": "https://episode.example/\(show).xml", "episodeUrl": "https://episode.example/\(episode).mp3", "description": "探索宇宙", "releaseDate": "2026-10-01T00:00:00Z", "trackTimeMillis": 120000, "genres": [["id": "1533", "name": "Science"]], "collectionViewUrl": "https://podcasts.apple.com/cn/podcast/science/id\(show)"]
        if let guid { value["episodeGuid"] = guid }
        return value
    }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!, items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        // Deliberately ignore cancellation to exercise generation protection in both channels.
        while holdOld && value("term") == "旧词" && !released { try? await Task.sleep(nanoseconds: 10_000_000); await Task.yield() }
        if failAll || (failEpisodes && value("entity") == "podcastEpisode") { throw URLError(.timedOut) }
        let data: Data
        if url.path == "/search", value("entity") == "podcastEpisode" {
            let term = value("term") ?? "黑洞"
            data = try JSONSerialization.data(withJSONObject: ["results": [Self.row(title: term + "之旅", guid: wrongGUID ? "unmatched" : "g-one"), Self.row(title: "无关单集", guid: "unrelated"), Self.row(show: 101, episode: 201, title: term + "之旅", guid: "g-two")]])
        } else if url.path == "/search" || url.path == "/lookup" {
            let id = value("id") ?? "100"
            data = try JSONSerialization.data(withJSONObject: ["results": [["collectionName": "科学访谈", "artistName": "科学团队", "feedUrl": "https://episode.example/\(id).xml", "genres": ["Science"], "genreIds": ["1533"], "artistId": 123]]])
        } else {
            let title = "科学访谈"
            data = Data("<rss version=\"2.0\"><channel><title>\(title)</title><description>科学与生活</description><item><title>黑洞之旅</title><description>探索宇宙</description><guid>g-one</guid><enclosure url=\"https://episode.example/200.mp3\" type=\"audio/mpeg\" length=\"100\"/></item></channel></rss>".utf8)
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension AcceptanceRegressionTests {
    func testPublicEpisodeSearchUsesOwnTextAndStableIDsWithoutLoadingRSS() async throws {
        let transport = EpisodeSearchTransport()
        let directory = DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0))
        let result = try await UnifiedDirectorySearch(directory: directory).search("黑洞", includeEpisodes: true)
        XCTAssertEqual(result.completedSources, 6); XCTAssertEqual(result.failedSources, 0)
        XCTAssertEqual(result.episodes.count, 2, "Cross-store candidates deduplicate by stable collection/track ID; homonyms remain distinct")
        XCTAssertEqual(Set(result.episodes.map { $0.identity!.showDirectoryID }), ["100", "101"])
        XCTAssertTrue(result.episodes.allSatisfy { $0.episode.title == "黑洞之旅" && $0.episode.duration == 120 && $0.episode.published != nil })
        XCTAssertTrue(result.episodes.allSatisfy { !$0.show.hasRSSMetadata && $0.show.artworkURL == nil })
        XCTAssertEqual(result.episodes[0].show.classificationObservations?.first?.id, "1533")
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 6); XCTAssertTrue(calls.allSatisfy { $0.url?.path == "/search" })
        XCTAssertEqual(calls.filter { $0.url!.query!.contains("entity=podcastEpisode") }.count, 3)
    }
    func testLocalEpisodeSearchMatchesEpisodeFieldsAndPreservesUnsubscribedDiscovery() throws {
        var library = LibraryState()
        let show = Podcast(feedURL: URL(string: "https://episode.example/100.xml")!, title: "黑洞节目", hasRSSMetadata: true)
        let match = Episode(podcastID: show.id, guid: "one", title: "BLACK holes", summary: "探索宇宙", audioURL: URL(string: "https://episode.example/one.mp3")!)
        let showOnly = Episode(podcastID: show.id, guid: "two", title: "普通访谈", audioURL: URL(string: "https://episode.example/two.mp3")!)
        library.merge(Feed(podcast: show, episodes: [match, showOnly]))
        XCTAssertTrue(library.subscriptions.isEmpty)
        XCTAssertEqual(EpisodeSearch.local("black HOLES", library: library, filter: try filter()).map(\.episode.id), [match.id])
        XCTAssertEqual(EpisodeSearch.local("宇宙", library: library, filter: try filter()).map(\.episode.id), [match.id])
        XCTAssertTrue(EpisodeSearch.local("黑洞", library: library, filter: try filter()).isEmpty)
        var policy = ParentalPolicy(); policy.episodeBlocklist.insert(match.id)
        XCTAssertTrue(EpisodeSearch.local("black", library: library, filter: try filter(policy)).isEmpty)
        policy.showBlocklist.insert(show.id); policy.episodeBlocklist.removeAll(); policy.episodeAllowlist.insert(match.id)
        XCTAssertEqual(EpisodeSearch.local("black", library: library, filter: try filter(policy)).count, 1)
    }
    func testEpisodeResolutionNeverGuessesByTitleAndDeduplicatesLocalGUIDOrEnclosure() async throws {
        let hits = try await DirectoryClient(http: HTTPClient(transport: EpisodeSearchTransport(), directoryInterval: 0)).searchEpisodes("黑洞")
        let hit = try XCTUnwrap(hits.first)
        var show = hit.show; show.hasRSSMetadata = true
        var episode = hit.episode; episode.title = "RSS 已更名"; episode.audioURL = URL(string: "https://episode.example/new.mp3")!
        let feed = Feed(podcast: show, episodes: [episode])
        XCTAssertEqual(EpisodeSearch.resolve(hit, in: feed)?.id, episode.id)
        XCTAssertNil(EpisodeSearch.resolve(hit, in: Feed(podcast: hits[1].show, episodes: [episode])))
        var sameTitle = episode; sameTitle.guid = "wrong-guid"; sameTitle.title = hit.episode.title
        XCTAssertNil(EpisodeSearch.resolve(hit, in: Feed(podcast: show, episodes: [sameTitle])))
        XCTAssertNil(EpisodeSearch.resolve(hit, in: Feed(podcast: show, episodes: [episode, episode])))
        let local = SearchEpisodeHit(show: show, episode: episode)
        XCTAssertEqual(EpisodeSearch.deduplicated([local, hit] + hits).count, 2)
        let noGUID = SearchEpisodeHit(show: show, episode: episode, identity: DirectoryEpisodeIdentity(showDirectoryID: "100", episodeDirectoryID: "200", guid: nil, audioURL: episode.audioURL, sourceURL: hit.identity!.sourceURL))
        XCTAssertEqual(EpisodeSearch.resolve(noGUID, in: feed)?.id, episode.id)
    }
    func testOneUnavailableEpisodeChannelIsPartialSuccess() async throws {
        let transport = EpisodeSearchTransport(); await transport.configure(failEpisodes: true)
        let value = try await UnifiedDirectorySearch(directory: DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0))).search("黑洞", includeEpisodes: true)
        XCTAssertEqual(value.failedSources, 3); XCTAssertEqual(value.completedSources, 6)
        XCTAssertFalse(value.shows.isEmpty); XCTAssertTrue(value.episodes.isEmpty)
    }
}
