import XCTest
import Combine
@testable import PodcastCore
@testable import QuietCast

final class PerformanceRegressionTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuietCastPerformance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor func testSearchReturnsWithoutFetchingEveryResultRSS() async throws {
        let body = Data(#"{"results":[{"collectionName":"科学","artistName":"团队","feedUrl":"https://example.com/science.xml","genres":["Science"]}]}"#.utf8)
        let transport = StubTransport([.data(200, body), .data(200, body)])
        let store = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0))
        await store.waitForPresentation()
        store.search("科学", country: "CN")
        let deadline = Date().addingTimeInterval(5)
        while (store.results.isEmpty || store.searching) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.results.first?.title, "科学"); XCTAssertFalse(store.searching)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/search" })
        XCTAssertTrue(store.library.episodes.isEmpty)
        // Directory-only results cannot bypass the required RSS check before playback/subscription.
        XCTAssertEqual(store.result(show: try XCTUnwrap(store.results.first)).decision, .review)
        await store.flushPersistence()
    }
    @MainActor func testLargeLibraryProgressSaveAndRepeatedListFilteringRemainResponsive() async throws {
        let root = try temporary(), url = root.appendingPathComponent("library.json")
        let show = Podcast(feedURL: URL(string: "https://example.com/performance")!, title: "科学访谈", author: "科学团队", summary: "科学知识访谈", categories: ["Science"], hasRSSMetadata: true)
        let summary = String(repeating: "科学与生活的访谈内容。", count: 70)
        var state = LibraryState()
        state.podcasts[show.id] = show
        for index in 0..<4000 {
            let episode = Episode(podcastID: index < 300 ? show.id : "https://example.com/other", guid: "test-\(index)", title: "科学访谈 \(index)", summary: summary, audioURL: URL(string: "https://example.com/\(index).mp3")!)
            state.episodes[episode.id] = episode
        }
        let fixture = state
        try await Task.detached { try AtomicLibraryStore(url: url).save(fixture) }.value
        let store = AppStore(rootURL: root)
        await store.waitForPresentation()
        let start = Date()
        XCTAssertTrue(store.change { $0.searchHistory = ["保存响应测试"] })
        let mutationTime = Date().timeIntervalSince(start)
        XCTAssertLessThan(mutationTime, 0.2, "Saving a multi-MB library must not encode it on the main actor")
        let first = store.episodes(for: show)
        XCTAssertEqual(first.count, 300)
        let renderStart = Date()
        for _ in 0..<3 { XCTAssertEqual(store.episodes(for: show).count, 300) }
        let renderTime = Date().timeIntervalSince(renderStart)
        XCTAssertLessThan(renderTime, 2, "Repeated list rendering must reuse immutable category/text normalization")
        print("PERFORMANCE: 4000 episodes, change=\(mutationTime)s; three 300-row filter passes=\(renderTime)s")
        await store.flushPersistence()
        XCTAssertEqual(try AtomicLibraryStore(url: url).load().searchHistory, ["保存响应测试"])
    }
}

extension PerformanceRegressionTests {
    @MainActor func testLifecycleBenchmark() async throws {
        let root = try temporary(), audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var library = LibraryState(), snapshot = DiscoverySnapshot(), records: [String: DownloadRecord] = [:]
        for index in 0..<20 {
            let show = Podcast(feedURL: URL(string: "https://example.com/benchmark/\(index)")!, title: "科学访谈 \(index)", author: "科学团队", summary: "科学与生活", categories: ["Science"], hasRSSMetadata: true, rssFetchedAt: Date())
            let episodes = (0..<200).map { number in
                Episode(podcastID: show.id, guid: "item-\(number)", title: "第\(number)期科学知识", summary: "节目\(index)单集\(number)。" + String(repeating: "探讨自然现象和生活中的科学知识。", count: 60), audioURL: URL(string: "https://example.com/\(index)/\(number).mp3")!, published: Date(timeIntervalSince1970: Double(number)))
            }
            let feed = Feed(podcast: show, episodes: episodes)
            library.merge(feed); library.subscriptions.insert(show.id)
            snapshot.feeds[show.id] = CachedDiscoveryFeed(feed: feed, fetchedAt: Date())
            for episode in episodes.prefix(25) {
                library.favorites.insert(episode.id)
                records[episode.id] = DownloadRecord(id: episode.id, episode: episode, status: .downloaded, received: 4, expected: 4, fileExtension: "mp3")
                try Data([0x49,0x44,0x33,0]).write(to: OfflineFiles(directory: audio).fileURL(episode.id, fileExtension: "mp3"))
            }
        }
        library.subscriptionRefreshAttemptAt = Date()
        for kind in [DiscoveryKind.topShows, .topEpisodes, .personalized, .newShows] {
            let key = DiscoveryService.key(kind, country: "CN")
            snapshot.sections[key] = DiscoverySection(id: key, kind: kind, title: key, origin: .localLibrary, country: "CN", generatedAt: Date(), entries: library.podcasts.keys.sorted().map { DiscoveryEntry(showID: $0) })
        }
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(library)
        try DiscoveryCacheStore(url: root.appendingPathComponent("discovery.json")).save(snapshot)
        try JSONEncoder().encode(records).write(to: audio.appendingPathComponent("manifest.json"))
        let transport = StubTransport([]), http = HTTPClient(transport: transport, directoryInterval: 0, defaultRetries: 0)
        let start = Date()
        let store = AppStore(rootURL: root, http: http, parentAuthority: try ParentAuthority(store: MemorySecureStore()), discoveryHTTP: http)
        let initTime = Date().timeIntervalSince(start)
        var firstPaint: TimeInterval?
        let observer = store.$presentation.sink { value in if firstPaint == nil && !value.subscribed.isEmpty { firstPaint = Date().timeIntervalSince(start) } }
        defer { observer.cancel() }
        await store.waitForPresentation()
        let readyTime = Date().timeIntervalSince(start)
        let show = try XCTUnwrap(store.library.podcasts.values.first)
        let listStart = Date()
        for _ in 0..<10 { XCTAssertEqual(store.episodes(for: show).count, 200) }
        let listTime = Date().timeIntervalSince(listStart)
        let builds = await store.presentationWorker.buildCount
        let libraryBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let manifestBytes = try Data(contentsOf: audio.appendingPathComponent("manifest.json"))
        let returnStart = Date()
        for _ in 0..<3 { await store.loadHome(); store.revalidate(); await store.waitForPresentation() }
        let returnTime = Date().timeIntervalSince(returnStart)
        let returnBuilds = await store.presentationWorker.buildCount - builds
        XCTAssertEqual(returnBuilds, 0, "Returning to cached home must not rebuild a full projection")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), libraryBytes)
        XCTAssertEqual(try Data(contentsOf: audio.appendingPathComponent("manifest.json")), manifestBytes)
        store.sceneBackground(); store.revalidate(); await store.refreshIfNeeded()
        let backgroundBuilds = await store.presentationWorker.buildCount
        XCTAssertEqual(backgroundBuilds, builds)
        let diskStart = Date()
        await store.downloads.validateLocalFiles()
        let diskTime = Date().timeIntervalSince(diskStart)
        XCTAssertEqual(store.downloads.validationCount, 0)
        let explicitDiskStart = Date()
        await store.downloads.validateLocalFiles(force: true)
        let explicitDiskTime = Date().timeIntervalSince(explicitDiskStart)
        XCTAssertEqual(store.downloads.validationCount, 1)
        XCTAssertEqual(store.library.episodes.count, 4000)
        XCTAssertEqual(store.downloads.records.count, 500)
        XCTAssertEqual(store.presentation.favorites.count, 500)
        let calls = await transport.requests.count
        XCTAssertEqual(calls, 0)
        print("LIFECYCLE_BENCHMARK firstPaint=\(firstPaint ?? -1) buildsOnReturn=\(returnBuilds) forcedDownloads500=\(explicitDiskTime) init=\(initTime) localReady=\(readyTime) detail10=\(listTime) homeReturn3=\(returnTime) downloads500=\(diskTime) network=\(calls)")
        XCTAssertLessThan(initTime, 0.2, "App construction must not synchronously decode the library/download index")
        let episode = try XCTUnwrap(store.library.episodes.values.first)
        store.recordProgress(episode.id, position: 5, duration: 100, finished: false)
        await store.waitForPresentation()
        let progressBuilds = await store.presentationWorker.buildCount
        store.recordProgress(episode.id, position: 15, duration: 100, finished: false)
        await store.waitForPresentation()
        let afterProgressBuilds = await store.presentationWorker.buildCount
        XCTAssertEqual(progressBuilds, afterProgressBuilds)
        await store.flushPersistence()
        let reopenStart = Date()
        let reopened = AppStore(rootURL: root, http: http, parentAuthority: try ParentAuthority(store: MemorySecureStore()), discoveryHTTP: http)
        await reopened.waitForPresentation()
        let reopenTime = Date().timeIntervalSince(reopenStart)
        let evaluations = await reopened.presentationWorker.evaluationCount
        XCTAssertEqual(evaluations, 0, "A new store must reuse only metadata/rules/policy-validated display decisions")
        XCTAssertEqual(reopened.library.progress[episode.id]?.position, 15)
        XCTAssertEqual(reopened.presentation.visibleEpisodeIDs, store.presentation.visibleEpisodeIDs)
        XCTAssertEqual(reopened.downloads.availableDownloadIDs.count, 500)
        XCTAssertLessThan(reopenTime, 5)
        print("REOPEN_BENCHMARK localReady=\(reopenTime) filterEvaluations=\(evaluations) episodes=4000 downloads=500")
        let searchBuilds = await reopened.presentationWorker.buildCount
        let searchBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let searchStart = Date()
        reopened.search("第")
        var lastTick = Date(), largestGap: TimeInterval = 0
        while reopened.searching && Date().timeIntervalSince(searchStart) < 5 {
            try await Task.sleep(nanoseconds: 10_000_000)
            largestGap = max(largestGap, Date().timeIntervalSince(lastTick)); lastTick = Date()
        }
        XCTAssertFalse(reopened.searching); XCTAssertEqual(reopened.episodeResults.count, 4000)
        let readStart = Date()
        XCTAssertEqual(reopened.episodeResults.filter(reopened.visibleSearchHit).count, 4000)
        let readTime = Date().timeIntervalSince(readStart)
        let searchAfterBuilds = await reopened.presentationWorker.buildCount
        XCTAssertEqual(searchAfterBuilds, searchBuilds)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), searchBytes)
        XCTAssertLessThan(largestGap, 0.2, "Local episode search must yield the main actor")
        XCTAssertLessThan(readTime, 0.1, "Search rendering must reuse current validated local display IDs")
        let directoryHits = reopened.episodeResults.prefix(60).enumerated().map { index, hit in
            SearchEpisodeHit(show: hit.show, episode: hit.episode, identity: DirectoryEpisodeIdentity(showDirectoryID: "\(index)", episodeDirectoryID: "\(index)", guid: hit.episode.guid, audioURL: hit.episode.audioURL, sourceURL: URL(string: "https://itunes.apple.com/search")!))
        }
        let mergeStart = Date()
        XCTAssertEqual(EpisodeSearch.deduplicated(reopened.episodeResults + directoryHits).count, 4000)
        let mergeTime = Date().timeIntervalSince(mergeStart)
        XCTAssertLessThan(mergeTime, 0.1, "Incremental directory merges must reuse computed GUID/enclosure keys")
        print("LOCAL_SEARCH_BENCHMARK episodes4000=\(Date().timeIntervalSince(searchStart)) mainMaxGap=\(largestGap) visible4000=\(readTime) merge4000plus60=\(mergeTime) projectionBuilds=\(searchAfterBuilds - searchBuilds)")
        // Keep an isolated, opt-in Debug fixture for actual simulator process termination/relaunch.
        let qa = FileManager.default.temporaryDirectory.appendingPathComponent("QuietCastLifecycleQA")
        try FileManager.default.createDirectory(at: qa.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        for name in ["library.json", "discovery.json", "display-cache.json", "Audio/manifest.json"] {
            try Data(contentsOf: root.appendingPathComponent(name)).write(to: qa.appendingPathComponent(name), options: .atomic)
        }
        for record in records.values {
            try Data([0x49,0x44,0x33,0]).write(to: OfflineFiles(directory: qa.appendingPathComponent("Audio")).fileURL(record.id, fileExtension: "mp3"))
        }

        await reopened.flushPersistence()
        await store.flushPersistence()
    }
}

extension PerformanceRegressionTests {
    func testDisplayCacheRejectsChangedMetadataPolicyRulesAndClockRollback() async throws {
        let root = try temporary(), url = root.appendingPathComponent("display.json")
        let rules = try RulesLoader.decode(Data(contentsOf: Bundle.main.url(forResource: "content-filter", withExtension: "json")!))
        let show = Podcast(feedURL: URL(string: "https://example.com/cache")!, title: "科学", hasRSSMetadata: true)
        var episode = Episode(podcastID: show.id, guid: "cache", title: "科学访谈", audioURL: URL(string: "https://example.com/cache.mp3")!)
        var state = LibraryState(); state.merge(Feed(podcast: show, episodes: [episode])); state.favorites = [episode.id]
        var policy = ParentalPolicy(); policy.customKeywords = ["测试禁词"]
        let now = Date(), worker = LibraryPresentationWorker(url: url)
        let initial = await worker.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: policy, now: now), epoch: 0)
        XCTAssertTrue(initial.visibleEpisodeIDs.contains(episode.id))
        let reopened = LibraryPresentationWorker(url: url)
        _ = await reopened.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: policy, now: now.addingTimeInterval(1)), epoch: 0)
        let reused = await reopened.evaluationCount; XCTAssertEqual(reused, 0)
        episode.summary = "测试禁词"; state.episodes[episode.id] = episode
        let changed = await reopened.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: policy, now: now.addingTimeInterval(2)), epoch: 0)
        XCTAssertFalse(changed.visibleEpisodeIDs.contains(episode.id))
        policy.episodeAllowlist = [episode.id]
        let allowed = await reopened.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: policy, now: now.addingTimeInterval(3)), epoch: 1)
        XCTAssertTrue(allowed.visibleEpisodeIDs.contains(episode.id))
        let failedRules = await reopened.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: nil, policy: policy, now: now.addingTimeInterval(4)), epoch: 2)
        XCTAssertTrue(failedRules.visibleEpisodeIDs.isEmpty)
        let rollback = LibraryPresentationWorker(url: url)
        let recovered = await rollback.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: policy, now: now.addingTimeInterval(-1)), epoch: 0)
        let rollbackCount = await rollback.evaluationCount
        XCTAssertGreaterThan(rollbackCount, 0); XCTAssertTrue(recovered.visibleEpisodeIDs.contains(episode.id))
    }
    func testDisplayCacheExpiresAtMetadataFreshnessBoundary() async throws {
        let root = try temporary(), url = root.appendingPathComponent("timed.json")
        let data = try Data(contentsOf: Bundle.module.url(forResource: "example-multisource", withExtension: "json", subdirectory: "Fixtures")!)
        let rules = try RulesLoader.decode(data), now = Date(timeIntervalSince1970: 1793001600)
        var show = Podcast(feedURL: URL(string: "https://example.com/timed")!, title: "科学", hasRSSMetadata: true)
        show.classificationObservations = [ClassificationObservation(namespace: "apple.podcasts.genre", id: "1483", name: "Fiction", source: .appleLookup, sourceURL: show.feedURL, observedAt: now)]
        let episode = Episode(podcastID: show.id, guid: "timed", title: "访谈", audioURL: URL(string: "https://example.com/timed.mp3")!)
        var state = LibraryState(); state.merge(Feed(podcast: show, episodes: [episode]))
        let filter = ContentFilter(rules: rules, policy: ParentalPolicy(), now: now)
        let expiry = try XCTUnwrap(filter.nextChangeDate(shows: [show]))
        let first = LibraryPresentationWorker(url: url)
        _ = await first.build(library: state, snapshot: DiscoverySnapshot(), filter: filter, epoch: 0)
        let reopened = LibraryPresentationWorker(url: url)
        _ = await reopened.build(library: state, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: ParentalPolicy(), now: expiry.addingTimeInterval(1)), epoch: 0)
        let count = await reopened.evaluationCount
        XCTAssertGreaterThan(count, 0, "Expired metadata must be reevaluated even after relaunch")
    }
}

extension PerformanceRegressionTests {
    @MainActor func testOfflineRefreshKeepsLocalCollectionsAndFreshDetailSkipsNetwork() async throws {
        let root = try temporary(), transport = StubTransport([])
        let http = HTTPClient(transport: transport, directoryInterval: 0, defaultRetries: 0)
        let show = Podcast(feedURL: URL(string: "https://example.com/offline")!, title: "科学访谈", hasRSSMetadata: true, rssFetchedAt: Date())
        let episode = Episode(podcastID: show.id, guid: "offline", title: "科学知识", audioURL: URL(string: "https://example.com/offline.mp3")!)
        var state = LibraryState(); state.merge(Feed(podcast: show, episodes: [episode])); state.favorites = [episode.id]
        state.subscriptionRefreshAttemptAt = Date()
        var snapshot = DiscoverySnapshot()
        snapshot.feeds[show.id] = CachedDiscoveryFeed(feed: Feed(podcast: show, episodes: [episode]), fetchedAt: Date())
        for kind in [DiscoveryKind.topShows, .topEpisodes, .personalized, .newShows] {
            let key = DiscoveryService.key(kind, country: "CN")
            snapshot.sections[key] = DiscoverySection(id: key, kind: kind, title: key, origin: .localLibrary, country: "CN", generatedAt: Date().addingTimeInterval(-90000), entries: [DiscoveryEntry(showID: show.id)])
        }
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
        try DiscoveryCacheStore(url: root.appendingPathComponent("discovery.json")).save(snapshot)
        let store = AppStore(rootURL: root, http: http, parentAuthority: try ParentAuthority(store: MemorySecureStore()), discoveryHTTP: http)
        await store.waitForPresentation()
        _ = try await store.load(show)
        let detailCalls = await transport.requests.count; XCTAssertEqual(detailCalls, 0)
        let before = store.presentation.favorites.map(\.id)
        await store.loadHome(force: true); await store.waitForPresentation()
        XCTAssertEqual(store.presentation.favorites.map(\.id), before)
        XCTAssertNotNil(store.library.episodes[episode.id]); XCTAssertFalse(store.discoveryErrors.isEmpty)
        let calls = await transport.requests.count; XCTAssertGreaterThan(calls, 0)
        await store.loadHome()
        let after = await transport.requests.count
        XCTAssertEqual(after, calls, "A failed refresh must be throttled on ordinary page return")
        do { _ = try await store.load(show, force: true); XCTFail("Expected offline feed failure") } catch { }
        XCTAssertEqual(store.presentation.favorites.map(\.id), before)
        await store.flushPersistence()
    }
}

private actor CancelledRefreshTransport: HTTPTransport {
    var count = 0
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if count == 5 { try await Task.sleep(nanoseconds: 10_000_000_000) }
        let rss = Data("<rss version=\"2.0\"><channel><title>科学节目</title><item><title>科学单集</title><guid>one</guid><enclosure url=\"https://refresh.example/one.mp3\" type=\"audio/mpeg\"/></item></channel></rss>".utf8)
        return (rss, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
extension PerformanceRegressionTests {
    @MainActor func testCancelledRefreshDoesNotMisreportRemainingNineAsFailed() async throws {
        let root = try temporary(), transport = CancelledRefreshTransport()
        var state = LibraryState()
        for index in 0..<13 {
            let show = Podcast(feedURL: URL(string: "https://refresh.example/\(index).xml")!, title: "科学节目 \(index)", hasRSSMetadata: true)
            state.merge(Feed(podcast: show, episodes: [])); state.subscriptions.insert(show.id)
        }
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
        let store = AppStore(rootURL: root, http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: try ParentAuthority(store: MemorySecureStore()))
        await store.waitForPresentation()
        let task = Task { await store.refresh() }
        let deadline = Date().addingTimeInterval(3)
        while await transport.count < 5 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel(); await task.value
        print("REFRESH_CANCELLATION_REPRO message=\(store.message ?? "none") completed=\(store.library.episodes.count)")
        XCTAssertNil(store.message)
        XCTAssertTrue(store.refreshWasCancelled); XCTAssertTrue(store.refreshFailures.isEmpty)
        XCTAssertNil(store.library.subscriptionRefreshAttemptAt); XCTAssertNil(store.library.subscriptionRefreshedAt)
        XCTAssertEqual(store.library.episodes.count, 4)
        let interruptedCalls = await transport.count; XCTAssertEqual(interruptedCalls, 5)
        // Retry immediately: cancellation must not consume the failed-request backoff.
        await store.refresh()
        let retriedCalls = await transport.count; XCTAssertEqual(retriedCalls, 18)
        XCTAssertFalse(store.refreshWasCancelled); XCTAssertTrue(store.refreshFailures.isEmpty)
        XCTAssertNotNil(store.library.subscriptionRefreshedAt); XCTAssertEqual(store.library.episodes.count, 13)
        await store.flushPersistence()
    }
}

extension PerformanceRegressionTests {
    @MainActor func testRealRefreshFailuresKeepLocalDataAndRecordIndividualCauses() async throws {
        let root = try temporary()
        let transport = StubTransport([.data(404, Data()), .timeout, .timeout, .data(200, Data("<html>not RSS</html>".utf8))])
        var state = LibraryState()
        for index in 0..<3 {
            let show = Podcast(feedURL: URL(string: "https://failure.example/\(index)")!, title: "科学节目 \(index)", hasRSSMetadata: true)
            let episode = Episode(podcastID: show.id, guid: "old", title: "已有单集", audioURL: URL(string: "https://failure.example/\(index).mp3")!)
            state.merge(Feed(podcast: show, episodes: [episode])); state.subscriptions.insert(show.id); state.favorites.insert(episode.id)
            state.record(episodeID: episode.id, position: 30, duration: 100)
        }
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
        let store = AppStore(rootURL: root, http: HTTPClient(transport: transport, directoryInterval: 0, defaultRetries: 0), parentAuthority: try ParentAuthority(store: MemorySecureStore()))
        await store.waitForPresentation()
        await store.refresh()
        XCTAssertEqual(store.refreshFailures.count, 3); XCTAssertFalse(store.refreshWasCancelled)
        XCTAssertTrue(store.refreshFailures.contains { $0.reason.contains("404") })
        XCTAssertTrue(store.refreshFailures.contains { $0.reason.contains("超时") })
        XCTAssertTrue(store.refreshFailures.contains { $0.reason.contains("RSS 无法解析") })
        XCTAssertTrue(store.message?.contains("3 个节目") == true); XCTAssertTrue(store.message?.contains("更新详情") == true)
        XCTAssertEqual(store.library.episodes, state.episodes); XCTAssertEqual(store.library.favorites, state.favorites)
        XCTAssertEqual(store.library.progress, state.progress); XCTAssertNil(store.library.subscriptionRefreshedAt)
        let before = await transport.count
        await store.refreshIfNeeded()
        let after = await transport.count; XCTAssertEqual(before, after, "Actual failures retain backoff on ordinary returns")
        await store.flushPersistence()
    }
}
