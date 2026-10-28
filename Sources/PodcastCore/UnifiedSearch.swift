import Foundation
import PodcastModels

public struct UnifiedSearchResult: Sendable {
    public var shows: [Podcast]
    public var completedSources: Int
    public var failedSources: Int
}

/// Federates the three supported storefronts without fetching any RSS or merging homonymous shows.
public struct UnifiedDirectorySearch: Sendable {
    private let directory: DirectoryClient
    public init(directory: DirectoryClient) { self.directory = directory }
    private struct RegionalResult: Sendable { let shows: [Podcast]; let failed: Bool }
    public func search(_ text: String, onUpdate: (@Sendable (UnifiedSearchResult) async -> Void)? = nil) async throws -> UnifiedSearchResult {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return UnifiedSearchResult(shows: [], completedSources: 0, failedSources: 0) }
        let result = await withTaskGroup(of: RegionalResult?.self) { group in
            for country in ["CN", "HK", "US"] {
                group.addTask { [directory] in
                    do { return RegionalResult(shows: try await directory.search(term, country: country, timeout: 8, retries: 0), failed: false) }
                    catch { return Task.isCancelled ? nil : RegionalResult(shows: [], failed: true) }
                }
            }
            var merged = UnifiedSearchResult(shows: [], completedSources: 0, failedSources: 0)
            var seen = Set<String>()
            for await regional in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                guard let regional else { continue }
                merged.completedSources += 1
                if regional.failed { merged.failedSources += 1 }
                // Stable first-seen order prevents late storefronts moving rows while people browse them.
                for show in regional.shows where seen.insert(show.id).inserted { merged.shows.append(show) }
                await onUpdate?(merged)
            }
            return merged
        }
        try Task.checkCancellation()
        if result.failedSources == 3 { throw SearchUnavailable() }
        return result
    }
    private struct SearchUnavailable: LocalizedError {
        var errorDescription: String? { "搜索暂时无法连接，请检查网络后重试。" }
    }
}
