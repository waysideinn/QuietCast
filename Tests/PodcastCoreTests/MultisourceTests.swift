import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

final class MultisourceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793001600) // 2026-10-26 UTC
    func rules(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> RuleSet {
        let url = Bundle.module.url(forResource: "example-multisource", withExtension: "json", subdirectory: "Fixtures")!
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var category = (root["categories"] as! [[String: Any]])[0]; edit(&category); root["categories"] = [category]
        return try RulesLoader.decode(JSONSerialization.data(withJSONObject: root))
    }
    func show(_ title: String = "科学访谈", id: String? = nil, name: String = "创作团队", role: PublisherRole = .unknown, observed: Date? = nil, genre: String? = nil) -> Podcast {
        var p = Podcast(feedURL: URL(string: "https://shared-host.example/feed")!, title: title, author: name, hasRSSMetadata: true)
        p.publisherIdentities = [PublisherIdentity(namespace: "apple.podcasts.artist", id: id, name: name, role: role, source: .appleLookup, sourceURL: URL(string: "https://itunes.apple.com/lookup?id=1")!, observedAt: observed ?? now)]
        if let genre { p.classificationObservations = [ClassificationObservation(namespace: "apple.podcasts.genre", id: genre, name: "目录分类", source: .appleSearch, sourceURL: URL(string: "https://itunes.apple.com/search")!, observedAt: observed ?? now)] }
        return p
    }
    func publisher(status: String = "confirmed", scope: String = "allShows", role: String = "publisher", ids: [String] = [], action: String = "block") -> [String: Any] {
        ["id":"account-test","enabled":true,"identities":[["namespace":"apple.podcasts.artist","id":"123"]],"names":["创作团队"],"role":role,"scope":scope,"showIDs":ids,"action":action,"score":6,"confirmation":["status":status,"by":"test-reviewer","at":"2026-10-01T00:00:00Z","evidence":["test account evidence"]],"expiresAt":"2027-01-01T00:00:00Z","note":"Test-only account rule"]
    }
    func testPreparedShowFilterMatchesLiveGateAcrossMetadataAndExceptions() throws {
        let rules = try rules { $0["publisherRules"] = [publisher()] }
        for show in [show(), show("小说朗读", id: "123", genre: "1483"), show(id: "456", observed: now.addingTimeInterval(-100 * 86400)), show(genre: "1533")] {
            let episode = Episode(podcastID: show.id, guid: "prepared", title: "科学与小说朗读", audioURL: URL(string: "https://example.com/a.mp3")!)
            var allowed = ParentalPolicy(); allowed.episodeAllowlist = [episode.id]
            var denied = ParentalPolicy(); denied.showAllowlist = [show.id]; denied.episodeBlocklist = [episode.id]
            var custom = ParentalPolicy(); custom.customKeywords = ["科学"]
            for policy in [ParentalPolicy(), allowed, denied, custom] {
                for date in [now, now.addingTimeInterval(365 * 86400)] {
                    let filter = ContentFilter(rules: rules, policy: policy, now: date)
                    let prepared = filter.prepare(show: show)
                    XCTAssertEqual(prepared.evaluate(), filter.evaluate(show: show))
                    XCTAssertEqual(prepared.evaluate(episode: episode), filter.evaluate(show: show, episode: episode))
                }
            }
        }
    }
    func testV11LoadsAndOldV10StillLoads() throws {
        XCTAssertEqual(try rules().schemaVersion,"1.1")
        let old = Bundle.module.url(forResource: "example-fiction", withExtension: "json", subdirectory: "Fixtures")!
        XCTAssertEqual(try RulesLoader.decode(Data(contentsOf: old)).schemaVersion,"1.0")
    }
    func testExactAppleIDAndNameAreSeparateFromOrdinaryRSSCategory() throws {
        let f = ContentFilter(rules: try rules(), policy: ParentalPolicy(), now: now)
        XCTAssertEqual(f.evaluate(show: show(genre:"1483")).decision,.review)
        var p = show(); p.classificationObservations = [ClassificationObservation(namespace:"rss.itunes.category",name:"Fiction",path:["Fiction"],source:.rss,sourceURL:p.feedURL,observedAt:now)]
        XCTAssertEqual(f.evaluate(show:p).decision,.review)
        p.classificationObservations?[0].namespace = "rss.category"
        XCTAssertEqual(f.evaluate(show:p).decision,.allow)
        p.classificationObservations?[0].namespace = "rss.itunes.category"; p.classificationObservations?[0].name = "Fiction research"; p.classificationObservations?[0].path = ["Fiction research"]
        XCTAssertEqual(f.evaluate(show:p).decision,.allow)
    }
    func testConfirmedStableAccountBlocksButSameHostDoesNot() throws {
        let r = try rules { $0["publisherRules"] = [publisher()] }
        let f = ContentFilter(rules:r,policy:ParentalPolicy(),now:now)
        let verdict = f.evaluate(show:show(id:"123"))
        XCTAssertEqual(verdict.decision,.block); XCTAssertEqual(verdict.evidence.first?.matchedIdentity,"123")
        XCTAssertEqual(verdict.evidence.first?.family,"publishers")
        XCTAssertEqual(f.evaluate(show:show(id:"456",name:"不同作者")).decision,.allow)
    }
    func testSameNameDifferentIDAndMissingIDNeverBecomeHighConfidenceBlock() throws {
        let f = ContentFilter(rules:try rules { $0["publisherRules"] = [publisher()] },policy:ParentalPolicy(),now:now)
        for p in [show(id:"456"),show()] { let v=f.evaluate(show:p); XCTAssertEqual(v.decision,.review); XCTAssertEqual(v.score,0); XCTAssertEqual(v.evidence.first?.kind,"identityUnavailable") }
    }
    func testMissingAccountIdentityRequiresReviewWhenConfirmedRestrictionsAreEnabled() throws {
        let f=ContentFilter(rules:try rules { $0["publisherRules"]=[publisher()] },policy:ParentalPolicy(),now:now)
        XCTAssertEqual(f.evaluate(show:show(name:"一个没有账号信息的新 RSS 作者")).decision,.review)
    }
    func testCategoryAndCategoryDerivedKeywordAreNotCountedTwice() throws {
        let r=try rules { c in
            var rows=c["classificationRules"] as! [[String:Any]];rows[0]["action"]="score";c["classificationRules"]=rows
            c["keywords"]=[["id":"derived-category-word","term":"Fiction","score":6,"fields":["showCategories"],"note":"same observation"]]
        }
        var p=show(genre:"1483");p.categories=["Fiction"]
        XCTAssertEqual(ContentFilter(rules:r,policy:ParentalPolicy(),now:now).evaluate(show:p).score,3)
    }
    func testPendingRejectedExpiredAndStaleAccounts() throws {
        let pending = ContentFilter(rules:try rules { $0["publisherRules"] = [publisher(status:"pending")] },policy:ParentalPolicy(),now:now)
        XCTAssertEqual(pending.evaluate(show:show(id:"123")).decision,.review)
        let rejected = ContentFilter(rules:try rules { $0["publisherRules"] = [publisher(status:"rejected")] },policy:ParentalPolicy(),now:now)
        XCTAssertEqual(rejected.evaluate(show:show(id:"123")).decision,.allow)
        let expired = try rules { var p=publisher();p["expiresAt"]="2026-10-20T00:00:00Z";$0["publisherRules"]=[p] }
        XCTAssertEqual(ContentFilter(rules:expired,policy:ParentalPolicy(),now:now).evaluate(show:show(id:"123")).decision,.allow)
        let f=ContentFilter(rules:try rules { $0["publisherRules"]=[publisher()] },policy:ParentalPolicy(),now:now)
        XCTAssertEqual(f.evaluate(show:show(id:"123",observed:now.addingTimeInterval(-40*86400))).decision,.review)
    }
    func testMixedAccountSelectedShowsDoesNotBlockOtherPrograms() throws {
        let p=show(id:"123")
        let r=try rules { $0["publisherRules"]=[publisher(scope:"selectedShows",role:"aggregator",ids:[p.id])] }
        let f=ContentFilter(rules:r,policy:ParentalPolicy(),now:now)
        XCTAssertEqual(f.evaluate(show:p).decision,.block)
        var other=p;other.feedURL=URL(string:"https://shared-host.example/nonfiction")!
        XCTAssertEqual(f.evaluate(show:other).decision,.allow)
        XCTAssertThrowsError(try rules { $0["publisherRules"]=[publisher(role:"aggregator")] })
    }
    func testKnownAggregatorObservationCannotBeRecastAsWholeAccountPublisher() throws {
        let f=ContentFilter(rules:try rules { $0["publisherRules"]=[publisher()] },policy:ParentalPolicy(),now:now)
        XCTAssertEqual(f.evaluate(show:show(id:"123",role:.aggregator)).decision,.review)
    }
    func testThreeSourcesCanBeDisabledIndependentlyAndCombined() throws {
        let r=try rules { c in
            var recognition=c["recognition"] as! [String:Any];recognition["appleCategories"]=false;recognition["keywords"]=false;c["recognition"]=recognition;c["publisherRules"]=[publisher()]
        }
        let f=ContentFilter(rules:r,policy:ParentalPolicy(),now:now)
        XCTAssertEqual(f.evaluate(show:show("小说朗读",id:"456",name:"他人",genre:"1483")).decision,.allow)
        XCTAssertEqual(f.evaluate(show:show(id:"123")).decision,.block)
        let joint=try rules { c in
            var config=c["recognition"] as! [String:Any];config["combination"]="allEnabledSources";c["recognition"]=config;c["publisherRules"]=[publisher()]
            var cats=c["classificationRules"] as! [[String:Any]];cats[0]["action"]="score";c["classificationRules"]=cats
        }
        let g=ContentFilter(rules:joint,policy:ParentalPolicy(),now:now)
        XCTAssertEqual(g.evaluate(show:show("小说朗读",id:"123",genre:"1483")).decision,.block)
        XCTAssertEqual(g.evaluate(show:show("小说朗读",id:"123")).decision,.allow)
    }
    func testMetadataFamiliesDoNotMultiplyCorrelatedScores() throws {
        let r=try rules { c in
            var cats=c["classificationRules"] as! [[String:Any]];cats[0]["action"]="score";var other=cats[0];other["id"]="same-category-twice";cats.append(other);c["classificationRules"]=cats
        }
        let verdict=ContentFilter(rules:r,policy:ParentalPolicy(),now:now).evaluate(show:show(genre:"1483"))
        XCTAssertEqual(verdict.score,3);XCTAssertEqual(verdict.evidence.map(\.contribution).reduce(0,+),3)
    }
    func testParentExceptionsStillOutrankNewSources() throws {
        let p=show(id:"123",genre:"1483");let ep=Episode(podcastID:p.id,guid:"g",title:"episode",audioURL:URL(string:"https://example.com/a.mp3")!)
        var policy=ParentalPolicy();policy.showBlocklist.insert(p.id);policy.episodeAllowlist.insert(ep.id);policy.blockedAppleCategories=["1483"]
        let f=ContentFilter(rules:try rules { $0["publisherRules"]=[publisher()] },policy:policy,now:now)
        XCTAssertEqual(f.evaluate(show:p,episode:ep).decision,.allow);XCTAssertEqual(f.evaluate(show:p).decision,.block)
    }
    func testParentCategoryHierarchyAndEveryEntryPath() throws {
        var policy=ParentalPolicy();policy.blockedAppleCategories=["1483"]
        let r=try rules(),p=show(genre:"1484"),f=ContentFilter(rules:r,policy:policy,now:now)
        XCTAssertFalse(f.isCategoryAllowed(PodcastCategories.category("1483")!));XCTAssertFalse(f.isCategoryAllowed(PodcastCategories.category("1484")!));XCTAssertFalse(f.isCategoryAllowed(PodcastCategories.category("1485")!))
        for entry in AccessEntry.allCases { XCTAssertThrowsError(try AccessGate(filter:f).authorize(entry,show:p)) }
        policy.blockedAppleCategories=["1484"]
        let childOnly=ContentFilter(rules:r,policy:policy,now:now)
        XCTAssertTrue(childOnly.isCategoryAllowed(PodcastCategories.category("1483")!));XCTAssertFalse(childOnly.isCategoryAllowed(PodcastCategories.category("1484")!));XCTAssertTrue(childOnly.isCategoryAllowed(PodcastCategories.category("1485")!))
    }
    func testOldLibraryAndPolicyCanBeDecodedWithoutNewMetadata() throws {
        let p=show();var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        json.removeValue(forKey:"classificationObservations");json.removeValue(forKey:"publisherIdentities")
        let decoded=try JSONDecoder().decode(Podcast.self,from:JSONSerialization.data(withJSONObject:json));XCTAssertNil(decoded.publisherIdentities)
        var policy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ParentalPolicy())) as! [String:Any];policy.removeValue(forKey:"blockedAppleCategories")
        XCTAssertNil(try JSONDecoder().decode(ParentalPolicy.self,from:JSONSerialization.data(withJSONObject:policy)).blockedAppleCategories)
    }
    func testRefreshPreservesDirectoryIdentityAndReplacesOldSnapshot() {
        let directory=show(id:"123",genre:"1483")
        var rss=Podcast(feedURL:directory.feedURL,title:"RSS 标题",author:"RSS 作者",hasRSSMetadata:true)
        rss.publisherIdentities=[PublisherIdentity(namespace:"rss.itunes.author",name:"RSS 作者",source:.rss,sourceURL:rss.feedURL,observedAt:now)]
        let first=rss.mergingDirectoryMetadata(from:directory)
        XCTAssertTrue(first.publisherIdentities!.contains { $0.id=="123" });XCTAssertEqual(first.author,"RSS 作者")
        var replacement=show(id:"456",genre:"1533");replacement.publisherIdentities?[0].observedAt=now.addingTimeInterval(10);replacement.classificationObservations?[0].observedAt=now.addingTimeInterval(10)
        let updated=first.mergingDirectoryMetadata(from:replacement)
        XCTAssertFalse(updated.publisherIdentities!.contains { $0.id=="123" });XCTAssertTrue(updated.publisherIdentities!.contains { $0.id=="456" })
    }
    func testMalformedNewRulesAndVersionMislabelRejected() throws {
        XCTAssertThrowsError(try rules { $0["publisherRules"]=[publisher(scope:"selectedShows")] })
        XCTAssertThrowsError(try rules { var p=publisher();p["identities"]=[];$0["publisherRules"]=[p] })
        XCTAssertThrowsError(try rules { var config=$0["recognition"] as! [String:Any];config["unknown"]=true;$0["recognition"]=config })
        let url=Bundle.module.url(forResource:"example-multisource",withExtension:"json",subdirectory:"Fixtures")!;var root=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];root["schemaVersion"]="1.0"
        XCTAssertThrowsError(try RulesLoader.decode(JSONSerialization.data(withJSONObject:root)))
    }
    func testRSSCapturesCategoryPathAndPublisherClaimsWithoutUsingHost() throws {
        let xml="""
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>访谈</title><itunes:author>作者甲</itunes:author><itunes:owner><itunes:name>运营乙</itunes:name></itunes:owner><itunes:category text="Fiction"><itunes:category text="Drama"/></itunes:category></channel></rss>
        """
        let feed=try RSSParser.parse(Data(xml.utf8),feedURL:URL(string:"https://shared-host.example/rss")!)
        XCTAssertTrue(feed.podcast.classificationObservations!.contains { $0.path==["Fiction","Drama"] })
        XCTAssertEqual(Set(feed.podcast.publisherIdentities!.map(\.name)),Set(["作者甲","运营乙"]))
        XCTAssertTrue(feed.podcast.publisherIdentities!.allSatisfy { $0.id==nil })
    }
}
