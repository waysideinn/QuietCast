import XCTest
import CryptoKit
import Foundation
import Security
import Network
import PodcastCore
@testable import QuietCast

private struct TestKeychain: SecureRecordStore {
    let service: String
    var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"verification"] }
    func read() throws -> Data? {
        var q=query;q[kSecReturnData as String]=true
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        return result as? Data
    }
    func write(_ data: Data) throws {
        let update=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if update==errSecItemNotFound {
            var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status=SecItemAdd(q as CFDictionary,nil)
            guard status==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        } else if update != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(update)) }
    }
    func removeTestItem() { SecItemDelete(query as CFDictionary) }
}

/// Ephemeral localhost fixture server, present only in the test bundle, never in the shipped app.
private final class LocalAudioServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private let queue=DispatchQueue(label:"org.quietcast.verification.http")
    private var connections:[NWConnection]=[]
    private var startCompleted=false
    init(body:Data) throws { self.body=body;listener=try NWListener(using:.tcp,on:.any) }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.startCompleted,let port=self.listener.port else { return };self.startCompleted=true
                    continuation.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/fixture.wav")!)
                case .failed(let error): if !self.startCompleted { self.startCompleted=true;continuation.resume(throwing:error) }
                default:break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return };self.connections.append(connection);connection.start(queue:self.queue)
                connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] _,_,_,error in
                    guard let self,error==nil else { connection.cancel();return }
                    var data=Data("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
                    data.append(self.body)
                    connection.send(content:data,completion:.contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue:queue)
        }
    }
    func stop() { queue.async { self.listener.cancel();self.connections.forEach { $0.cancel() } } }
}

final class NativeIOTests:XCTestCase {
    @MainActor func testPauseCancelsPendingAudioActivationWithoutStuckBuffering() async throws {
        let root = try temporary(), audio = root.appendingPathComponent("pause.wav")
        try wave().write(to: audio)
        let show = Podcast(feedURL: URL(string: "https://verification.invalid/pause")!, title: "Pause verification", hasRSSMetadata: true)
        let episode = Episode(podcastID: show.id, guid: "pause", title: "Pause", audioURL: audio)
        let player = PodcastPlayer(); player.authorize = { _, _ in true }; defer { player.unload() }
        player.load(episode, show: show, localURL: audio, position: 2, preferences: PlayerPreferences(), autoplay: false)
        try await wait { !player.buffering }
        let start = Date(); player.resume(); player.pause()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.buffering)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.buffering)
        XCTAssertEqual(player.position, 2, accuracy: 0.3)
    }
    private func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("QuietCastVerification-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    private func wave() -> Data {
        let count=18*8000*2
        var data=Data("RIFF".utf8)
        func u32(_ n:UInt32) { var v=n.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        func u16(_ n:UInt16) { var v=n.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        u32(UInt32(count+36));data.append(Data("WAVEfmt ".utf8));u32(16);u16(1);u16(1);u32(8000);u32(16000);u16(2);u16(16)
        data.append(Data("data".utf8));u32(UInt32(count));data.append(Data(repeating:0,count:count));return data
    }
    @MainActor private func wait(_ condition:()->Bool,seconds:Double=20,file:StaticString=#filePath,line:UInt=#line) async throws {
        let deadline=Date().addingTimeInterval(seconds)
        while !condition() && Date()<deadline { try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertTrue(condition(),"Native asynchronous operation did not reach the expected state",file:file,line:line)
    }
    /// Packaging regression: the actual app bundle must contain B's approved trial asset.
    func testBundledProductionTrialRulesMatchApprovedRelease() throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"content-filter",withExtension:"json"))
        let data=try Data(contentsOf:url)
        XCTAssertEqual(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"b1d875e5b49415f74c111389f0ec1b3c189abc37cdc547dd5c21e18d3393d765")
        let rules=try RulesLoader.decode(data)
        XCTAssertEqual(rules.schemaVersion,"1.1")
        XCTAssertEqual(rules.status,"production")
        XCTAssertEqual(rules.ruleVersion,"fiction-zh-2026-10-27-v1")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,"1.1.3")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String,"6")
    }
    func testApplicationIdentityAndBackgroundAudioConfiguration() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier,"org.quietcast.family")
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey:"UIBackgroundModes") as? [String] ?? []).contains("audio"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey:"MinimumOSVersion") as? String,"16.0")
    }
    func testPINUsesRealIsolatedSimulatorKeychainAndSurvivesReopen() throws {
        let store=TestKeychain(service:"org.quietcast.verification."+UUID().uuidString)
        defer { store.removeTestItem() }
        let first=try ParentAuthority(store:store)
        let grant=try first.setup(pin:"680421",confirmation:"680421",recoveryAcknowledged:true)
        var policy=first.policy;policy.blockedAppleCategories=["1483"];try first.updatePolicy(policy,grant:grant)
        let reopened=try ParentAuthority(store:store)
        XCTAssertTrue(reopened.configured);XCTAssertEqual(reopened.policy.blockedAppleCategories,["1483"])
        XCTAssertThrowsError(try reopened.authenticate(pin:"000000"))
        XCTAssertNoThrow(try reopened.authenticate(pin:"680421"))
    }
    @MainActor func testAVPlayerRestoresSavedPositionAndSavesOnPause() async throws {
        let root=try temporary(),audio=root.appendingPathComponent("local.wav");try wave().write(to:audio)
        let show=Podcast(feedURL:URL(string:"https://verification.invalid/rss")!,title:"Native audio verification",hasRSSMetadata:true)
        let ep=Episode(podcastID:show.id,guid:"native-a",title:"Local verification fixture",audioURL:audio)
        let player=PodcastPlayer();player.authorize={_,_ in true};var saved:[String:Double]=[:]
        player.onProgress={id,position,_,_ in saved[id]=position}
        defer { player.unload() }
        player.load(ep,show:show,localURL:audio,position:4,preferences:PlayerPreferences(),autoplay:false)
        try await wait { !player.buffering }
        XCTAssertEqual(player.position,4,accuracy:0.3);XCTAssertFalse(player.isPlaying)
        player.resume();try await wait({player.position>5},seconds:12);player.pause()
        XCTAssertGreaterThan(try XCTUnwrap(saved[ep.id]),5);XCTAssertFalse(player.isPlaying)
    }
    @MainActor func testSwitchAndExecutionGateCannotOverwriteOrResumeBlockedEpisode() async throws {
        let root=try temporary(),audio=root.appendingPathComponent("local.wav");try wave().write(to:audio)
        let show=Podcast(feedURL:URL(string:"https://verification.invalid/rss")!,title:"Verification",hasRSSMetadata:true)
        let a=Episode(podcastID:show.id,guid:"a",title:"A",audioURL:audio),b=Episode(podcastID:show.id,guid:"b",title:"B",audioURL:audio)
        var allowed=true;let player=PodcastPlayer();player.authorize={_,_ in allowed};var saved:[String:Double]=[:]
        player.onProgress={id,position,_,_ in saved[id]=position};defer { player.unload() }
        player.load(a,show:show,localURL:audio,position:3,preferences:PlayerPreferences(),autoplay:false);try await wait { !player.buffering }
        player.load(b,show:show,localURL:audio,position:9,preferences:PlayerPreferences(),autoplay:false);try await wait { !player.buffering };player.save()
        XCTAssertEqual(try XCTUnwrap(saved[a.id]),3,accuracy:0.3);XCTAssertEqual(try XCTUnwrap(saved[b.id]),9,accuracy:0.3)
        allowed=false;player.resume();player.seek(15)
        XCTAssertFalse(player.isPlaying);XCTAssertEqual(player.position,9,accuracy:0.3)
    }
    @MainActor func testLegacyDownloadIndexMigratesWithoutLosingAudio() async throws {
        let root=try temporary()
        let show=Podcast(feedURL:URL(string:"https://verification.invalid/rss")!,title:"Legacy download",hasRSSMetadata:true)
        let episode=Episode(podcastID:show.id,guid:"legacy",title:"Legacy audio",audioURL:URL(string:"https://verification.invalid/opaque")!)
        let legacy=OfflineFiles(directory:root).fileURL(episode.id)
        try wave().write(to:legacy)
        let record=DownloadRecord(id:episode.id,episode:episode,status:.downloaded)
        try JSONEncoder().encode([episode.id:record]).write(to:root.appendingPathComponent("manifest.json"))
        let manager=DownloadManager(directory:root,sessionIdentifier:"org.quietcast.verification."+UUID().uuidString)
        await manager.waitUntilReady()
        let local=try XCTUnwrap(manager.localURL(episode.id))
        XCTAssertEqual(local.pathExtension,"wav");XCTAssertEqual(try Data(contentsOf:local),wave())
        XCTAssertFalse(FileManager.default.fileExists(atPath:legacy.path))
        await manager.flushPersistence()
        let saved=try JSONDecoder().decode([String:DownloadRecord].self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(saved[episode.id]?.fileExtension,"wav")
        manager.delete(episode.id);XCTAssertEqual(manager.diskUsage,0)
    }
    @MainActor func testBackgroundURLSessionDownloadDeleteAndOfflineFilePlayback() async throws {
        let root=try temporary(),server=try LocalAudioServer(body:wave());let remote=try await server.start();defer { server.stop() }
        let show=Podcast(feedURL:URL(string:"https://verification.invalid/rss")!,title:"Download verification",hasRSSMetadata:true)
        let episode=Episode(podcastID:show.id,guid:"download",title:"Local transfer verification",audioURL:remote)
        let manager=DownloadManager(directory:root.appendingPathComponent("Audio"),sessionIdentifier:"org.quietcast.verification."+UUID().uuidString)
        await manager.waitUntilReady()
        var allowed=true;manager.authorize={_ in allowed};var failure:String?;manager.onError={failure=$0}
        manager.start(episode)
        try await wait({manager.records[episode.id]?.status == .downloaded || failure != nil},seconds:45)
        XCTAssertNil(failure);let local=try XCTUnwrap(manager.localURL(episode.id));XCTAssertEqual(local.pathExtension,"wav");XCTAssertEqual(try Data(contentsOf:local),wave());XCTAssertGreaterThan(manager.diskUsage,0)
        server.stop()
        let player=PodcastPlayer();player.authorize={_,_ in allowed};var playbackError:String?;player.onError={playbackError=$0};defer { player.unload() }
        player.load(episode,show:show,localURL:local,position:2,preferences:PlayerPreferences(),autoplay:false)
        try await wait { !player.buffering };XCTAssertNil(playbackError);player.resume();try await wait({player.position>3 || playbackError != nil},seconds:12);XCTAssertNil(playbackError);XCTAssertGreaterThan(player.position,3);player.pause();player.unload()
        allowed=false;player.load(episode,show:show,localURL:local,position:0,preferences:PlayerPreferences(),autoplay:true);XCTAssertNil(player.episode)
        manager.delete(episode.id);XCTAssertNil(manager.records[episode.id]);XCTAssertFalse(FileManager.default.fileExists(atPath:local.path));XCTAssertEqual(manager.diskUsage,0)
        manager.start(episode);XCTAssertNil(manager.records[episode.id])
    }
}
