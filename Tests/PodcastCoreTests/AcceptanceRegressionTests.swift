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
