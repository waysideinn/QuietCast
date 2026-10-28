import Foundation
#if !CORE_CLI_TESTS
import XCTest
#endif
@testable import PodcastCore

final class SearchJournalTests: XCTestCase {
    func testRepeatedTermsMergeAndMostRecentSearchMovesFirst() {
        var journal = SearchJournal()
        journal.record("  科学  访谈 \n", at: Date(timeIntervalSince1970: 1))
        journal.record("历史", at: Date(timeIntervalSince1970: 2))
        journal.record("科学 访谈", at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(journal.entries.map(\.term), ["科学 访谈", "历史"])
        XCTAssertEqual(journal.entries.first?.count, 2)
        XCTAssertEqual(journal.entries.first?.lastSearchedAt, Date(timeIntervalSince1970: 3))
        journal.record("ＳＷＩＦＴ"); journal.record("swift")
        XCTAssertEqual(journal.entries.first?.count, 2)
    }
    func testEmptyTermsDoNotRecordAndStorageIsBounded() {
        var journal = SearchJournal(); journal.record(" \n\t")
        XCTAssertTrue(journal.entries.isEmpty)
        for i in 0..<250 { journal.record("关键词\(i)") }
        XCTAssertEqual(journal.entries.count, 200)
        XCTAssertEqual(journal.entries.last?.term, "关键词50")
        journal.record(String(repeating: "字", count: 500))
        XCTAssertEqual(journal.entries.first?.term.count, 200)
        XCTAssertNoThrow(try journal.validate())
    }
    func testDeletingAndReopeningPreservesRemainingCountsThenClear() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("search.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SearchJournalStore(url: url)
        var journal = SearchJournal(); journal.record("科学"); journal.record("历史"); journal.record("科学")
        try store.save(journal)
        var reopened = try store.load(); XCTAssertEqual(reopened.entries.first?.count, 2)
        reopened.remove(ids: [reopened.entries.last!.id]); try store.save(reopened)
        XCTAssertEqual(try store.load().entries.map(\.term), ["科学"])
        try store.save(SearchJournal()); XCTAssertTrue(try store.load().entries.isEmpty)
    }
    func testCorruptHistoryIsNotSilentlyOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let invalid = Data("{invalid".utf8); try invalid.write(to: url)
        XCTAssertThrowsError(try SearchJournalStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
}
