import PodcastModels
import ContentFiltering
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum RSSParser {
    public static func parse(_ data: Data, feedURL: URL) throws -> Feed {
        guard data.count <= 8 * 1024 * 1024 else { throw PodcastError.oversized }
        let prefix = String(decoding: data, as: UTF8.self).uppercased()
        guard !prefix.contains("<!DOCTYPE"), !prefix.contains("<!ENTITY") else { throw PodcastError.invalidFeed("不接受 DTD 或外部实体") }
        let delegate = FeedDelegate(url: feedURL)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.validChannel, delegate.depth == 0, !delegate.show.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PodcastError.invalidFeed(parser.parserError?.localizedDescription ?? "需要 RSS 2.0 channel 与 title")
        }
        let show = delegate.show
        let episodes = delegate.entries.values.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return Feed(podcast: show, episodes: episodes)
    }
    public static func duration(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (1...3).contains(parts.count), parts.allSatisfy({ Double($0) != nil }) else { return nil }
        let value = parts.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return value.isFinite && value >= 0 ? value : nil
    }
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
private final class FeedDelegate: NSObject, XMLParserDelegate {
    struct Frame { var name: String; var text = ""; var categoryName: String? }
    var stack: [Frame] = []
    var depth: Int { stack.count }
    var validChannel = false
    var show: Podcast
    var entries: [String: Episode] = [:]
    var item: [String: String]?
    var imageURL: URL?
    var primaryCategoryRoot: String?
    init(url: URL) { show = Podcast(feedURL: url, title: "", hasRSSMetadata: true, rssFetchedAt: Date()) }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let sourceURL = show.feedURL
        let name = elementName.lowercased()
        stack.append(Frame(name: name, categoryName: name == "itunes:category" ? attributes["text"] : nil))
        if depth > 64 { parser.abortParsing(); return }
        if name == "channel", stack.first?.name == "rss" { validChannel = true }
        if name == "item", stack.dropLast().last?.name == "channel" { item = [:]; imageURL = nil }
        if name == "enclosure", item != nil, let url = attributes["url"], let parsed = try? PublicURL.parse(url),
           attributes["type"]?.hasPrefix("audio/") != false {
            item?["audio"] = parsed.absoluteString
        }
        if name == "itunes:image", let href = attributes["href"], let url = try? PublicURL.parse(href) {
            if item != nil { imageURL = url } else { show.artworkURL = url }
        }
        if name == "itunes:category", item == nil, let text = attributes["text"] {
            show.categories.append(text)
            let path = stack.compactMap(\.categoryName)
            if primaryCategoryRoot == nil { primaryCategoryRoot = path.first }
            if show.classificationObservations == nil { show.classificationObservations = [] }
            show.classificationObservations?.append(ClassificationObservation(namespace: "rss.itunes.category", name: text, path: path, primary: path.first == primaryCategoryRoot, source: .rss, sourceURL: sourceURL))
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count - 1].text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let sourceURL = show.feedURL
        guard let frame = stack.popLast() else { return }
        let name = frame.name; let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.last?.name
        if name == "item" {
            if let item, let audio = item["audio"].flatMap(URL.init(string:)), let title = item["title"], !title.isEmpty, entries.count < 3000 {
                let ep = Episode(podcastID: show.id, guid: item["guid"].flatMap { $0.isEmpty ? nil : $0 } ?? audio.absoluteString, title: RSSParser.plain(title), summary: RSSParser.plain(item["content:encoded"] ?? item["description"] ?? item["itunes:summary"] ?? ""), audioURL: audio, artworkURL: imageURL, published: parseDate(item["pubdate"]), duration: item["itunes:duration"].flatMap(RSSParser.duration), metadata: ["itunes:type","itunes:explicit","itunes:keywords","itunes:episode","itunes:season"].compactMap { key in item[key].map { "\(key):\($0)" } }.joined(separator: "\n"))
                entries[ep.id] = ep
            }
            item = nil; imageURL = nil
        } else if item != nil, parent == "item" {
            item?[name] = text
        } else if parent == "channel", item == nil {
            switch name {
            case "title": show.title = RSSParser.plain(text)
            case "itunes:author": show.author = RSSParser.plain(text); publisher(text, namespace: "rss.itunes.author", role: .creator)
            case "managingeditor", "dc:creator": if show.author.isEmpty { show.author = RSSParser.plain(text) }; publisher(text, namespace: name == "managingeditor" ? "rss.managingEditor" : "rss.dc.creator", role: .creator)
            case "publisher", "dc:publisher": publisher(text, namespace: "rss.publisher", role: .unknown)
            case "description", "itunes:summary": if show.summary.isEmpty { show.summary = RSSParser.plain(text) }
            case "category": show.categories.append(text); if show.classificationObservations == nil { show.classificationObservations = [] }; show.classificationObservations?.append(ClassificationObservation(namespace: "rss.category", name: text, source: .rss, sourceURL: sourceURL))
            case "language","itunes:type","itunes:explicit","itunes:keywords","podcast:medium","copyright": show.metadata += "\n\(name):\(text)"
            default: break
            }
        } else if name == "itunes:name", parent == "itunes:owner", item == nil {
            publisher(text, namespace: "rss.itunes.owner", role: .unknown)
        } else if name == "url", parent == "image", item == nil, show.artworkURL == nil {
            show.artworkURL = try? PublicURL.parse(text)
        }
        if !stack.isEmpty { stack[stack.count - 1].text += text }
    }
    private func publisher(_ name: String, namespace: String, role: PublisherRole) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sourceURL = show.feedURL
        if show.publisherIdentities == nil { show.publisherIdentities = [] }
        show.publisherIdentities?.append(PublisherIdentity(namespace: namespace, name: RSSParser.plain(name), role: role, source: .rss, sourceURL: sourceURL))
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let d = f.date(from: value) { return d }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
