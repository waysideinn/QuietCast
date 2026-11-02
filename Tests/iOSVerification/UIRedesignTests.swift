import XCTest
import SwiftUI
@testable import PodcastCore
@testable import QuietCast

private actor LateSearchTransport: HTTPTransport {
    var oldRequests = 0
    var released = false
    func release() { released = true }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let term = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value ?? ""
        if term == "旧词" {
            oldRequests += 1
            // Deliberately emulate a transport which delivers a response despite cancellation.
            while !released { try? await Task.sleep(nanoseconds: 10_000_000); await Task.yield() }
        }
        let body = try JSONSerialization.data(withJSONObject: ["results": [["collectionName": term, "feedUrl": "https://late.example/" + (term == "旧词" ? "old" : "new"), "genres": ["Science"]] as [String: Any]]])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class UIRedesignTests: XCTestCase {
    func testFiveSectionsAndLegacyTabMigration() {
        XCTAssertEqual(AppSection.allCases.map(\.rawValue), ["explore", "subscriptions", "favorites", "downloads", "settings"])
        XCTAssertEqual(AppSection.migrating(legacy: 1), .explore)
        XCTAssertEqual(AppSection.migrating(legacy: 2), .subscriptions)
        XCTAssertEqual(AppSection.migrating(legacy: 3), .downloads)
        XCTAssertEqual(AppSection.migrating(legacy: 4), .settings)
        XCTAssertEqual(AppSection.migrating(legacy: 99), .explore)
    }
    func testProjectionPreservesCollectionsOrderAndLiveFiltering() throws {
        let rules = try RulesLoader.decode(Data(contentsOf: Bundle.module.url(forResource: "example-multisource", withExtension: "json", subdirectory: "Fixtures")!))
        let a = Podcast(feedURL: URL(string: "https://example.com/one")!, title: "科学", author: "同名播主", hasRSSMetadata: true)
        let b = Podcast(feedURL: URL(string: "https://example.com/two")!, title: "历史", author: "同名播主", hasRSSMetadata: true)
        let e1 = Episode(podcastID: a.id, guid: "one", title: "A", audioURL: URL(string: "https://example.com/a.mp3")!, published: Date(timeIntervalSince1970: 10))
        let e2 = Episode(podcastID: a.id, guid: "two", title: "B", audioURL: URL(string: "https://example.com/b.mp3")!, published: Date(timeIntervalSince1970: 20))
        let e3 = Episode(podcastID: b.id, guid: "three", title: "C", audioURL: URL(string: "https://example.com/c.mp3")!, published: Date(timeIntervalSince1970: 30))
        var library = LibraryState(); library.merge(Feed(podcast: a, episodes: [e1,e2])); library.merge(Feed(podcast: b, episodes: [e3]))
        library.subscriptions = [a.id,b.id]; library.favorites = [e1.id,e3.id]; library.queue = [e2.id,e1.id]
        library.progress[e1.id] = EpisodeProgress(position: 20, duration: 30, completed: true, lastPlayed: Date())
        library.progress[e2.id] = EpisodeProgress(completed: true)
        let first = LibraryPresentation.build(library: library, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: ParentalPolicy()))
        XCTAssertEqual(first.updates.map(\.id), [e3.id,e2.id]); XCTAssertEqual(first.unplayed.map(\.id), [e3.id])
        XCTAssertEqual(first.history.map(\.id), [e1.id]); XCTAssertEqual(first.queue.map(\.id), [e2.id,e1.id])
        XCTAssertEqual(first.episodesByShow[a.id]?.count, 2); XCTAssertEqual(first.episodesByShow[b.id]?.count, 1)
        library.progress[e1.id]?.completed = false
        let backlog = LibraryPresentation.build(library: library, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: ParentalPolicy()))
        XCTAssertEqual(backlog.unplayed.map(\.id), [e3.id], "Completing the latest episode must not resurface older unplayed episodes")
        var blocked = ParentalPolicy(); blocked.showBlocklist = [b.id]
        let next = LibraryPresentation.build(library: library, snapshot: DiscoverySnapshot(), filter: ContentFilter(rules: rules, policy: blocked))
        XCTAssertEqual(next.favorites.map(\.id), [e1.id]); XCTAssertFalse(next.visibleEpisodeIDs.contains(e3.id)); XCTAssertEqual(library.favorites.count, 2)
    }
    @MainActor func testSearchDoesNotRecordHistoryAndPresentationUsesLatestRevision() async throws {
        let root = try temporary()
        let transport = StubTransport([.data(200, Data(#"{"results":[]}"#.utf8))])
        let store = AppStore(rootURL: root, http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: try ParentAuthority(store: MemorySecureStore()))
        await store.waitForPresentation()
        store.change { $0.searchHistory = ["旧资料保留兼容"] }
        store.search("科学", country: "CN")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.library.searchHistory, ["旧资料保留兼容"])
        let a = Podcast(feedURL: URL(string: "https://example.com/revision")!, title: "科学", hasRSSMetadata: true)
        let episode = Episode(podcastID: a.id, guid: "revision", title: "科学单集", audioURL: URL(string: "https://example.com/one.mp3")!)
        store.change { $0.merge(Feed(podcast: a, episodes: [episode])); $0.favorites.insert(episode.id) }
        store.change { $0.favorites.removeAll() }
        await store.waitForPresentation(); XCTAssertTrue(store.presentation.favorites.isEmpty)
        await store.flushPersistence()
    }
    @MainActor func testPolicyChangeImmediatelyInvalidatesOldPresentationWithoutDeletingFavorites() async throws {
        let authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let store = AppStore(rootURL: try temporary(), parentAuthority: authority)
        await store.waitForPresentation()
        let show = Podcast(feedURL: URL(string: "https://example.com/policy")!, title: "科学节目", hasRSSMetadata: true)
        let episode = Episode(podcastID: show.id, guid: "policy", title: "科学访谈", audioURL: URL(string: "https://example.com/policy.mp3")!)
        store.change { $0.merge(Feed(podcast: show, episodes: [episode])); $0.favorites.insert(episode.id); $0.queue = [episode.id]; $0.subscriptions.insert(show.id) }
        await store.waitForPresentation(); XCTAssertEqual(store.presentation.favorites.count, 1)
        var policy = store.policy; policy.showBlocklist.insert(show.id)
        try store.updatePolicy(policy, grant: grant)
        XCTAssertTrue(store.presentation.favorites.isEmpty)
        await store.waitForPresentation()
        XCTAssertTrue(store.presentation.subscribed.isEmpty); XCTAssertTrue(store.presentation.queue.isEmpty)
        XCTAssertTrue(store.library.favorites.contains(episode.id)); XCTAssertFalse(store.authorizeEpisode(episode.id, entry: .download, requestUnlock: false))
        await store.flushPersistence()
    }
    @MainActor func testMissingDownloadedFileIsNotOfflineContent() async throws {
        let root = try temporary()
        let ep = Episode(podcastID: "https://example.com/feed", guid: "missing", title: "丢失音频", audioURL: URL(string: "https://example.com/audio.mp3")!)
        let records = [ep.id: DownloadRecord(id: ep.id, episode: ep, status: .downloaded, fileExtension: "mp3")]
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("manifest.json"))
        let manager = DownloadManager(directory: root, sessionIdentifier: "org.quietcast.ui-tests." + UUID().uuidString)
        await manager.waitUntilReady()
        XCTAssertNil(manager.localURL(ep.id)); XCTAssertEqual(manager.records[ep.id]?.status, .failed)
        XCTAssertFalse(manager.availableDownloadIDs.contains(ep.id))
    }
    @MainActor func testFirstKeyboardReturnCommitsChineseAndStartsUnifiedSearchWithoutRegionChange() async throws {
        let transport = RegionalSearchTransport()
        let store = try await makeFixture(http: HTTPClient(transport: transport, directoryInterval: 0))
        defer { store.player.unload() }
        _ = try await capture(NavigationStack { HomeView() }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "first-keyboard-search") { view in
            let field = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "explore.search" })
            XCTAssertTrue(field.becomeFirstResponder())
            field.setMarkedText("科学", selectedRange: NSRange(location: 2, length: 0))
            field.sendActions(for: .editingChanged)
            let shouldReturn = try XCTUnwrap(field.delegate?.textFieldShouldReturn)
            XCTAssertFalse(shouldReturn(field))
            XCTAssertFalse(field.isFirstResponder, "Submitting Return must dismiss the keyboard")
            // A late editing notification must not clear or cancel the just-submitted request.
            field.sendActions(for: .editingChanged)
            let deadline = Date().addingTimeInterval(5)
            while store.searching && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(store.searchTerm, "科学"); XCTAssertFalse(store.searching); XCTAssertNil(store.searchError)
            XCTAssertEqual(store.results.count, 4)
        }
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 6, "One Return starts one search with a show and episode channel for each storefront")
        XCTAssertTrue(calls.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value == "科学" })
        XCTAssertTrue(store.library.searchHistory.isEmpty)
        await store.flushPersistence()
    }
    @MainActor func testButtonSubmissionDismissalEndsEditingUntilNextTap() async throws {
        _ = try await capture(NavigationStack { TextField("输入", text: .constant("科学")) }, size: CGSize(width: 375, height: 667), name: "keyboard-dismissal") { view in
            let field = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UITextField }.first)
            XCTAssertTrue(field.becomeFirstResponder())
            Keyboard.dismiss()
            XCTAssertFalse(field.isFirstResponder)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(field.isFirstResponder, "Result updates must not reopen the keyboard")
            XCTAssertTrue(field.becomeFirstResponder(), "The next user edit can focus again")
            Keyboard.dismiss()
        }
    }
    @MainActor func testParentSearchJournalRequiresGrantAndPersistsSeparateFromSuggestions() async throws {
        let root = try temporary()
        let authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let http = HTTPClient(transport: StubTransport([.data(200, Data(#"{"results":[]}"#.utf8))]), directoryInterval: 0)
        let store = AppStore(rootURL: root, http: http, parentAuthority: authority)
        await store.waitForPresentation()
        store.search("科学"); store.search("历史"); store.search("科学"); store.search("")
        let records = try store.parentSearchRecords(grant: grant)
        XCTAssertEqual(records.map(\.term), ["科学", "历史"]); XCTAssertEqual(records.first?.count, 2)
        XCTAssertTrue(store.library.searchHistory.isEmpty)
        let reopened = AppStore(rootURL: root, http: http, parentAuthority: authority)
        await reopened.waitForPresentation()
        XCTAssertEqual(try reopened.parentSearchRecords(grant: grant), records)
        _ = try await capture(NavigationStack { ParentSearchHistoryView(grant: grant) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "parent-search-history")
        authority.lock()
        XCTAssertThrowsError(try store.parentSearchRecords(grant: grant))
        XCTAssertThrowsError(try store.deleteSearchRecords(grant: grant))
        let newGrant = try authority.authenticate(pin: "246813")
        try store.deleteSearchRecords(ids: [records.last!.id], grant: newGrant)
        XCTAssertEqual(try store.parentSearchRecords(grant: newGrant).count, 1)
        try store.deleteSearchRecords(grant: newGrant)
        XCTAssertTrue(try store.parentSearchRecords(grant: newGrant).isEmpty)
        let cleared = AppStore(rootURL: root, http: http, parentAuthority: authority)
        await cleared.waitForPresentation()
        XCTAssertTrue(try cleared.parentSearchRecords(grant: newGrant).isEmpty)
        await store.flushPersistence(); await reopened.flushPersistence(); await cleared.flushPersistence()
    }
    @MainActor func testLateCancelledSearchCannotOverwriteNewResultsOrRestoreClearedSearch() async throws {
        let transport = LateSearchTransport()
        let store = try await makeFixture(http: HTTPClient(transport: transport, directoryInterval: 0))
        defer { store.player.unload() }
        store.search("旧词")
        let started = Date().addingTimeInterval(2)
        while await transport.oldRequests < 3, Date() < started { try await Task.sleep(nanoseconds: 10_000_000) }
        store.search("新词")
        let deadline = Date().addingTimeInterval(3)
        while store.searching && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await transport.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.searchTerm, "新词"); XCTAssertEqual(store.results.map(\.title), ["新词"])
        XCTAssertFalse(store.searching); XCTAssertNil(store.searchError)
        store.search("新词"); store.search("")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.results.isEmpty); XCTAssertEqual(store.searchTerm, ""); XCTAssertFalse(store.searching)
        await store.flushPersistence()
    }
    @MainActor func testHomeBottomStaysVisibleAfterScrollingStops() async throws {
        let store = try await makeFixture()
        defer { store.player.unload() }
        await store.waitForPresentation()
        let oldTab = UserDefaults.standard.object(forKey: "navigation.selectedSection")
        defer { if let oldTab { UserDefaults.standard.set(oldTab, forKey: "navigation.selectedSection") } else { UserDefaults.standard.removeObject(forKey: "navigation.selectedSection") } }
        UserDefaults.standard.set(AppSection.explore.rawValue, forKey: "navigation.selectedSection")
        for (name, size, type) in [
            ("home-bottom-se", CGSize(width: 375, height: 667), DynamicTypeSize.large),
            ("home-bottom-indicator", CGSize(width: 393, height: 852), .large),
            ("home-bottom-landscape", CGSize(width: 667, height: 375), .large),
            ("home-bottom-large-text", CGSize(width: 375, height: 667), .xxxLarge)
        ] {
            let frames = try await capture(RootView().environmentObject(store).dynamicTypeSize(type), size: size, name: name) { try await self.restAtBottom($0) }
            self.assertLastItemVisible("home.bottom", frames: frames)
        }
        await store.flushPersistence()
    }
    @MainActor func testShowMoreEpisodesStaysVisibleAfterScrollingStops() async throws {
        let rss = Data("<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>嗑嗑科学</title><itunes:category text=\"Science\"/></channel></rss>".utf8)
        let transport = StubTransport([.data(200, rss)])
        let store = try await makeFixture(http: HTTPClient(transport: transport, directoryInterval: 0))
        defer { store.player.unload() }
        let show = try XCTUnwrap(store.library.podcasts[store.player.episode!.podcastID])
        store.change { library in
            for index in 0..<150 {
                let episode = Episode(podcastID: show.id, guid: "long-list-\(index)", title: "科学单集 \(index)", audioURL: URL(string: "https://example.com/long/\(index).mp3")!, published: Date().addingTimeInterval(Double(-index) * 86400))
                library.episodes[episode.id] = episode
            }
        }
        await store.waitForPresentation()
        for (name, size, type) in [
            ("show-more-se", CGSize(width: 375, height: 667), DynamicTypeSize.large),
            ("show-more-indicator", CGSize(width: 393, height: 852), .large),
            ("show-more-large-text", CGSize(width: 375, height: 667), .xxxLarge)
        ] {
            let frames = try await capture(PlayerNavigationContainer(player: store.player, selectedTab: .constant(AppSection.explore.rawValue), expand: {}) {
                NavigationStack { ShowDetailView(show: show) }
            }.environmentObject(store).dynamicTypeSize(type), size: size, name: name) { try await self.restAtBottom($0) }
            self.assertLastItemVisible("show.moreEpisodes", frames: frames)
        }
        await store.flushPersistence()
    }
    @MainActor private func assertLastItemVisible(_ key: String, frames: [String: CGRect], file: StaticString = #filePath, line: UInt = #line) {
        guard let last = frames[key], let page = frames["page.viewport"], let mini = frames["miniPlayer"] else { return XCTFail("Missing measurements for \(key)", file: file, line: line) }
        XCTAssertLessThanOrEqual(page.maxY, mini.minY + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(last.minY, page.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(last.maxY, page.maxY + 1, "The final item must remain above the player after scrolling stops", file: file, line: line)
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func restAtBottom(_ view: UIView) async throws {
        for scroll in descendants(view).compactMap({ $0 as? UIScrollView }) {
            print("SCROLL_EXTENT: \(type(of: scroll)) bounds=\(scroll.bounds) size=\(scroll.contentSize) insets=\(scroll.adjustedContentInset)")
        }
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height > 20 && $0.bounds.width > 200 && $0.contentSize.height > $0.bounds.height + 40 }.max { $0.contentSize.height < $1.contentSize.height })
        // Materialize lazy rows a viewport at a time. Teleporting to an estimated
        // extent can leave an empty viewport after content above it changes height.
        var stablePasses = 0
        for _ in 0..<120 {
            scroll.layoutIfNeeded()
            let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = min(bottom, scroll.contentOffset.y + max(40, scroll.bounds.height * 0.8))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutIfNeeded()
            let refinedBottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            stablePasses = abs(scroll.contentOffset.y - refinedBottom) <= 1 ? stablePasses + 1 : 0
            if stablePasses >= 3 { break }
        }
        XCTAssertFalse(scroll.isTracking); XCTAssertFalse(scroll.isDragging); XCTAssertFalse(scroll.isDecelerating)
        XCTAssertEqual(scroll.contentOffset.y, max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), accuracy: 1)
    }
    @MainActor func testPlayerFirstScreenAndRootDockLayouts() async throws {
        let store = try await makeFixture()
        await store.waitForPresentation()
        defer { store.player.unload(); LayoutDiagnostics.activeID = nil }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        for (name, size, type, dark) in [
            ("player-se", CGSize(width: 375, height: 667), DynamicTypeSize.large, false),
            ("player-home-indicator", CGSize(width: 393, height: 852), .large, false),
            ("player-se-large-text", CGSize(width: 375, height: 667), .xxxLarge, false),
            ("player-landscape", CGSize(width: 667, height: 375), .large, false),
            ("player-accessibility", CGSize(width: 375, height: 667), .accessibility5, false),
            ("player-dark", CGSize(width: 375, height: 667), .large, true)
        ] {
            let frames = try await capture(PlayerView(player: store.player).environmentObject(store).dynamicTypeSize(type), size: size, name: name, dark: dark)
            if name == "player-se" || name == "player-se-large-text" || name == "player-home-indicator" || name == "player-dark" {
                for key in ["player.favorite", "player.speed", "player.sleep", "player.download"] {
                    let frame = try XCTUnwrap(frames[key], key)
                    XCTAssertGreaterThanOrEqual(frame.height, 44, key)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0, key)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 1, key)
                    XCTAssertLessThanOrEqual(frame.maxY, size.height - 16, "\(key) must be on the first screen")
                }
            }
        }
        let oldTab = UserDefaults.standard.object(forKey: "navigation.selectedSection")
        defer { if let oldTab { UserDefaults.standard.set(oldTab, forKey: "navigation.selectedSection") } else { UserDefaults.standard.removeObject(forKey: "navigation.selectedSection") } }
        for tab in AppSection.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: "navigation.selectedSection")
            let frames = try await capture(RootView().environmentObject(store), size: CGSize(width: 375, height: 667), name: "root-\(tab.rawValue)")
            let mini = try XCTUnwrap(frames["miniPlayer"])
            let bar = try XCTUnwrap(frames["bottomTabs"])
            XCTAssertLessThanOrEqual(mini.maxY, bar.minY + 1, "Mini Player must remain above all five tabs")
            XCTAssertGreaterThan(mini.height, 40); XCTAssertGreaterThan(bar.height, 40)
        }
        UserDefaults.standard.set(AppSection.explore.rawValue, forKey: "navigation.selectedSection")
        for (name, size, type) in [
            ("root-home-indicator", CGSize(width: 393, height: 852), DynamicTypeSize.large),
            ("root-landscape", CGSize(width: 667, height: 375), .large),
            ("root-accessibility", CGSize(width: 375, height: 667), .accessibility5)
        ] {
            let frames = try await capture(RootView().environmentObject(store).dynamicTypeSize(type), size: size, name: name)
            let mini = try XCTUnwrap(frames["miniPlayer"]), bar = try XCTUnwrap(frames["bottomTabs"])
            XCTAssertLessThanOrEqual(mini.maxY, bar.minY + 1)
            for section in AppSection.allCases {
                let tab = try XCTUnwrap(frames["tab.\(section.rawValue)"])
                XCTAssertGreaterThanOrEqual(tab.width, 44); XCTAssertGreaterThanOrEqual(tab.height, 44)
                XCTAssertGreaterThanOrEqual(tab.minX, -1); XCTAssertLessThanOrEqual(tab.maxX, size.width + 1)
            }
        }
        store.player.unload(); store.change { $0.currentEpisodeID = nil }
        let frames = try await capture(RootView().environmentObject(store), size: CGSize(width: 375, height: 667), name: "root-without-player")
        XCTAssertNil(frames["miniPlayer"]); XCTAssertNotNil(frames["bottomTabs"])
        await store.flushPersistence()
    }
    @MainActor func testBlockedRecordFeedbackPersistsScopePreventsDuplicatesAndReportsFailure() async throws {
        let root = try temporary(), secure = MemorySecureStore()
        let authority = try ParentAuthority(store: secure)
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let store = AppStore(rootURL: root, parentAuthority: authority)
        await store.waitForPresentation()
        let show = Podcast(feedURL: URL(string: "https://example.com/blocked")!, title: "小说朗读", hasRSSMetadata: true)
        let one = Episode(podcastID: show.id, guid: "one", title: "小说朗读一", audioURL: URL(string: "https://example.com/one.mp3")!)
        let two = Episode(podcastID: show.id, guid: "two", title: "小说朗读二", audioURL: URL(string: "https://example.com/two.mp3")!)
        store.change { $0.merge(Feed(podcast: show, episodes: [one, two])); $0.favorites = [one.id, two.id]; $0.queue = [one.id, two.id] }
        var policy = store.policy; policy.showBlocklist = [show.id]; try store.updatePolicy(policy, grant: grant)
        let event = BlockEvent(show: show, episode: one, entry: .playback, result: store.result(show: show, episode: one))
        let feedback = ParentExceptionFeedback()
        var actions = 0
        feedback.allow(success: "已允许单集") {
            actions += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            try store.setException(show: show, episode: one, allow: true, grant: grant)
        }
        XCTAssertEqual(feedback.state, .saving)
        feedback.allow(success: "不应重复") { actions += 1 }
        while feedback.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(actions, 1); XCTAssertEqual(feedback.state, .success("已允许单集"))
        XCTAssertEqual(store.result(show: show, episode: one).decision, .allow)
        XCTAssertEqual(store.result(show: show, episode: two).decision, .block)
        XCTAssertTrue(store.policy.showBlocklist.contains(show.id))
        await store.waitForPresentation()
        XCTAssertEqual(store.presentation.favorites.map(\.id), [one.id])
        _ = try await capture(NavigationStack { BlockedRecordDetailView(event: event, grant: grant, feedback: feedback) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "parent-allowed-episode") { try await self.waitForFeedback(in: $0) }
        // A show exception must not clear an independently blocked episode.
        try store.setException(show: show, episode: two, allow: false, grant: grant)
        try store.setException(show: show, episode: nil, allow: true, grant: grant)
        XCTAssertEqual(store.result(show: show).decision, .allow)
        XCTAssertEqual(store.result(show: show, episode: two).decision, .block)
        let reopened = try ParentAuthority(store: secure)
        XCTAssertTrue(reopened.policy.episodeAllowlist.contains(one.id)); XCTAssertTrue(reopened.policy.showAllowlist.contains(show.id))
        secure.rejectWrites = true
        feedback.allow(success: "不能成功") { try store.setException(show: show, episode: two, allow: true, grant: grant) }
        while feedback.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .failure(let failure) = feedback.state else { return XCTFail("Expected visible storage failure") }
        XCTAssertTrue(failure.contains("允许失败")); XCTAssertTrue(store.policy.episodeBlocklist.contains(two.id))
        _ = try await capture(NavigationStack { BlockedRecordDetailView(event: event, grant: grant, feedback: feedback) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "parent-allow-failure") { try await self.waitForFeedback(in: $0) }
        secure.rejectWrites = false; authority.lock()
        feedback.allow(success: "不能过期授权") { try store.setException(show: show, episode: two, allow: true, grant: grant) }
        while feedback.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .failure(let expired) = feedback.state else { return XCTFail("Expected expired grant failure") }
        XCTAssertTrue(expired.contains("过期")); XCTAssertTrue(store.policy.episodeBlocklist.contains(two.id))
        await store.flushPersistence()
    }
    @MainActor private func waitForFeedback(in view: UIView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            view.layoutIfNeeded()
            if let frame = LayoutDiagnostics.frames["parent.feedback"], !frame.isEmpty, frame.minY >= 0, frame.maxY <= view.bounds.height { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let frame = try XCTUnwrap(LayoutDiagnostics.frames["parent.feedback"])
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, view.bounds.height, "Authorization feedback must scroll into view on a small phone")
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuietCastUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    @MainActor private func makeFixture(http: HTTPClient = HTTPClient(), discoveryHTTP: HTTPClient? = nil) async throws -> AppStore {
        let root = try temporary()
        var state = LibraryState(), snapshot = DiscoverySnapshot()
        let names = ["嗑嗑科学", "历史的回声", "生活观察", "科技与未来", "科学会客厅", "城市漫游", "自然之声", "周末读书"]
        for index in 0..<8 {
            let show = Podcast(feedURL: URL(string: "https://example.com/ui/\(index)")!, title: names[index], author: "节目团队\(index + 1)", summary: "这是用于布局验证的示例节目。", categories: ["Science"], hasRSSMetadata: true, rssFetchedAt: Date())
            let episode = Episode(podcastID: show.id, guid: "ui-\(index)", title: index == 0 ? "“阿飘”正传｜幽灵粒子里有“幽灵”吗？" : "第\(index + 1)期：一起探索世界的新发现", summary: "这是布局验证用的单集简介，不代表真实节目内容。", audioURL: URL(string: "https://example.com/ui/\(index).mp3")!, published: Date().addingTimeInterval(Double(-index) * 86400), duration: 4979)
            let feed = Feed(podcast: show, episodes: [episode]); state.merge(feed); snapshot.feeds[show.id] = CachedDiscoveryFeed(feed: feed, fetchedAt: Date())
            if index < 2 { state.subscriptions.insert(show.id) }
            if index == 0 { state.currentEpisodeID = episode.id; state.favorites.insert(episode.id); state.record(episodeID: episode.id, position: 48, duration: 4979) }
            if index == 1 { state.queue.append(episode.id) }
        }
        let audioFolder = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let current = state.episodes[state.currentEpisodeID!]!
        let audio = wave()
        try audio.write(to: OfflineFiles(directory: audioFolder).fileURL(current.id, fileExtension: "wav"))
        let pending = state.episodes[state.queue[0]]!
        let records = [current.id: DownloadRecord(id: current.id, episode: current, status: .downloaded, received: Int64(audio.count), expected: Int64(audio.count), fileExtension: "wav"), pending.id: DownloadRecord(id: pending.id, episode: pending, status: .paused)]
        try JSONEncoder().encode(records).write(to: audioFolder.appendingPathComponent("manifest.json"))
        state.subscriptionRefreshAttemptAt = Date()
        let feeds = snapshot.feeds.values.sorted { $0.feed.podcast.id < $1.feed.podcast.id }
        for kind in [DiscoveryKind.topShows, .topEpisodes, .personalized, .newShows] {
            let key = DiscoveryService.key(kind, country: "CN")
            snapshot.sections[key] = DiscoverySection(id: key, kind: kind, title: kind.rawValue, origin: kind == .topShows ? .appleShowsChart : kind == .topEpisodes ? .appleEpisodesChart : .localRecommendation, country: "CN", generatedAt: Date(), entries: feeds.enumerated().map { DiscoveryEntry(showID: $0.element.feed.podcast.id, episodeID: kind == .topEpisodes ? $0.element.feed.episodes[0].id : nil, rank: kind == .topShows || kind == .topEpisodes ? $0.offset + 1 : nil) })
        }
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
        try DiscoveryCacheStore(url: root.appendingPathComponent("discovery.json")).save(snapshot)
        let store = AppStore(rootURL: root, http: http, parentAuthority: try ParentAuthority(store: MemorySecureStore()), discoveryHTTP: discoveryHTTP)
        await store.waitForPresentation()
        store.discoveryCountry = "CN"
        return store
    }
    private func wave() -> Data {
        let count: UInt32 = 8000 * 2 * 120
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); number(count + 36); ascii("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000)); number(UInt16(2)); number(UInt16(16)); ascii("data"); number(count)
        data.append(Data(repeating: 0, count: Int(count))); return data
    }
    @MainActor private func capture<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false, beforeSnapshot: (@MainActor (UIView) async throws -> Void)? = nil) async throws -> [String: CGRect] {
        let captureID = UUID()
        LayoutDiagnostics.activeID = captureID; LayoutDiagnostics.frames = [:]
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")).environment(\.layoutCaptureID, captureID))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let landscape = size.width > size.height
        if scene.interfaceOrientation.isLandscape != landscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; LayoutDiagnostics.activeID = nil }
        window.frame = CGRect(origin: .zero, size: size)
        host.traitOverrides.horizontalSizeClass = .compact
        host.traitOverrides.verticalSizeClass = size.width > size.height ? .compact : .regular
        window.rootViewController = host
        window.overrideUserInterfaceStyle = dark ? .dark : .light; window.makeKeyAndVisible()
        host.view.frame = window.bounds; window.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await beforeSnapshot?(host.view)
        let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UIReview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.pngData()!.write(to: folder.appendingPathComponent(name + ".png"))
        print("UI_REVIEW_SCENE: \(name) orientation=\(scene.interfaceOrientation.rawValue) size=\(scene.coordinateSpace.bounds) window=\(window.bounds)")
        let metrics = LayoutDiagnostics.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys,.prettyPrinted]).write(to: folder.appendingPathComponent(name + ".json"))
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let frames = LayoutDiagnostics.frames
        LayoutDiagnostics.activeID = nil
        window.isHidden = true; window.rootViewController = nil
        return frames
    }
}

extension UIRedesignTests {
    @MainActor private func finishSearch(_ store: AppStore) async throws {
        let end = Date().addingTimeInterval(5)
        while store.searching && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.searching)
    }
    @MainActor func testEpisodeSearchIsIncrementalTransientAndResolvesOnlySelectedRSS() async throws {
        let transport = EpisodeSearchTransport(), root = try temporary()
        let authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let store = AppStore(rootURL: root, http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await store.waitForPresentation()
        let builds = await store.presentationWorker.buildCount
        store.search("黑洞")
        try await finishSearch(store)
        XCTAssertEqual(store.episodeResults.count, 2); XCTAssertEqual(store.results.count, 1)
        XCTAssertTrue(store.library.episodes.isEmpty); XCTAssertTrue(store.library.podcasts.isEmpty)
        let afterBuilds = await store.presentationWorker.buildCount
        XCTAssertEqual(builds, afterBuilds, "Incremental search must not rebuild or persist the full library")
        XCTAssertEqual(try store.parentSearchRecords(grant: grant).first?.count, 1)
        let first = try XCTUnwrap(store.episodeResults.first { $0.identity?.showDirectoryID == "100" })
        store.play(first.episode); store.enqueue(first.episode)
        XCTAssertNil(store.player.episode); XCTAssertTrue(store.library.queue.isEmpty)
        let episode = try await store.resolveSearchEpisode(first)
        XCTAssertEqual(episode.guid, "g-one"); XCTAssertEqual(episode.title, "黑洞之旅")
        XCTAssertEqual(store.library.episodes.count, 1)
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { $0.url?.path == "/lookup" }.count, 1)
        XCTAssertEqual(calls.filter { $0.url?.path.hasSuffix(".xml") == true }.map { $0.url!.absoluteString }, ["https://episode.example/100.xml"])
        await store.waitForPresentation()
        store.search("黑洞"); try await finishSearch(store)
        XCTAssertEqual(store.episodeResults.count, 2, "The same local GUID and remote candidate form one row")
        XCTAssertNil(store.episodeResults.first?.identity)
        XCTAssertEqual(try store.parentSearchRecords(grant: grant).first?.count, 2)
        _ = try await capture(NavigationStack { SearchEpisodeRow(hit: first) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "search-episode-row")
        _ = try await capture(NavigationStack { SearchEpisodeDetailView(hit: first) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "search-episode-detail")
        await store.flushPersistence()
    }
    @MainActor func testEpisodeSearchLateCancellationPartialFailuresAndLocalOfflineResults() async throws {
        let transport = EpisodeSearchTransport(); await transport.configure(holdOld: true)
        let store = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: try ParentAuthority(store: MemorySecureStore()))
        await store.waitForPresentation()
        store.search("旧词")
        let deadline = Date().addingTimeInterval(2)
        while await transport.requests.count < 6 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        store.search("新词"); try await finishSearch(store)
        await transport.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.episodeResults.count, 2)
        XCTAssertTrue(store.episodeResults.allSatisfy { $0.episode.title == "新词之旅" })
        store.search(""); XCTAssertTrue(store.episodeResults.isEmpty); XCTAssertTrue(store.results.isEmpty)
        await transport.configure(failEpisodes: true)
        store.search("黑洞"); try await finishSearch(store)
        XCTAssertFalse(store.results.isEmpty); XCTAssertTrue(store.episodeResults.isEmpty); XCTAssertNotNil(store.searchWarning); XCTAssertNil(store.searchError)
        var show = Podcast(feedURL: URL(string: "https://episode.example/local.xml")!, title: "本机科学", hasRSSMetadata: true)
        show.rssFetchedAt = Date()
        let episode = Episode(podcastID: show.id, guid: "local", title: "黑洞本机命中", audioURL: URL(string: "https://episode.example/local.mp3")!)
        store.change { $0.merge(Feed(podcast: show, episodes: [episode])) }; await store.waitForPresentation()
        await transport.configure(failAll: true)
        store.search("黑洞"); try await finishSearch(store)
        XCTAssertEqual(store.episodeResults.map(\.episode.id), [episode.id]); XCTAssertNil(store.searchError); XCTAssertNotNil(store.searchWarning)
        store.search("没有匹配"); try await finishSearch(store)
        XCTAssertTrue(store.episodeResults.isEmpty); XCTAssertNotNil(store.searchError)
        await store.flushPersistence()
    }
    @MainActor func testSearchEpisodeCannotBypassRuleChangesOrUnmatchedGUID() async throws {
        let transport = EpisodeSearchTransport(), authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let store = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await store.waitForPresentation()
        store.search("黑洞"); try await finishSearch(store)
        let hit = try XCTUnwrap(store.episodeResults.first { $0.identity?.showDirectoryID == "100" })
        XCTAssertEqual(store.result(show: hit.show, episode: hit.episode).decision, .review)
        var policy = store.policy; policy.episodeBlocklist.insert(hit.episode.id); policy.showAllowlist.insert(hit.show.id)
        try store.updatePolicy(policy, grant: grant)
        XCTAssertFalse(store.visibleSearchHit(hit))
        do { _ = try await store.resolveSearchEpisode(hit); XCTFail("Blocked candidate must not resolve") } catch { }
        let requests = await transport.requests.count; XCTAssertEqual(requests, 6)
        var rssShow = hit.show; rssShow.hasRSSMetadata = true
        store.change { $0.merge(Feed(podcast: rssShow, episodes: [hit.episode])) }
        await store.waitForPresentation()
        let noGUID = SearchEpisodeHit(show: hit.show, episode: Episode(podcastID: hit.show.id, guid: "directory:200", title: hit.episode.title, audioURL: hit.episode.audioURL), identity: DirectoryEpisodeIdentity(showDirectoryID: "100", episodeDirectoryID: "200", guid: nil, audioURL: hit.episode.audioURL, sourceURL: hit.identity!.sourceURL))
        XCTAssertFalse(store.visibleSearchHit(noGUID), "A GUID-less candidate must respect a known blocked enclosure even though it is absent from display indexes")
        policy.episodeBlocklist.removeAll(); policy.showAllowlist.removeAll(); policy.blockedAppleCategories = ["1533"]
        try store.updatePolicy(policy, grant: grant); XCTAssertFalse(store.visibleSearchHit(hit))
        policy.blockedAppleCategories = []; try store.updatePolicy(policy, grant: grant)
        await transport.configure(wrongGUID: true)
        // Isolate this case from the existing local enclosure: dedup correctly prefers that
        // known RSS row and would otherwise remove the deliberately conflicting candidate.
        let mismatchStore = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await mismatchStore.waitForPresentation()
        mismatchStore.search("宇宙"); try await finishSearch(mismatchStore)
        let wrong = try XCTUnwrap(mismatchStore.episodeResults.first { $0.identity?.showDirectoryID == "100" })
        do { _ = try await mismatchStore.resolveSearchEpisode(wrong); XCTFail("Same title or audio must not override a conflicting GUID") }
        catch { XCTAssertTrue(error.localizedDescription.contains("单集标识")) }
        XCTAssertNil(mismatchStore.library.episodes[wrong.episode.id]); XCTAssertNil(mismatchStore.player.episode); XCTAssertTrue(mismatchStore.library.queue.isEmpty)
        await mismatchStore.flushPersistence()
        await store.flushPersistence()
    }
    @MainActor func testSubscriptionRail120ShowsRendersLazilyReachesLastAndDoesNoIO() async throws {
        let root = try temporary(), transport = StubTransport([])
        let authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        var state = LibraryState()
        for index in 0...120 {
            let show = Podcast(feedURL: URL(string: "https://rail.example/\(index).xml")!, title: String(format: "科学节目 %03d", index), author: "科学团队", hasRSSMetadata: true, rssFetchedAt: Date())
            state.merge(Feed(podcast: show, episodes: [])); state.subscriptions.insert(show.id)
        }
        state.subscriptionRefreshAttemptAt = Date()
        try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
        // Eight visible cards reproduce the old rail's cardinality while retaining all 121 local shows.
        let baselineRoot = try temporary()
        var baselineState = state
        baselineState.subscriptions = Set(state.podcasts.values.sorted { $0.title < $1.title }.prefix(8).map(\.id))
        try AtomicLibraryStore(url: baselineRoot.appendingPathComponent("library.json")).save(baselineState)
        let baselineStore = AppStore(rootURL: baselineRoot, http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await baselineStore.waitForPresentation()
        let baselineStart = Date()
        _ = try await capture(NavigationStack { SubscriptionsView() }.environmentObject(baselineStore), size: CGSize(width: 375, height: 667), name: "subscriptions-8-first") { _ in
            print("RAIL_BENCHMARK initial8=\(Date().timeIntervalSince(baselineStart)) materialized=\(LayoutDiagnostics.frames.keys.filter { $0.hasPrefix("subscriptions.show.") }.count)")
        }
        let store = AppStore(rootURL: root, http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await store.waitForPresentation()
        let blocked = try XCTUnwrap(state.podcasts["https://rail.example/60.xml"])
        try store.setException(show: blocked, episode: nil, allow: false, grant: grant)
        await store.waitForPresentation(); await store.flushPersistence()
        XCTAssertEqual(store.presentation.subscribed.count, 120)
        let last = try XCTUnwrap(store.presentation.subscribed.last)
        let bytes = try Data(contentsOf: root.appendingPathComponent("library.json")), builds = await store.presentationWorker.buildCount
        let start = Date()
        _ = try await capture(NavigationStack { SubscriptionsView() }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "subscriptions-120-last") { view in
            let initialFrames = LayoutDiagnostics.frames.keys.filter { $0.hasPrefix("subscriptions.show.") }
            print("RAIL_BENCHMARK initial120=\(Date().timeIntervalSince(start)) materialized=\(initialFrames.count)")
            XCTAssertLessThan(initialFrames.count, 20, "The first viewport must not materialize all 120 cover views")
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UIScrollView }.first { $0.contentSize.width > $0.bounds.width + 200 && $0.bounds.height < 250 })
            let scrollStart = Date(); var steps = 0
            while steps < 150 {
                scroll.layoutIfNeeded()
                let end = max(0, scroll.contentSize.width - scroll.bounds.width)
                scroll.setContentOffset(CGPoint(x: min(end, scroll.contentOffset.x + scroll.bounds.width * 0.85), y: scroll.contentOffset.y), animated: false)
                try await Task.sleep(nanoseconds: 16_000_000); view.layoutIfNeeded(); steps += 1
                if abs(scroll.contentOffset.x - (scroll.contentSize.width - scroll.bounds.width)) < 1 { break }
            }
            let frame = try XCTUnwrap(LayoutDiagnostics.frames["subscriptions.show.\(last.id)"])
            XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, view.bounds.width + 1)
            XCTAssertFalse(LayoutDiagnostics.frames.keys.contains("subscriptions.show.\(blocked.id)"))
            print("RAIL_BENCHMARK scroll120=\(Date().timeIntervalSince(scrollStart)) steps=\(steps) last=\(last.id) lastFrame=\(frame)")
        }
        _ = try await capture(NavigationStack { ShowDetailView(show: last) }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "subscriptions-120-last-detail")
        XCTAssertEqual(store.library.podcasts[last.id]?.title, last.title)
        let calls = await transport.requests.count, after = await store.presentationWorker.buildCount
        XCTAssertEqual(calls, 0); XCTAssertEqual(after, builds)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
        _ = try await capture(NavigationStack { SubscriptionsView() }.environmentObject(store).dynamicTypeSize(.accessibility3), size: CGSize(width: 667, height: 375), name: "subscriptions-120-landscape-large-text")
        await store.flushPersistence()
    }
}

extension UIRedesignTests {
    @MainActor func testSearchScopeLayoutsAndChineseFirstReturnWithEpisodeResults() async throws {
        for (name, size, type, scope) in [
            ("search-combined", CGSize(width: 375, height: 667), DynamicTypeSize.large, 0),
            ("search-episodes", CGSize(width: 375, height: 667), DynamicTypeSize.large, 2),
            ("search-episodes-large-text", CGSize(width: 667, height: 375), DynamicTypeSize.accessibility3, 2)
        ] {
            let transport = EpisodeSearchTransport()
            let store = try await makeFixture(http: HTTPClient(transport: transport, directoryInterval: 0))
            defer { store.player.unload() }
            _ = try await capture(NavigationStack { HomeView() }.environmentObject(store).dynamicTypeSize(type), size: size, name: name) { view in
                let field = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "explore.search" })
                XCTAssertTrue(field.becomeFirstResponder())
                field.setMarkedText("黑洞", selectedRange: NSRange(location: 2, length: 0)); field.sendActions(for: .editingChanged)
                XCTAssertFalse(try XCTUnwrap(field.delegate?.textFieldShouldReturn)(field))
                XCTAssertFalse(field.isFirstResponder)
                try await self.finishSearch(store)
                XCTAssertEqual(store.episodeResults.count, 2)
                let picker = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UISegmentedControl }.first)
                picker.selectedSegmentIndex = scope; picker.sendActions(for: .valueChanged)
                try await Task.sleep(nanoseconds: 350_000_000); view.layoutIfNeeded()
                XCTAssertEqual(picker.numberOfSegments, 3)
                XCTAssertEqual(picker.selectedSegmentIndex, scope)
                if type.isAccessibilitySize { try await self.restAtBottom(view) }
            }
            await store.flushPersistence()
        }
    }
    @MainActor func testFreshCachedRSSStillAdoptsDirectoryPermissionChangesWithoutRSSRequest() async throws {
        let transport = StubTransport([]), authority = try ParentAuthority(store: MemorySecureStore())
        let grant = try authority.setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let store = AppStore(rootURL: try temporary(), http: HTTPClient(transport: transport, directoryInterval: 0), parentAuthority: authority)
        await store.waitForPresentation()
        let show = Podcast(feedURL: URL(string: "https://cached.example/science.xml")!, title: "科学", hasRSSMetadata: true, rssFetchedAt: Date())
        let episode = Episode(podcastID: show.id, guid: "cached", title: "访谈", audioURL: URL(string: "https://cached.example/1.mp3")!)
        store.change { $0.merge(Feed(podcast: show, episodes: [episode])); $0.queue = [episode.id] }
        await store.waitForPresentation()
        var policy = store.policy; policy.blockedAppleCategories = ["1533"]
        try store.updatePolicy(policy, grant: grant)
        var incoming = show
        incoming.hasRSSMetadata = false
        incoming.classificationObservations = [ClassificationObservation(namespace: "apple.podcasts.genre", id: "1533", name: "Science", source: .appleLookup, sourceURL: show.feedURL)]
        let updated = try await store.load(incoming)
        XCTAssertEqual(store.result(show: updated, episode: episode).decision, .block)
        XCTAssertTrue(store.library.queue.isEmpty)
        let calls = await transport.requests.count; XCTAssertEqual(calls, 0)
        await store.waitForPresentation(); XCTAssertFalse(store.presentation.visibleEpisodeIDs.contains(episode.id))
        await store.flushPersistence()
    }
}

extension UIRedesignTests {
    @MainActor func testRefreshFailureDetailsAreVisibleAndRespectParentRules() async throws {
        let transport = EpisodeSearchTransport(); await transport.configure(failAll: true)
        let store = try await makeFixture(http: HTTPClient(transport: transport, directoryInterval: 0))
        defer { store.player.unload() }
        let grant = try XCTUnwrap(store.authority).setup(pin: "246813", confirmation: "246813", recoveryAcknowledged: true)
        let blocked = try XCTUnwrap(store.presentation.subscribed.first)
        try store.setException(show: blocked, episode: nil, allow: false, grant: grant)
        store.change(updatePresentation: false) { $0.subscriptionRefreshAttemptAt = nil }
        await store.waitForPresentation()
        await store.refresh()
        XCTAssertEqual(store.refreshFailures.count, 2)
        let visible = try XCTUnwrap(store.refreshFailures.first { store.visible($0.show) })
        let frames = try await capture(NavigationStack { SubscriptionRefreshReportView() }.environmentObject(store), size: CGSize(width: 375, height: 667), name: "refresh-failure-details")
        XCTAssertNotNil(frames["refresh.failure.\(visible.id)"])
        XCTAssertNil(frames["refresh.failure.\(blocked.id)"])
        await store.flushPersistence()
    }
}

private actor NativeRefreshProbeTransport: HTTPTransport {
    var rssCount = 0
    var cancelled = 0
    private var holdFirst = false
    private var released = false
    func pauseFirst() { holdFirst = true }
    func release() { released = true }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.url?.host == "refresh.example" || (request.url?.host == "example.com" && request.url?.path.hasPrefix("/ui/") == true) {
            rssCount += 1
            do {
                while holdFirst && rssCount == 1 && !released { try await Task.sleep(nanoseconds: 10_000_000) }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            catch { cancelled += 1; throw error }
            data = Data("<rss version=\"2.0\"><channel><title>科学节目更新</title><item><title>更新单集</title><guid>one</guid><enclosure url=\"https://refresh.example/one.mp3\" type=\"audio/mpeg\"/></item></channel></rss>".utf8)
        } else { data = Data(#"{"results":[]}"#.utf8) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
extension UIRedesignTests {
    @MainActor func testNativeRefreshCompletesWhileStayingOnSubscriptionsAndHome() async throws {
        for (subscriptions, enteringRefresh) in [(true, false), (false, false), (false, true)] {
            let root = try temporary(), transport = NativeRefreshProbeTransport()
            if enteringRefresh { await transport.pauseFirst() }
            let http = HTTPClient(transport: transport, directoryInterval: 0)
            var state = LibraryState(), snapshot = DiscoverySnapshot()
            for index in 0..<13 {
                let show = Podcast(feedURL: URL(string: "https://refresh.example/\(index).xml")!, title: "科学节目 \(index)", hasRSSMetadata: true, rssFetchedAt: Date())
                let episode = Episode(podcastID: show.id, guid: "one", title: "已有单集", audioURL: URL(string: "https://refresh.example/\(index).mp3")!)
                let feed = Feed(podcast: show, episodes: [episode]); state.merge(feed); state.subscriptions.insert(show.id)
                snapshot.feeds[show.id] = CachedDiscoveryFeed(feed: feed, fetchedAt: Date())
            }
            state.subscriptionRefreshAttemptAt = Date().addingTimeInterval(enteringRefresh ? -7200 : -120)
            for kind in [DiscoveryKind.topShows, .topEpisodes, .personalized, .newShows] {
                let key = DiscoveryService.key(kind, country: "CN")
                snapshot.sections[key] = DiscoverySection(id: key, kind: kind, title: key, origin: .localLibrary, country: "CN", generatedAt: Date(), entries: [])
            }
            try AtomicLibraryStore(url: root.appendingPathComponent("library.json")).save(state)
            try DiscoveryCacheStore(url: root.appendingPathComponent("discovery.json")).save(snapshot)
            let store = AppStore(rootURL: root, http: http, parentAuthority: try ParentAuthority(store: MemorySecureStore()), discoveryHTTP: http)
            await store.waitForPresentation()
            let content = subscriptions ? AnyView(SubscriptionsView()) : AnyView(HomeView())
            _ = try await capture(NavigationStack { content }.environmentObject(store), size: CGSize(width: 375, height: 667), name: subscriptions ? "refresh-native-subscriptions" : enteringRefresh ? "refresh-native-home-on-entry" : "refresh-native-home") { view in
                let control = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UIScrollView }.compactMap(\.refreshControl).first)
                let prior = await transport.rssCount; XCTAssertEqual(prior, enteringRefresh ? 1 : 0)
                let start = Date()
                control.beginRefreshing(); control.sendActions(for: .valueChanged)
                if enteringRefresh { try await Task.sleep(nanoseconds: 50_000_000); await transport.release() }
                while Date().timeIntervalSince(start) < 6 {
                    if await transport.rssCount == 13 && !store.refreshing { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let calls = await transport.rssCount, cancelled = await transport.cancelled
                print("NATIVE_REFRESH_STAYING page=\(subscriptions ? "subscriptions" : "home") onEntry=\(enteringRefresh) rss=\(calls) cancelled=\(cancelled) interrupted=\(store.refreshWasCancelled) failures=\(store.refreshFailures.count) message=\(store.message ?? "none") elapsed=\(Date().timeIntervalSince(start))")
                XCTAssertEqual(calls, 13); XCTAssertEqual(cancelled, 0); XCTAssertFalse(store.refreshWasCancelled)
                XCTAssertTrue(store.refreshFailures.isEmpty); XCTAssertNil(store.message)
            }
            await store.flushPersistence()
        }
    }
}

extension UIRedesignTests {
    @MainActor func testManualHomeRefreshSurvivesCancelledCallerAndCoalescesRepeatPulls() async throws {
        let transport = NativeRefreshProbeTransport(); await transport.pauseFirst()
        let http = HTTPClient(transport: transport, directoryInterval: 0)
        let store = try await makeFixture(http: http, discoveryHTTP: http)
        store.player.unload()
        store.change(updatePresentation: false) { $0.subscriptionRefreshAttemptAt = Date().addingTimeInterval(-120) }
        let subscriptions = store.library.subscriptions, favorites = store.library.favorites, progress = store.library.progress
        let first = Task { await store.refreshHome() }
        let deadline = Date().addingTimeInterval(3)
        while await transport.rssCount < 1 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        first.cancel()
        let second = Task { await store.refreshHome() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.homeRefreshing); XCTAssertTrue(store.refreshing)
        let held = await transport.rssCount; XCTAssertEqual(held, 1)
        await transport.release()
        await first.value; await second.value
        let count = await transport.rssCount, cancelled = await transport.cancelled
        XCTAssertEqual(count, 2, "Concurrent refresh callers must share one subscription refresh")
        XCTAssertEqual(cancelled, 0); XCTAssertFalse(store.homeRefreshing); XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.refreshWasCancelled); XCTAssertTrue(store.refreshFailures.isEmpty); XCTAssertNil(store.message)
        XCTAssertNotNil(store.library.subscriptionRefreshedAt)
        XCTAssertEqual(store.library.subscriptions, subscriptions); XCTAssertEqual(store.library.favorites, favorites); XCTAssertEqual(store.library.progress, progress)
        print("MANUAL_REFRESH_OWNERSHIP cancelledCaller=true rss=\(count) cancelledRequests=\(cancelled) coalesced=true")
        await store.flushPersistence()
    }
}
