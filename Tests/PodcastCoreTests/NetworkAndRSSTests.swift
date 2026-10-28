import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

actor StubTransport: HTTPTransport {
    enum Response: Sendable { case data(Int, Data), timeout }
    var responses: [Response]
    var requests: [URLRequest] = []
    init(_ responses: [Response]) { self.responses = responses }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch responses.removeFirst() {
        case .data(let status, let data): return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .timeout: throw URLError(.timedOut)
        }
    }
    var count: Int { requests.count }
}
final class NetworkAndRSSTests: XCTestCase {
    func testDiscoveryClientBoundsDirectoryWaitAndDoesNotRetryTimeout() async throws {
        let transport = StubTransport([.timeout, .data(200, Data())])
        let client = DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0, defaultTimeout: 8, defaultRetries: 0))
        do { _ = try await client.search("科学"); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.timeoutInterval, 8)
    }
    func testDiscoveryRSSUsesShortTimeoutWithoutSilentRetry() async throws {
        let transport = StubTransport([.timeout, .data(200, Data())])
        do {
            _ = try await FeedClient(http: HTTPClient(transport: transport, directoryInterval: 0)).fetch(URL(string: "https://example.com/slow")!, timeout: 6, retries: 0)
            XCTFail("A timed out discovery source must report failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.timeoutInterval, 6)
    }
    let url = URL(string: "https://example.com/feed.xml")!
    let xml = """
    <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
    <title>科学 &amp; 生活</title><description><![CDATA[<p>每周访谈</p>]]></description><itunes:author>作者</itunes:author><itunes:category text="Science"/><itunes:image href="https://example.com/art.jpg"/><language>zh-cn</language><itunes:type>episodic</itunes:type>
    <item><title>第一集</title><guid>g1</guid><description>概要</description><content:encoded><![CDATA[<p>完整 <b>介绍</b></p>]]></content:encoded><pubDate>Sun, 25 Oct 2026 12:00:00 +0800</pubDate><itunes:duration>1:02:03</itunes:duration><enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
    <item><title>无 guid</title><enclosure url="https://example.com/2.m4a" type="audio/mp4"/></item>
    <item><title>没有音频不能播放</title></item>
    </channel></rss>
    """
    func testRSSParsesNamespacesCDATAEnclosuresAndStableIdentity() throws {
        let feed = try RSSParser.parse(Data(xml.utf8), feedURL: url)
        XCTAssertEqual(feed.podcast.title, "科学 & 生活"); XCTAssertEqual(feed.podcast.author, "作者")
        XCTAssertEqual(feed.podcast.categories, ["Science"]); XCTAssertTrue(feed.podcast.hasRSSMetadata)
        XCTAssertEqual(feed.episodes.count, 2); XCTAssertEqual(feed.episodes.first?.duration, 3723)
        XCTAssertTrue(feed.episodes.first!.summary.contains("完整")); XCTAssertFalse(feed.episodes.first!.summary.contains("<b>"))
        XCTAssertNotNil(feed.episodes.first!.published); XCTAssertEqual(feed.episodes.first!.id, Identity.hash(feed.podcast.id + "\ng1"))
        XCTAssertEqual(feed.episodes.last!.guid, "https://example.com/2.m4a")
    }
    func testMalformedAndEntityRSSRejected() {
        for value in ["hello", "<rss><channel><title>Broken", "<html/>", "<rss><channel/></rss>", "<!DOCTYPE rss [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><rss/>"] { XCTAssertThrowsError(try RSSParser.parse(Data(value.utf8), feedURL: url)) }
    }
    func testUTF16EntityDeclarationsCannotBypassDTDGuard() {
        let value = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE rss [<!ENTITY x \"test\">]><rss><channel><title>&x;</title></channel></rss>"
        XCTAssertThrowsError(try RSSParser.parse(value.data(using: .utf16)!, feedURL: url))
    }
    func testDurationAndURLValidation() throws {
        XCTAssertEqual(RSSParser.duration("12:30"), 750); XCTAssertNil(RSSParser.duration("unknown"))
        for text in ["file:///tmp/a", "javascript:foo", "https://user:pass@example.com/feed", ""] { XCTAssertThrowsError(try PublicURL.parse(text)) }
        XCTAssertEqual(Identity.feed(URL(string: "HTTPS://EXAMPLE.com/feed?q=1#part")!), "https://example.com/feed?q=1")
    }
    func testDirectorySearchUsesLiveEndpointContractAndEncodesChinese() async throws {
        let body = Data(#"{"results":[{"collectionName":"科学","artistName":"作者","feedUrl":"https://example.com/feed.xml","genres":["Science"]},{"collectionName":"no feed"}]}"#.utf8)
        let transport = StubTransport([.data(200, body)])
        let shows = try await DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0)).search("中文 科学")
        XCTAssertEqual(shows.count, 1); XCTAssertEqual(shows.first?.title, "科学")
        let request = await transport.requests.first!
        XCTAssertEqual(request.url!.host, "itunes.apple.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "term" }?.value, "中文 科学")
        XCTAssertEqual(query.first { $0.name == "entity" }?.value, "podcast")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 20)
    }
    func testHTTPCacheAndForcedRefresh() async throws {
        let transport = StubTransport([.data(200, Data("first".utf8)), .data(200, Data("second".utf8))])
        let http = HTTPClient(transport: transport, directoryInterval: 0)
        let first = try await http.get(url); let cached = try await http.get(url)
        XCTAssertEqual(first, cached); let count = await transport.count; XCTAssertEqual(count, 1)
        let next = try await http.get(url, force: true); XCTAssertNotEqual(next, first)
    }
    func testNetworkTimeoutRetriesThenSurfacesFailure() async throws {
        let transport = StubTransport([.timeout, .timeout]); let http = HTTPClient(transport: transport)
        do { _ = try await http.get(url); XCTFail("timeout should fail") } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let count = await transport.count; XCTAssertEqual(count, 2)
    }
    func testHTTPFailureAndMalformedSearchHandled() async throws {
        for response in [StubTransport.Response.data(404, Data()), .data(200, Data("invalid json".utf8))] {
            let transport = StubTransport([response]); let directory = DirectoryClient(http: HTTPClient(transport: transport, directoryInterval: 0))
            do { _ = try await directory.search("history"); XCTFail("expected failure") } catch { }
        }
    }
    func testTransientFailureRetriesSuccessfully() async throws {
        let transport = StubTransport([.data(503, Data()), .data(200, Data(xml.utf8))])
        let feed = try await FeedClient(http: HTTPClient(transport: transport)).fetch(url)
        XCTAssertEqual(feed.episodes.count, 2); let count = await transport.count; XCTAssertEqual(count, 2)
    }
    func testExternalLinksCannotPlayRawAudioOrFiles() throws {
        XCTAssertEqual(try ExternalLink.resolve(URL(string: "quietcast://feed?url=https%3A%2F%2Fexample.com%2Frss")!), .rss(URL(string: "https://example.com/rss")!))
        XCTAssertEqual(try ExternalLink.resolve(URL(string: "https://podcasts.apple.com/cn/podcast/a/id12345?i=8")!), .directoryID("12345"))
        XCTAssertEqual(try ExternalLink.resolve(URL(string: "quietcast://feed?url=https%3A%2F%2Fpodcasts.apple.com%2Fcn%2Fpodcast%2Fa%2Fid12345")!), .directoryID("12345"))
        for text in ["file:///tmp/a.mp3", "https://example.com/a.mp3", "quietcast://play?url=https://example.com/a.mp3", "https://podcasts.apple.com/a"] { XCTAssertThrowsError(try ExternalLink.resolve(URL(string: text)!)) }
    }
}
