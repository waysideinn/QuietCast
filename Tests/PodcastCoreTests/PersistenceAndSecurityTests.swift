import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

final class MemorySecureStore: SecureRecordStore {
    var data: Data?
    var rejectWrites = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { if rejectWrites { throw PodcastError.storage("test failure") }; self.data = data }
}
final class PersistenceAndSecurityTests: XCTestCase {
    func testBackgroundWriterCannotOverwriteNewProgressWithDelayedOlderSnapshot() async throws {
        let root = try temporary(), url = root.appendingPathComponent("ordered.json"), writer = LibraryWriter(url: url)
        var newest = LibraryState(); newest.searchHistory = ["科学"]
        try await writer.save(newest, revision: 2)
        try await writer.save(LibraryState(), revision: 1)
        XCTAssertEqual(try AtomicLibraryStore(url: url).load().searchHistory, ["科学"])
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func feed() -> Feed {
        let p = Podcast(feedURL: URL(string: "https://example.com/rss")!, title: "访谈", hasRSSMetadata: true)
        return Feed(podcast: p, episodes: (1...2).map { Episode(podcastID: p.id, guid: "g\($0)", title: "ep\($0)", audioURL: URL(string: "https://example.com/\($0).mp3")!) })
    }
    func testSubscriptionProgressAndQueueSurviveReopening() throws {
        let disk = AtomicLibraryStore(url: try temporary().appendingPathComponent("library.json")); let f = feed()
        var state = LibraryState(); state.merge(f); state.subscriptions.insert(f.podcast.id); state.favorites.insert(f.episodes[0].id)
        state.queue = f.episodes.map(\.id); state.currentEpisodeID = f.episodes[1].id
        state.record(episodeID: f.episodes[0].id, position: 123, duration: 900)
        state.record(episodeID: f.episodes[1].id, position: 80, duration: 100, finished: true)
        try disk.save(state); let restored = try disk.load()
        XCTAssertEqual(restored, state); XCTAssertEqual(restored.progress[f.episodes[0].id]?.position, 123)
        XCTAssertTrue(restored.progress[f.episodes[1].id]!.completed)
        state.record(episodeID: f.episodes[0].id, position: .nan, duration: 100)
        XCTAssertEqual(state.progress[f.episodes[0].id]?.position, 123)
    }
    func testCheckpointsDoNotInflateLocalListeningFrequency() {
        let f=feed();var state=LibraryState();state.merge(f)
        state.beginPlayback(episodeID:f.episodes[0].id)
        for tick in 1...5 { state.record(episodeID:f.episodes[0].id,position:Double(tick)*10,duration:1000) }
        XCTAssertEqual(state.progress[f.episodes[0].id]?.playCount,1)
        state.beginPlayback(episodeID:f.episodes[0].id);XCTAssertEqual(state.progress[f.episodes[0].id]?.playCount,2)
    }
    func testFeedRefreshRetainsProgressAndSubscriptions() {
        let f = feed(); var state = LibraryState(); state.merge(f); state.subscriptions.insert(f.podcast.id)
        state.record(episodeID: f.episodes[0].id, position: 40, duration: 500); state.merge(f)
        XCTAssertEqual(state.progress[f.episodes[0].id]?.position, 40); XCTAssertTrue(state.subscriptions.contains(f.podcast.id))
    }
    func testCorruptLibraryNotSilentlyResetOrOverwritten() throws {
        let url = try temporary().appendingPathComponent("library.json"), data = Data("broken".utf8)
        try data.write(to: url); XCTAssertThrowsError(try AtomicLibraryStore(url: url).load()); XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testOldPlaybackCallbackCannotOverwriteNewSession() {
        var session = ProgressSession(); let first = session.switchTo("a"); let second = session.switchTo("b")
        XCTAssertFalse(session.accepts(episodeID: "a", generation: first)); XCTAssertFalse(session.accepts(episodeID: "b", generation: first)); XCTAssertTrue(session.accepts(episodeID: "b", generation: second))
    }
    func testOfflineFileInstallationQuotaReadAndDeleteWithoutNetwork() throws {
        let root = try temporary(), audio = root.appendingPathComponent("download.tmp"), bytes = Data("offline audio fixture".utf8)
        try bytes.write(to: audio); let storage = OfflineFiles(directory: root.appendingPathComponent("Audio"))
        XCTAssertThrowsError(try storage.install(audio, id: "episode", storageLimit: 1))
        try storage.install(audio, id: "episode", storageLimit: 1000)
        XCTAssertEqual(try Data(contentsOf: storage.fileURL("episode")), bytes); XCTAssertEqual(storage.usage, Int64(bytes.count))
        try storage.delete("episode"); XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL("episode").path)); XCTAssertEqual(storage.usage, 0)
    }
    func testPBKDF2KnownVectorAndConstantTimeComparison() throws {
        let key = try PINKDF.derive(pin: "password", salt: Data("saltSALTsaltSALT".utf8), rounds: 2)
        // Cross-checked against Python hashlib.pbkdf2_hmac SHA-256.
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "2b77275cc3120b1513f6f3e03649fd493376526056cd04462aa6fef64a5d19f0")
        XCTAssertTrue(PINKDF.constantTimeEqual(key, key)); XCTAssertFalse(PINKDF.constantTimeEqual(key, Data(repeating: 0, count: 32)))
    }
    func testPINSetupVerificationPolicyAndNoPlaintext() throws {
        let secure = MemorySecureStore(); let authority = try ParentAuthority(store: secure)
        XCTAssertThrowsError(try authority.setup(pin: "123", confirmation: "123", recoveryAcknowledged: true))
        XCTAssertThrowsError(try authority.setup(pin: "901728", confirmation: "901728", recoveryAcknowledged: false))
        let grant = try authority.setup(pin: "901728", confirmation: "901728", recoveryAcknowledged: true)
        XCTAssertFalse(String(data: secure.data!, encoding: .utf8)!.contains("901728"))
        var policy = authority.policy; policy.blockedAppleCategories = ["1483"]; policy.showBlocklist.insert("https://example.com/rss"); try authority.updatePolicy(policy, grant: grant)
        let reopened = try ParentAuthority(store: secure); XCTAssertTrue(reopened.configured)
        XCTAssertEqual(reopened.policy.showBlocklist, policy.showBlocklist)
        XCTAssertEqual(reopened.policy.blockedAppleCategories, policy.blockedAppleCategories)
        XCTAssertThrowsError(try reopened.updatePolicy(ParentalPolicy(), grant: grant))
        let newGrant = try reopened.authenticate(pin: "901728"); try reopened.changePIN("678905", confirmation: "678905", grant: newGrant)
        XCTAssertNoThrow(try ParentAuthority(store: secure).authenticate(pin: "678905"))
    }
    func testPINFailureDelaySurvivesReopening() throws {
        let secure = MemorySecureStore(); var now = Date(timeIntervalSince1970: 1000)
        let authority = try ParentAuthority(store: secure, now: { now }); _ = try authority.setup(pin: "567890", confirmation: "567890", recoveryAcknowledged: true)
        for _ in 0..<5 { XCTAssertThrowsError(try authority.authenticate(pin: "000000")) }
        let reopened = try ParentAuthority(store: secure, now: { now }); XCTAssertThrowsError(try reopened.authenticate(pin: "567890"))
        now = now.addingTimeInterval(31); XCTAssertNoThrow(try reopened.authenticate(pin: "567890"))
    }
    func testGrantExpiresAndBackgroundLockInvalidatesIt() throws {
        let secure = MemorySecureStore(); var now = Date()
        let authority = try ParentAuthority(store: secure, now: { now }); let grant = try authority.setup(pin: "567890", confirmation: "567890", recoveryAcknowledged: true)
        now = now.addingTimeInterval(121); XCTAssertFalse(authority.isAuthorized(grant)); XCTAssertThrowsError(try authority.updatePolicy(ParentalPolicy(), grant: grant))
        let second = try authority.authenticate(pin: "567890"); authority.lock(); XCTAssertFalse(authority.isAuthorized(second))
    }
    func testCorruptKeychainFailsClosedAndFailedWriteDoesNotMutatePolicy() throws {
        let secure = MemorySecureStore(); secure.data = Data("corrupt".utf8); XCTAssertThrowsError(try ParentAuthority(store: secure))
        secure.data = nil; let authority = try ParentAuthority(store: secure); let grant = try authority.setup(pin: "567890", confirmation: "567890", recoveryAcknowledged: true)
        secure.rejectWrites = true; var policy = authority.policy; policy.enabled = false
        XCTAssertThrowsError(try authority.updatePolicy(policy, grant: grant)); XCTAssertTrue(authority.policy.enabled)
    }
    func testInterruptionResumesOnlyWithPriorIntentSystemPermissionAndCurrentAccess() {
        var recovery = InterruptionRecovery()
        recovery.began(wasPlaying: true)
        XCTAssertTrue(recovery.ended(systemAllowsResume: true, contentAllowed: true))
        XCTAssertFalse(recovery.ended(systemAllowsResume: true, contentAllowed: true))
        recovery.began(wasPlaying: false)
        XCTAssertFalse(recovery.ended(systemAllowsResume: true, contentAllowed: true))
        recovery.began(wasPlaying: true)
        XCTAssertFalse(recovery.ended(systemAllowsResume: false, contentAllowed: true))
        recovery.began(wasPlaying: true)
        XCTAssertFalse(recovery.ended(systemAllowsResume: true, contentAllowed: false))
        recovery.began(wasPlaying: true); recovery.userPausedOrRouteLost()
        XCTAssertFalse(recovery.ended(systemAllowsResume: true, contentAllowed: true))
    }
    func testImportedRulesRequireGrantAndPersistOnlyAfterValidation() throws {
        let secure = MemorySecureStore(), authority = try ParentAuthority(store: secure)
        let grant = try authority.setup(pin: "567890", confirmation: "567890", recoveryAcknowledged: true)
        let data = try Data(contentsOf: Bundle.module.url(forResource: "example-fiction", withExtension: "json", subdirectory: "Fixtures")!)
        _ = try authority.importRules(data, grant: grant); XCTAssertEqual(try ParentAuthority(store: secure).importedRules, data)
        XCTAssertThrowsError(try authority.importRules(Data("bad".utf8), grant: grant)); XCTAssertEqual(authority.importedRules, data)
        authority.lock(); XCTAssertThrowsError(try authority.importRules(data, grant: grant))
    }
}
