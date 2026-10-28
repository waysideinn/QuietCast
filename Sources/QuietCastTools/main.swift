import Foundation
import PodcastCore

@main struct QuietCastTools {
    static func main() async {
        do { try await run() } catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print("quietcast-tools validate <rules.json> | smoke-network [keyword] | smoke-home [CN/HK/US] | score <rules.json> <show-title> [episode-title]"); return }
        switch command {
        case "validate", "score":
            guard args.count >= 2 else { throw PodcastError.rule("缺少规则文件路径") }
            let rules = try RulesLoader.decode(FileRulesProvider(url: URL(fileURLWithPath: args[1])).load())
            if command == "validate" { print("VALID schema=\(rules.schemaVersion) rules=\(rules.ruleVersion) status=\(rules.status) categories=\(rules.categories.count)") }
            else {
                guard args.count >= 3 else { throw PodcastError.rule("缺少测试标题") }
                let show = Podcast(feedURL: URL(string: "https://test.invalid/rss")!, title: args[2], hasRSSMetadata: true)
                let ep = args.count > 3 ? Episode(podcastID: show.id, guid: "test", title: args[3], audioURL: URL(string: "https://test.invalid/audio.mp3")!) : nil
                let result = ContentFilter(rules: rules, policy: ParentalPolicy()).evaluate(show: show, episode: ep)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            }
        case "smoke-home":
            let country = args.count > 1 ? args[1].uppercased() : "CN"
            let sample = URL(fileURLWithPath: "App/Resources/content-filter.json")
            let rules = try RulesLoader.decode(FileRulesProvider(url: sample).load())
            let service = DiscoveryService(http: HTTPClient(defaultTimeout: 8, defaultRetries: 0), cacheURL: URL(fileURLWithPath: ".build/discovery-smoke.json"), candidateLimit: 6)
            for kind in [DiscoveryKind.topShows, .topEpisodes] {
                let loaded = await service.load(kind, library: LibraryState(), filter: ContentFilter(rules: rules, policy: ParentalPolicy()), country: country, force: true)
                let key = DiscoveryService.key(kind, country: country)
                guard let section = loaded.snapshot.sections[key] else { throw PodcastError.invalidFeed(loaded.error ?? "未取得发现数据") }
                let entries = DiscoveryPresentation.entries(section, feeds: loaded.snapshot.feeds, filter: ContentFilter(rules: rules, policy: ParentalPolicy()))
                print("\(kind.rawValue): origin=\(section.origin.rawValue), source=\(section.sourceURL?.absoluteString ?? "directory"), allowed=\(entries.count), cached=\(loaded.fromCache)")
                if let error = loaded.error { print(error) }
            }
        case "smoke-network":
            let term = args.count > 1 ? args[1] : "科学"
            let http = HTTPClient(); let found = try await DirectoryClient(http: http).search(term)
            print("Live iTunes search: \(found.count) unique feed URLs for \(term)")
            guard !found.isEmpty else { throw PodcastError.invalidFeed("真实目录没有返回节目") }
            var success = false
            for show in found.prefix(3) {
                do {
                    let feed = try await FeedClient(http: http).fetch(show.feedURL)
                    print("Live RSS: title=\(feed.podcast.title), episodes=\(feed.episodes.count), URL=\(show.feedURL.absoluteString)")
                    success = true; break
                } catch { print("RSS unavailable: \(show.feedURL.host ?? "") — \(error.localizedDescription)") }
            }
            guard success else { throw PodcastError.invalidFeed("前三个真实 RSS 均不可用") }
        default: throw PodcastError.rule("未知命令")
        }
    }
}
