import PodcastModels
import ContentFiltering
import Foundation

public struct AtomicLibraryStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryState() }
        do {
            let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url))
            guard state.version == 1 else { throw PodcastError.storage("不支持的资料库版本；原文件已保留") }
            return state
        } catch { throw PodcastError.storage("\(error.localizedDescription)；原文件已保留，未重置") }
    }
    public func save(_ state: LibraryState) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
        } catch { throw PodcastError.storage(error.localizedDescription) }
    }
}

/// Serial disk work off the UI actor. A late older task must never overwrite newer progress.
public actor LibraryWriter {
    private let store: AtomicLibraryStore
    private var savedRevision: UInt64 = 0
    public init(url: URL) { store = AtomicLibraryStore(url: url) }
    public func save(_ state: LibraryState, revision: UInt64) throws {
        guard revision > savedRevision else { return }
        try store.save(state)
        savedRevision = revision
    }
}

public struct BlockEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var show: Podcast
    public var episode: Episode?
    public var entry: AccessEntry
    public var result: FilterResult
    public init(show: Podcast, episode: Episode?, entry: AccessEntry, result: FilterResult) {
        self.show = show; self.episode = episode; self.entry = entry; self.result = result
    }
}

/// Captures the episode identity before a player transition. A delayed old callback cannot overwrite the new episode.
public struct ProgressSession: Sendable {
    public private(set) var currentID: String?
    public private(set) var generation: UInt64 = 0
    public init() {}
    @discardableResult public mutating func switchTo(_ id: String?) -> UInt64 { generation &+= 1; currentID = id; return generation }
    public func accepts(episodeID: String, generation: UInt64) -> Bool { currentID == episodeID && self.generation == generation }
}
