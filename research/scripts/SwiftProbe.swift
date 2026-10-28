import Foundation
#if canImport(PodcastModels)
import PodcastModels
import ContentFiltering
#endif

// Compiled with A's unchanged Models.swift and ContentFiltering.swift into /tmp.
// This executable performs no network requests or App-resource modifications.
@main
struct ResearchProbe {
    static func main() throws {
        let rules = try RulesLoader.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let document = root as? [String: Any]
        let input = root as? [[String: Any]] ?? document!["fixtures"] as! [[String: Any]]
        func date(_ value: String) -> Date {
            let parser = ISO8601DateFormatter()
            if let result = parser.date(from: value) { return result }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: value)!
        }
        let at = (document?["evaluationTime"] as? String).map(date) ?? Date()
        let filter = ContentFilter(rules: rules, policy: ParentalPolicy(), now: at)
        let output: [[String: Any]] = input.map { row in
            let f = row["fields"] as! [String: String]
            let cs = (row["classificationObservations"] as? [[String: Any]] ?? []).map { o in
                ClassificationObservation(namespace: o["namespace"] as! String, id: o["id"] as? String, name: o["name"] as! String, path: o["path"] as? [String] ?? [], primary: o["primary"] as? Bool, source: MetadataSource(rawValue: o["source"] as! String)!, sourceURL: URL(string: o["sourceURL"] as! String)!, observedAt: date(o["observedAt"] as! String))
            }
            let ps = (row["publisherIdentities"] as? [[String: Any]] ?? []).map { o in
                PublisherIdentity(namespace: o["namespace"] as! String, id: o["id"] as? String, name: o["name"] as! String, role: PublisherRole(rawValue: o["role"] as! String)!, source: MetadataSource(rawValue: o["source"] as! String)!, sourceURL: URL(string: o["sourceURL"] as! String)!, observedAt: date(o["observedAt"] as! String))
            }
            let show = Podcast(feedURL: URL(string: row["feed_url"] as! String)!, title: f["showTitle"] ?? "", author: f["author"] ?? "", summary: f["showDescription"] ?? "", categories: [f["showCategories"] ?? ""], metadata: f["rssMetadata"] ?? "", hasRSSMetadata: row["rss_complete"] as! Bool, classificationObservations: cs, publisherIdentities: ps)
            var episode: Episode? = nil
            if let guid = row["guid"] as? String {
                episode = Episode(podcastID: show.id, guid: guid, title: f["episodeTitle"] ?? "", summary: f["episodeDescription"] ?? "", audioURL: URL(string: "https://example.invalid/not-fetched")!)
            }
            let result = filter.evaluate(show: show, episode: episode)
            return ["decision":result.decision.rawValue,"score":result.score,"normalization":f.mapValues(TextNormalizer.normalize)]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
