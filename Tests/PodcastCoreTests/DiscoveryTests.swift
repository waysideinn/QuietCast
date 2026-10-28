import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

actor DiscoveryTransport: HTTPTransport {
    var offline = false
    var calls: [URL] = []
    func setOffline() { offline = true }
    func fetch(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let url=request.url!;calls.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        let data: Data
        if url.host == "rss.marketingtools.apple.com" {
            let episode = url.lastPathComponent == "podcast-episodes.json"
            let values=(1...4).map { id -> [String:String] in ["id":episode ? "100\(id)":"\(id)","name":episode ? "第\(id)期科学访谈":"科学节目\(id)","kind":episode ? "podcast-episodes":"podcasts","url":"https://podcasts.apple.com/cn/podcast/test/id\(id)" + (episode ? "?i=100\(id)":"")] }
            data=try JSONSerialization.data(withJSONObject:["feed":["title":episode ? "热门单集":"热门节目","results":values]])
        } else if url.host == "itunes.apple.com" {
            data=try JSONSerialization.data(withJSONObject:["results":(1...4).map { id -> [String:Any] in ["collectionName":"科学节目\(id)","artistName":"团队\(id)","artistId":100+id,"feedUrl":"https://feeds.example/\(id)","collectionViewUrl":"https://podcasts.apple.com/cn/podcast/test/id\(id)","genreIds":["1533"],"genres":["Science"],"primaryGenreName":"Science"] }])
        } else {
            let id=Int(url.lastPathComponent) ?? 1
            data=Data("<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>科学节目\(id)</title><itunes:author>团队\(id)</itunes:author><itunes:category text=\"Science\"/><item><title>第\(id)期科学访谈</title><guid>g\(id)</guid><enclosure url=\"https://audio.example/\(id).mp3\" type=\"audio/mpeg\"/></item></channel></rss>".utf8)
        }
        return (data,HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    var count: Int { calls.count }
}
final class DiscoveryTests: XCTestCase {
    func rules() throws -> RuleSet { try RulesLoader.decode(Data(contentsOf:Bundle.module.url(forResource:"example-multisource",withExtension:"json",subdirectory:"Fixtures")!)) }
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    func show(_ index:Int, category:String="1533", author:String?=nil) -> Podcast {
        let url=URL(string:"https://feeds.example/\(index)")!
        return Podcast(feedURL:url,title:"节目\(index)",author:author ?? "团队\(index)",hasRSSMetadata:true,classificationObservations:[ClassificationObservation(namespace:"apple.podcasts.genre",id:category,name:"Science",source:.appleSearch,sourceURL:URL(string:"https://itunes.apple.com/search")!)])
    }
    func testModernShowAndEpisodeChartsParsedAsRealSeparateOrigins() async throws {
        let http=HTTPClient(transport:DiscoveryTransport(),directoryInterval:0),client=PublicChartsClient(http:HTTPClient(transport:DiscoveryTransport(),directoryInterval:0))
        let chart=try await PublicChartsClient(http:http).chart();XCTAssertEqual(chart.references.count,4);XCTAssertNil(chart.references[0].episodeDirectoryID)
        let episodes=try await client.chart(episodes:true);XCTAssertEqual(episodes.references.first?.episodeDirectoryID,"1001");XCTAssertEqual(episodes.references.first?.showDirectoryID,"1")
    }
    func testPublicEpisodeLookupMapsExactCollectionTrackAndGUID() async throws {
        let payload=Data(#"{"results":[{"kind":"podcast","trackId":1,"collectionId":1},{"kind":"podcast-episode","trackId":1001,"collectionId":1,"episodeGuid":"g1","genres":[{"name":"Science","id":"1533"}]},{"kind":"podcast-episode","trackId":1002,"collectionId":2,"episodeGuid":"g2"}]}"#.utf8)
        let transport=StubTransport([.data(200,payload)])
        let map=try await DirectoryClient(http:HTTPClient(transport:transport,directoryInterval:0)).lookupEpisodeIdentities(["1","2"])
        XCTAssertEqual(map["1:1001"]?.guid,"g1");XCTAssertEqual(map["2:1002"]?.guid,"g2");XCTAssertNil(map["1:1002"])
        let request=await transport.requests.first!;XCTAssertTrue(request.url!.absoluteString.contains("podcastEpisode"))
    }
    func testAmbiguousChartEpisodeTitlesNeverSelectArbitraryAudio() {
        let p=show(1),url=URL(string:"https://podcasts.apple.com/cn/podcast/test/id1?i=1001")!
        let reference=ChartReference(showDirectoryID:"1",episodeDirectoryID:"1001",title:"相同标题",rank:1,url:url)
        let ep=Episode(podcastID:p.id,guid:"g1",title:"相同标题",audioURL:URL(string:"https://audio.example/1.mp3")!)
        XCTAssertNil(PublicChartsClient.resolveEpisode(reference,in:Feed(podcast:p,episodes:[ep])))
        let identity=DirectoryEpisodeIdentity(showDirectoryID:"1",episodeDirectoryID:"1001",guid:"g1",audioURL:nil,sourceURL:url)
        XCTAssertEqual(PublicChartsClient.resolveEpisode(reference,in:Feed(podcast:p,episodes:[ep]),identity:identity)?.id,ep.id)
        var another=ep;another.guid="g2"
        XCTAssertEqual(PublicChartsClient.resolveEpisode(reference,in:Feed(podcast:p,episodes:[ep,another]),identity:identity)?.id,ep.id)
    }
    func testEveryDiscoveryOriginRechecksCurrentPolicyAndRemovesDuplicates() throws {
        let allowed=show(1),blocked=show(2);var policy=ParentalPolicy();policy.showBlocklist.insert(blocked.id)
        let f=ContentFilter(rules:try rules(),policy:policy)
        let feeds=[allowed.id:CachedDiscoveryFeed(feed:Feed(podcast:allowed,episodes:[]),fetchedAt:Date()),blocked.id:CachedDiscoveryFeed(feed:Feed(podcast:blocked,episodes:[]),fetchedAt:Date())]
        for origin in [DiscoveryOrigin.appleShowsChart,.appleEpisodesChart,.appleCategoryChart,.directoryDiscovery,.directoryEpisodes,.localRecommendation,.localLibrary] {
            let section=DiscoverySection(id:"test",kind:.topShows,title:"source",origin:origin,country:"CN",generatedAt:Date(),entries:[DiscoveryEntry(showID:allowed.id),DiscoveryEntry(showID:blocked.id),DiscoveryEntry(showID:allowed.id)])
            XCTAssertEqual(DiscoveryPresentation.entries(section,feeds:feeds,filter:f).map(\.showID),[allowed.id])
        }
    }
    func testCategoryEntryAndResultsRemainBlockedAfterCacheRestore() throws {
        let p=show(1,category:"1484"),r=try rules();var policy=ParentalPolicy();policy.blockedAppleCategories=["1483"]
        let section=DiscoverySection(id:"test",kind:.category,title:"Drama",origin:.appleCategoryChart,country:"CN",generatedAt:Date(),entries:[DiscoveryEntry(showID:p.id)],categoryKey:"1484")
        var snapshot=DiscoverySnapshot();snapshot.sections[section.id]=section;snapshot.feeds[p.id]=CachedDiscoveryFeed(feed:Feed(podcast:p,episodes:[]),fetchedAt:Date())
        let disk=DiscoveryCacheStore(url:try temporary().appendingPathComponent("cache.json"));try disk.save(snapshot)
        let restored=try disk.load();XCTAssertEqual(DiscoveryPresentation.entries(restored.sections["test"]!,feeds:restored.feeds,filter:ContentFilter(rules:r,policy:policy)).count,0)
    }
    func testLocalInterestsUseSubscriptionsFavoritesAndRecentFrequency() {
        let p=show(1),ep1=Episode(podcastID:p.id,guid:"1",title:"ep1",audioURL:URL(string:"https://audio.example/1")!),ep2=Episode(podcastID:p.id,guid:"2",title:"ep2",audioURL:URL(string:"https://audio.example/2")!)
        var state=LibraryState();state.merge(Feed(podcast:p,episodes:[ep1,ep2]));state.subscriptions.insert(p.id)
        let subscribed=LocalRecommender.interests(library:state)["1533"]!
        state.favorites.insert(ep1.id);state.record(episodeID:ep1.id,position:10,duration:100);state.record(episodeID:ep2.id,position:20,duration:100)
        let richer=LocalRecommender.interests(library:state)["1533"]!;XCTAssertTrue(richer>subscribed+4)
    }
    func testRecommendationDiversityExcludesSubscribedBlockedAndDuplicates() throws {
        let candidates=(1...7).map { show($0,author:$0<5 ? "同一账号":"其他\($0)") };var state=LibraryState();state.subscriptions.insert(candidates[6].id)
        var policy=ParentalPolicy();policy.showBlocklist.insert(candidates[5].id)
        let ranked=LocalRecommender.ranked(candidates+[candidates[0]],library:state,filter:ContentFilter(rules:try rules(),policy:policy))
        XCTAssertFalse(ranked.contains { $0.id==candidates[6].id || $0.id==candidates[5].id });XCTAssertEqual(Set(ranked.map(\.id)).count,ranked.count);XCTAssertTrue(ranked.filter { $0.author=="同一账号" }.count<=2)
    }
    func testCacheFirstAndNetworkFailureKeepsLastValidSection() async throws {
        let root=try temporary(),url=root.appendingPathComponent("discovery.json"),transport=DiscoveryTransport()
        let service=DiscoveryService(http:HTTPClient(transport:transport,directoryInterval:0),cacheURL:url,candidateLimit:4)
        let filter=ContentFilter(rules:try rules(),policy:ParentalPolicy())
        let loaded=await service.load(.topShows,library:LibraryState(),filter:filter)
        let key=DiscoveryService.key(.topShows,country:"CN")
        XCTAssertEqual(loaded.snapshot.sections[key]?.origin,.appleShowsChart);XCTAssertEqual(loaded.snapshot.sections[key]?.entries.count,4)
        let before=await transport.count;let cached=await service.load(.topShows,library:LibraryState(),filter:filter);let after=await transport.count
        XCTAssertTrue(cached.fromCache);XCTAssertEqual(before,after)
        var stale=loaded.snapshot;stale.sections[key]?.generatedAt=Date().addingTimeInterval(-2*86400);try DiscoveryCacheStore(url:url).save(stale)
        await transport.setOffline()
        let reopened=DiscoveryService(http:HTTPClient(transport:transport,directoryInterval:0),cacheURL:url,candidateLimit:4)
        let failed=await reopened.load(.topShows,library:LibraryState(),filter:filter)
        XCTAssertNotNil(failed.error);XCTAssertEqual(failed.snapshot.sections[key]?.entries.count,4)
    }
    func testUnavailableChartFallbackIsExplicitDirectoryDiscovery() async throws {
        let searchJSON=Data(#"{"results":[{"collectionName":"科学访谈","feedUrl":"https://feeds.example/1","genres":["Science"],"genreIds":["1533"]}]}"#.utf8)
        let rss=Data("<rss><channel><title>科学访谈</title></channel></rss>".utf8)
        // 404 modern, 404 legacy, public search, RSS.
        let transport=StubTransport([.data(404,Data()),.data(404,Data()),.data(200,searchJSON),.data(200,rss)])
        let service=DiscoveryService(http:HTTPClient(transport:transport,directoryInterval:0),cacheURL:try temporary().appendingPathComponent("cache.json"),candidateLimit:4)
        let loaded=await service.load(.topShows,library:LibraryState(),filter:ContentFilter(rules:try rules(),policy:ParentalPolicy()))
        let section=loaded.snapshot.sections[DiscoveryService.key(.topShows,country:"CN")]
        XCTAssertEqual(section?.origin,.directoryDiscovery);XCTAssertEqual(section?.title,"播客发现");XCTAssertNotNil(loaded.error)
    }
    func testAllCategoryNodesHaveStandardIDsAndLocalizedAliasInheritance() throws {
        XCTAssertTrue(PodcastCategories.all.allSatisfy { $0.appleID != nil })
        XCTAssertEqual(Set(PodcastCategories.all.map(\.id)).count,PodcastCategories.all.count)
        XCTAssertEqual(PodcastCategories.category("1536")?.path.last,"Mathematics")
        var policy=ParentalPolicy();policy.blockedAppleCategories=["1304"]
        var p=show(1);p.classificationObservations=[ClassificationObservation(namespace:"apple.podcasts.genre",id:"1498",name:"語言學習",source:.appleSearch,sourceURL:p.feedURL)]
        XCTAssertEqual(ContentFilter(rules:try rules(),policy:policy).evaluate(show:p).decision,.block)
        XCTAssertFalse(ContentFilter(rules:try rules(),policy:policy).isCategoryAllowed(PodcastCategories.category("1498")!))
    }
    func testOlderDiscoveryCacheCannotOverwriteFreshRSSMetadata() {
        var fresh=show(1);fresh.title="最新 RSS 标题";fresh.rssFetchedAt=Date()
        var old=fresh;old.title="旧缓存标题";old.rssFetchedAt=Date().addingTimeInterval(-86400)
        var state=LibraryState();state.merge(Feed(podcast:fresh,episodes:[]));state.merge(Feed(podcast:old,episodes:[]))
        XCTAssertEqual(state.podcasts[fresh.id]?.title,"最新 RSS 标题")
    }
    func testFutureAndExpiredCacheDatesAreNotFresh() {
        let now=Date();XCTAssertTrue(CacheFreshness.isFresh(now.addingTimeInterval(-100),ttl:86400,now:now))
        XCTAssertFalse(CacheFreshness.isFresh(now.addingTimeInterval(-90000),ttl:86400,now:now));XCTAssertFalse(CacheFreshness.isFresh(now.addingTimeInterval(100),ttl:86400,now:now))
    }
}
