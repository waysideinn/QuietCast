import Foundation

public enum MetadataSource: String, Codable, Sendable { case appleSearch, appleLookup, rss }
public struct ClassificationObservation: Codable, Equatable, Sendable {
    public var namespace: String
    public var id: String?
    public var name: String
    public var path: [String]
    public var primary: Bool?
    public var source: MetadataSource
    public var sourceURL: URL
    public var observedAt: Date
    public init(namespace: String, id: String? = nil, name: String, path: [String] = [], primary: Bool? = nil, source: MetadataSource, sourceURL: URL, observedAt: Date = Date()) {
        self.namespace = namespace; self.id = id; self.name = name; self.path = path; self.primary = primary
        self.source = source; self.sourceURL = sourceURL; self.observedAt = observedAt
    }
}
public enum PublisherRole: String, Codable, Sendable { case publisher, creator, aggregator, unknown }
public struct PublisherIdentity: Codable, Equatable, Sendable {
    public var namespace: String
    public var id: String?
    public var name: String
    public var role: PublisherRole
    public var source: MetadataSource
    public var sourceURL: URL
    public var observedAt: Date
    public init(namespace: String, id: String? = nil, name: String, role: PublisherRole = .unknown, source: MetadataSource, sourceURL: URL, observedAt: Date = Date()) {
        self.namespace = namespace; self.id = id; self.name = name; self.role = role
        self.source = source; self.sourceURL = sourceURL; self.observedAt = observedAt
    }
}
public extension Podcast {
    /// RSS refresh replaces RSS observations while keeping available directory provenance and stable IDs.
    func mergingDirectoryMetadata(from previous: Podcast?) -> Podcast {
        guard let previous else { return self }
        var merged = self
        merged.directoryURL = directoryURL ?? previous.directoryURL
        let newCategories = classificationObservations ?? []
        let directoryCategories = previous.classificationObservations?.filter { $0.source != .rss } ?? []
        let ownDirectoryCategories = newCategories.filter { $0.source != .rss }
        let usePreviousCategories = (directoryCategories.map(\.observedAt).max() ?? .distantPast) > (ownDirectoryCategories.map(\.observedAt).max() ?? .distantPast)
        merged.classificationObservations = newCategories.filter { $0.source == .rss } + (usePreviousCategories ? directoryCategories : ownDirectoryCategories)
        let newPublishers = publisherIdentities ?? []
        let directoryPublishers = previous.publisherIdentities?.filter { $0.source != .rss } ?? []
        let ownDirectoryPublishers = newPublishers.filter { $0.source != .rss }
        let usePreviousPublishers = (directoryPublishers.map(\.observedAt).max() ?? .distantPast) > (ownDirectoryPublishers.map(\.observedAt).max() ?? .distantPast)
        merged.publisherIdentities = newPublishers.filter { $0.source == .rss } + (usePreviousPublishers ? directoryPublishers : ownDirectoryPublishers)
        if usePreviousCategories || usePreviousPublishers || directoryTitle == nil { merged.directoryTitle = previous.directoryTitle ?? directoryTitle }
        let rssCategories = newCategories.filter { $0.source == .rss }.map(\.name)
        merged.categories = Array(Set((rssCategories.isEmpty ? categories : rssCategories) + (merged.classificationObservations ?? []).filter { $0.source != .rss }.map(\.name).filter { !$0.isEmpty })).sorted()
        return merged
    }
}
