import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

final class FilteringTests: XCTestCase {
    func fixture() throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: "example-fiction", withExtension: "json", subdirectory: "Fixtures")!) }
    func rules(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> RuleSet {
        var json = try JSONSerialization.jsonObject(with: fixture()) as! [String: Any]; modify(&json)
        return try RulesLoader.decode(JSONSerialization.data(withJSONObject: json))
    }
    func show(_ title: String = "科学访谈", summary: String = "每周讨论科学与生活", complete: Bool = true) -> Podcast {
        Podcast(feedURL: URL(string: "https://example.com/rss")!, title: title, summary: summary, hasRSSMetadata: complete)
    }
    func episode(_ show: Podcast, title: String = "第10集 科学访谈") -> Episode { Episode(podcastID: show.id, guid: "001", title: title, audioURL: URL(string: "https://example.com/a.mp3")!) }
    func testSampleLoads() throws { XCTAssertEqual(try rules().schemaVersion, "1.0") }
    func testStrongKeywordBlocksAndExplains() throws {
        let result = ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show("小说朗读"))
        XCTAssertEqual(result.decision, .block); XCTAssertEqual(result.score, 12)
        XCTAssertEqual(result.evidence.first?.ruleID, "sample-audiobook"); XCTAssertEqual(result.evidence.first?.fields, [.showTitle])
        XCTAssertEqual(result.categoryIDs, ["fiction-audiobooks"])
    }
    func testSingleOrdinaryKeywordDoesNotBlock() throws {
        let result = ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show("连载访谈"))
        XCTAssertEqual(result.decision, .allow); XCTAssertEqual(result.score, 2.25)
    }
    func testCombinationRequiresSameField() throws {
        let f = ContentFilter(rules: try rules(), policy: ParentalPolicy())
        XCTAssertEqual(f.evaluate(show: show("小说连载")).decision, .block)
        XCTAssertEqual(f.evaluate(show: show("小说", summary: "连载")).decision, .allow)
    }
    func testReviewThreshold() throws {
        let r = try rules { root in var c = root["categories"] as! [[String: Any]]; c[0]["thresholds"] = ["review": 2, "block": 8]; root["categories"] = c }
        XCTAssertEqual(ContentFilter(rules: r, policy: ParentalPolicy()).evaluate(show: show("连载访谈")).decision, .review)
    }
    func testAnyFieldCombination() throws {
        let r = try rules { root in var c = root["categories"] as! [[String: Any]]; var combos = c[0]["combinationKeywords"] as! [[String: Any]]; combos[0]["scope"] = "anyField"; c[0]["combinationKeywords"] = combos; root["categories"] = c }
        let result = ContentFilter(rules: r, policy: ParentalPolicy()).evaluate(show: show("小说", summary: "连载"))
        XCTAssertEqual(result.decision, .review); XCTAssertEqual(result.score, 7.5)
    }
    func testTraditionalChineseWidthAndPunctuation() throws {
        XCTAssertEqual(TextNormalizer.normalize("小 說，朗讀 ＡＢＣ"), "小说朗读abc")
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show("小 說，朗讀")).decision, .block)
    }
    func testExclusionCannotEraseStrongEvidence() throws {
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show("小说研究 小说朗读")).decision, .block)
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show("小说研究 连载", summary: "访谈")).decision, .review)
    }
    func testNormalInterviewAndNumberedEpisodesAllowed() throws {
        let p = show(); XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: p, episode: episode(p)).decision, .allow)
    }
    func testRepeatedHitsDoNotMultiplyScore() throws {
        let p = show("连载连载连载", summary: "连载")
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: p).score, 2.25)
    }
    func testSpecificParentEpisodeAllowOverridesShowBlock() throws {
        let p = show("小说朗读"), ep = episode(show("小说朗读")); var policy = ParentalPolicy()
        policy.showBlocklist.insert(p.id); policy.episodeAllowlist.insert(ep.id)
        let f = ContentFilter(rules: try rules(), policy: policy)
        XCTAssertEqual(f.evaluate(show: p, episode: ep).decision, .allow); XCTAssertEqual(f.evaluate(show: p).decision, .block)
        policy.episodeBlocklist.insert(ep.id)
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: policy).evaluate(show: p, episode: ep).decision, .block)
    }
    func testParentRulesOverrideAutomaticLists() throws {
        let p = show("小说朗读"); var policy = ParentalPolicy(); policy.showAllowlist.insert(p.id)
        let r = try rules { root in var c = root["categories"] as! [[String: Any]]; c[0]["showBlocklist"] = [p.id]; root["categories"] = c }
        XCTAssertEqual(ContentFilter(rules: r, policy: policy).evaluate(show: p).decision, .allow)
    }
    func testListSpecificityAndConflictingDeny() throws {
        let p = show(), ep = episode(show())
        let r = try rules { root in var c = root["categories"] as! [[String: Any]]; c[0]["showBlocklist"] = [p.id]; c[0]["episodeAllowlist"] = [ep.id]; root["categories"] = c }
        XCTAssertEqual(ContentFilter(rules: r, policy: ParentalPolicy()).evaluate(show: p, episode: ep).decision, .allow)
    }
    func testDisabledModeAndMissingRulesFailClosed() throws {
        XCTAssertEqual(ContentFilter(rules: nil, policy: ParentalPolicy()).evaluate(show: show()).decision, .block)
        var policy = ParentalPolicy(); policy.enabled = false
        XCTAssertEqual(ContentFilter(rules: nil, policy: policy).evaluate(show: show()).decision, .allow)
        policy.enabled = true; policy.enabledCategoryIDs.insert("missing")
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: policy).evaluate(show: show()).decision, .block)
    }
    func testIncompleteDirectoryMetadataRequiresReview() throws { XCTAssertEqual(ContentFilter(rules: try rules(), policy: ParentalPolicy()).evaluate(show: show(complete: false)).decision, .review) }
    func testCustomKeywordRequiresExplicitParentIntent() throws {
        var policy = ParentalPolicy(); policy.customKeywords = ["科学"]
        XCTAssertEqual(ContentFilter(rules: try rules(), policy: policy).evaluate(show: show()).decision, .block)
    }
    func testAllExecutionEntrancesDenyAndRulesUpdateInvalidatesDownloadedContent() throws {
        let p = show(), ep = episode(show()); let first = try rules()
        let f = ContentFilter(rules: first, policy: ParentalPolicy())
        for entry in AccessEntry.allCases { XCTAssertNoThrow(try AccessGate(filter: f).authorize(entry, show: p, episode: ep)) }
        let updated = try rules { root in root["ruleVersion"] = "test-2"; var c = root["categories"] as! [[String: Any]]; c[0]["episodeBlocklist"] = [ep.id]; root["categories"] = c }
        for entry in AccessEntry.allCases { XCTAssertThrowsError(try AccessGate(filter: .init(rules: updated, policy: ParentalPolicy())).authorize(entry, show: p, episode: ep), entry.rawValue) }
    }
    func testMalformedRuleFilesRejected() throws {
        for modifier: (inout [String: Any]) -> Void in [
            { $0["schemaVersion"] = "2.0" }, { $0["unknown"] = true },
            { root in var c = root["categories"] as! [[String: Any]]; c[0]["thresholds"] = ["review": 8, "block": 4]; root["categories"] = c },
            { root in var c = root["categories"] as! [[String: Any]]; c[0]["keywords"] = c[0]["strongKeywords"]; root["categories"] = c },
            { root in var c = root["categories"] as! [[String: Any]]; var k = c[0]["keywords"] as! [[String: Any]]; k[0]["term"] = " - "; c[0]["keywords"] = k; root["categories"] = c }
        ] { XCTAssertThrowsError(try rules(modifier)) }
        XCTAssertThrowsError(try RulesLoader.decode(Data("bad".utf8)))
    }
    func testRegexSafety() throws {
        for p in ["(a+)+", "a*", "a|b", "(?=a)", "\\1", "a{1,999}", "a{1,2}b{2,3}", "a{1,}"] { XCTAssertThrowsError(try RulesLoader.validateRegex(p), p) }
        XCTAssertNoThrow(try RulesLoader.validateRegex("第[0-9]{1,8}集"))
    }
    func testRejectedImportRetainsPreviousRepository() throws {
        struct Provider: RulesProvider { var data: Data; func load() throws -> Data { data } }
        var repository = RulesRepository(provider: Provider(data: try fixture()))
        let old = repository.rules?.ruleVersion
        XCTAssertThrowsError(try repository.replace(with: Data("{}".utf8)))
        XCTAssertEqual(repository.rules?.ruleVersion, old)
    }
}
