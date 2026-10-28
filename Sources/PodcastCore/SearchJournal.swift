import Foundation
import PodcastModels

public struct SearchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var term: String
    public var count: Int
    public var lastSearchedAt: Date
}

/// Separate from child-facing suggestions and the existing library format.
public struct SearchJournal: Codable, Equatable, Sendable {
    public static let limit = 200
    public static let termLimit = 200
    public private(set) var entries: [SearchRecord] = []
    public init() {}
    public static func cleaned(_ term: String) -> String {
        String(term.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(termLimit))
    }
    private static func key(_ term: String) -> String {
        cleaned(term).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")).precomposedStringWithCanonicalMapping
    }
    public mutating func record(_ term: String, at date: Date = Date()) {
        let text = Self.cleaned(term)
        guard !text.isEmpty else { return }
        let id = Identity.hash(Self.key(text))
        if let index = entries.firstIndex(where: { $0.id == id }) {
            var entry = entries.remove(at: index)
            entry.term = text; entry.count = min(entry.count, Int.max - 1) + 1; entry.lastSearchedAt = date
            entries.insert(entry, at: 0)
        } else { entries.insert(SearchRecord(id: id, term: text, count: 1, lastSearchedAt: date), at: 0) }
        entries = Array(entries.prefix(Self.limit))
    }
    public mutating func remove(ids: Set<String>) { entries.removeAll { ids.contains($0.id) } }
    public func validate() throws {
        guard entries.count <= Self.limit, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.term.isEmpty && $0.term.count <= Self.termLimit && $0.count > 0 && $0.lastSearchedAt.timeIntervalSince1970.isFinite && $0.id == Identity.hash(Self.key($0.term)) }) else {
            throw PodcastError.storage("搜索记录格式无效；原文件已保留")
        }
    }
}

public struct SearchJournalStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> SearchJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return SearchJournal() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw PodcastError.storage("搜索记录文件过大；原文件已保留") }
        let value = try JSONDecoder().decode(SearchJournal.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    public func save(_ value: SearchJournal) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
