import XCTest
import PodcastCore
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
        let transport = StubTransport([.data(200, body)])
        let store = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0))
        store.search("科学", country: "CN")
        let deadline = Date().addingTimeInterval(5)
        while (store.results.isEmpty || store.searching) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.results.first?.title, "科学"); XCTAssertFalse(store.searching)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.url?.path, "/search")
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
