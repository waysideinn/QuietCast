import PodcastModels
import Foundation

public enum ContentField: String, Codable, CaseIterable, Sendable {
    case showTitle, showDescription, showCategories, author, episodeTitle, episodeDescription, rssMetadata
}
public struct KeywordRule: Codable, Sendable {
    public let id: String; public let score: Double; public let fields: [ContentField]; public let note: String; public let term: String
}
public struct CombinationRule: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case sameField, anyField }
    public let id: String; public let score: Double; public let fields: [ContentField]; public let note: String
    public let terms: [String]; public let scope: Scope
}
public struct RegexRule: Codable, Sendable {
    public let id: String; public let score: Double; public let fields: [ContentField]; public let note: String; public let pattern: String
}
public struct FilterCategory: Codable, Sendable {
    public struct Thresholds: Codable, Sendable { public let review: Double; public let block: Double }
    public let id: String; public let name: String; public let description: String; public let enabled: Bool
    public let recognition: RecognitionConfiguration?
    public let classificationRules: [ClassificationRule]?
    public let publisherRules: [PublisherRule]?
    public let thresholds: Thresholds
    public let fieldWeights: [String: Double]
    public let strongKeywords: [KeywordRule]; public let keywords: [KeywordRule]
    public let combinationKeywords: [CombinationRule]; public let exclusions: [KeywordRule]; public let regexRules: [RegexRule]
    public let showBlocklist: [String]; public let episodeBlocklist: [String]
    public let showAllowlist: [String]; public let episodeAllowlist: [String]; public let notes: String
}
public struct RuleSet: Codable, Sendable {
    public let schemaVersion: String; public let ruleVersion: String; public let updatedAt: String
    public let status: String; public let sources: [String]; public let categories: [FilterCategory]
}
public enum Decision: String, Codable, Sendable { case allow, review, block }
public struct RuleEvidence: Codable, Equatable, Sendable {
    public var family: String? = nil
    public var namespace: String? = nil
    public var matchedIdentity: String? = nil
    public var source: String? = nil
    public var sourceURL: URL? = nil
    public var role: String? = nil
    public var confirmation: String? = nil
    public var ruleID: String; public var kind: String; public var fields: [ContentField]; public var value: String; public var contribution: Double
}
public struct FilterResult: Codable, Equatable, Sendable {
    public var decision: Decision; public var categoryIDs: [String]; public var evidence: [RuleEvidence]
    public var score: Double; public var ruleVersion: String; public var reason: String
    public static func simple(_ d: Decision, version: String, reason: String) -> FilterResult {
        FilterResult(decision: d, categoryIDs: [], evidence: [], score: 0, ruleVersion: version, reason: reason)
    }
}
public struct ParentalPolicy: Codable, Equatable, Sendable {
    public var enabled = true
    public var blockedAppleCategories: Set<String>?
    public var enabledCategoryIDs: Set<String> = ["fiction-audiobooks"]
    public var showAllowlist: Set<String> = []; public var showBlocklist: Set<String> = []
    public var episodeAllowlist: Set<String> = []; public var episodeBlocklist: Set<String> = []
    public var customKeywords: [String] = []
    public init() {}
}

public enum TextNormalizer {
    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>(); value.countLimit = 8192; value.totalCostLimit = 8 * 1024 * 1024; return value
    }()
    public static func normalize(_ text: String) -> String {
        let bounded = String(text.prefix(20_000))
        if let cached = cache.object(forKey: bounded as NSString) { return cached as String }
        let plain = bounded.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        let simplified = plain.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? plain
        let result = simplified.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
            .map(String.init).joined().lowercased()
        cache.setObject(result as NSString, forKey: bounded as NSString, cost: (bounded.utf16.count + result.utf16.count) * 2)
        return result
    }
}

public enum RulesLoader {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func decode(_ data: Data) throws -> RuleSet {
        guard data.count <= maximumBytes else { throw PodcastError.oversized }
        try validateStructure(data)
        let rules: RuleSet
        do { rules = try JSONDecoder().decode(RuleSet.self, from: data) }
        catch { throw PodcastError.rule("JSON 字段格式不正确：\(error.localizedDescription)") }
        guard ["1.0", "1.1"].contains(rules.schemaVersion), ["example", "production"].contains(rules.status),
              !rules.ruleVersion.isEmpty, rules.ruleVersion.count <= 64,
              (ISO8601DateFormatter().date(from: rules.updatedAt) != nil || ISO8601DateFormatter.fractional.date(from: rules.updatedAt) != nil),
              (1...32).contains(rules.categories.count), Set(rules.categories.map(\.id)).count == rules.categories.count,
              rules.sources.count <= 128, rules.sources.allSatisfy({ !$0.isEmpty && $0.count <= 2000 }) else { throw PodcastError.rule("不支持的版本、日期、来源或类别") }
        for c in rules.categories {
            guard validID(c.id), !c.name.isEmpty, c.name.count <= 256, c.description.count <= 2000, c.notes.count <= 4000,
                  c.thresholds.review.isFinite, c.thresholds.block.isFinite, c.thresholds.review > 0,
                  c.thresholds.block > c.thresholds.review, c.thresholds.block <= 1000,
                  Set(c.fieldWeights.keys) == Set(ContentField.allCases.map(\.rawValue)),
                  c.fieldWeights.values.allSatisfy({ $0.isFinite && (0...3).contains($0) }) else { throw PodcastError.rule("类别或阈值无效：\(c.id)") }
            var ids = Set<String>()
            func common(_ id: String, _ score: Double, _ fields: [ContentField], _ note: String) throws {
                guard validID(id), ids.insert(id).inserted, score.isFinite, score > 0, score <= 100,
                      !fields.isEmpty, fields.count <= 7, Set(fields).count == fields.count, note.count <= 1000 else { throw PodcastError.rule("重复规则 ID 或非法权重：\(id)") }
            }
            for array in [c.strongKeywords, c.keywords, c.exclusions] {
                guard array.count <= 256 else { throw PodcastError.rule("词条过多") }
                for r in array {
                    try common(r.id, r.score, r.fields, r.note)
                    guard !TextNormalizer.normalize(r.term).isEmpty, r.term.count <= 128 else { throw PodcastError.rule("空词条：\(r.id)") }
                }
            }
            guard c.combinationKeywords.count <= 256, c.regexRules.count <= 256 else { throw PodcastError.rule("词条过多") }
            for r in c.combinationKeywords {
                try common(r.id, r.score, r.fields, r.note)
                let terms = r.terms.map(TextNormalizer.normalize)
                guard (2...8).contains(terms.count), terms.allSatisfy({ !$0.isEmpty }), r.terms.allSatisfy({ $0.count <= 128 }), Set(terms).count == terms.count else { throw PodcastError.rule("组合词无效：\(r.id)") }
            }
            for r in c.regexRules { try common(r.id, r.score, r.fields, r.note); try validateRegex(r.pattern) }
            try AdvancedRulesValidator.validate(c, existingIDs: ids)
            for list in [c.showAllowlist, c.showBlocklist, c.episodeAllowlist, c.episodeBlocklist] {
                guard list.count <= 10000, Set(list).count == list.count, list.allSatisfy({ !$0.isEmpty && $0.count <= 2048 }) else { throw PodcastError.rule("名单无效") }
            }
        }
        return rules
    }
    private static func validID(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil }
    // Only a small, auditable regex subset is accepted. No grouping/backtracking loops.
    public static func validateRegex(_ pattern: String) throws {
        func fail() throws { throw PodcastError.rule("不安全或不支持的正则：\(pattern)") }
        guard !pattern.isEmpty, pattern.count <= 256 else { return try fail() }
        let chars = Array(pattern); var i = 0; var inClass = false; var quantified = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 1
                guard i < chars.count, "dDwWsS".contains(chars[i]) else { return try fail() }
            } else if c == "[" { guard !inClass else { return try fail() }; inClass = true }
            else if c == "]" { guard inClass else { return try fail() }; inClass = false }
            else if !inClass && "()|*+?}".contains(c) { return try fail() }
            else if !inClass && c == "{" {
                guard i > 0, quantified == 0, let end = chars[(i+1)...].firstIndex(of: "}") else { return try fail() }
                let parts = String(chars[(i+1)..<end]).split(separator: ",", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count), let lo = Int(parts[0]), let hi = Int(parts.last!), lo >= 0, hi >= lo, hi <= 64 else { return try fail() }
                quantified += 1; i = end
            }
            i += 1
        }
        guard !inClass, (try? NSRegularExpression(pattern: pattern)) != nil else { return try fail() }
    }
    private static func validateStructure(_ data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data)
        func keys(_ value: Any, _ allowed: [String], optional: [String] = []) throws -> [String: Any] {
            guard let o = value as? [String: Any], Set(allowed).isSubset(of: Set(o.keys)), Set(o.keys).isSubset(of: Set(allowed + optional)) else { throw PodcastError.rule("缺少字段或包含未定义字段") }; return o
        }
        let top = try keys(root, ["schemaVersion","ruleVersion","updatedAt","status","sources","categories"])
        guard let cats = top["categories"] as? [Any] else { throw PodcastError.rule("categories 必须为数组") }
        let extras = (top["schemaVersion"] as? String) == "1.1" ? ["recognition", "classificationRules", "publisherRules"] : []
        for value in cats {
            let c = try keys(value, ["id","name","description","enabled","thresholds","fieldWeights","strongKeywords","keywords","combinationKeywords","exclusions","regexRules","showBlocklist","episodeBlocklist","showAllowlist","episodeAllowlist","notes"], optional: extras)
            try AdvancedRulesValidator.validateStructure(c)
            _ = try keys(c["thresholds"] as Any, ["review","block"])
            _ = try keys(c["fieldWeights"] as Any, ContentField.allCases.map(\.rawValue))
            for name in ["strongKeywords","keywords","exclusions","combinationKeywords","regexRules"] {
                guard let array = c[name] as? [Any] else { throw PodcastError.rule("规则必须为数组") }
                let fields = ["id","score","fields","note"] + (name == "combinationKeywords" ? ["terms","scope"] : [name == "regexRules" ? "pattern" : "term"])
                for rule in array { _ = try keys(rule, fields) }
            }
        }
    }
}
private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }
}

public protocol RulesProvider { func load() throws -> Data }
public struct FileRulesProvider: RulesProvider {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= RulesLoader.maximumBytes else { throw PodcastError.oversized }
        return try Data(contentsOf: url)
    }
}
public struct RulesRepository {
    public private(set) var rules: RuleSet?
    public private(set) var failure: String?
    public init(provider: any RulesProvider) { do { rules = try RulesLoader.decode(provider.load()) } catch { failure = error.localizedDescription } }
    public mutating func replace(with data: Data) throws { let candidate = try RulesLoader.decode(data); rules = candidate; failure = nil }
}

public struct ContentFilter: Sendable {
    public let rules: RuleSet?
    public let policy: ParentalPolicy
    public let now: Date
    public init(rules: RuleSet?, policy: ParentalPolicy, now: Date = Date()) { self.rules = rules; self.policy = policy; self.now = now }
    public func evaluate(show: Podcast, episode: Episode? = nil) -> FilterResult {
        evaluate(show: show, episode: episode, prepared: nil)
    }
    /// Share immutable show metadata/signals across an RSS's episodes, never across policies or dates.
    public func prepare(show: Podcast) -> PreparedShowFilter { PreparedShowFilter(filter: self, show: show) }
    /// Earliest time-dependent decision boundary. Display caches expire here, including across relaunch.
    public func nextChangeDate(shows: [Podcast]) -> Date? {
        var dates: [Date] = []
        let active = (rules?.categories ?? []).filter { $0.enabled && policy.enabledCategoryIDs.contains($0.id) }
        for category in active {
            for rule in category.publisherRules ?? [] {
                if let date = AdvancedRulesValidator.date(rule.expiresAt), date > now { dates.append(date) }
                if let date = AdvancedRulesValidator.date(rule.confirmation.at), date > now { dates.append(date) }
            }
            let age = Double((category.recognition ?? RecognitionConfiguration()).metadataMaxAgeDays) * 86400
            for show in shows {
                let observations = (show.classificationObservations ?? []).map(\.observedAt) + (show.publisherIdentities ?? []).map(\.observedAt)
                for date in observations {
                    for boundary in [date.addingTimeInterval(-300), date.addingTimeInterval(age)] where boundary > now { dates.append(boundary) }
                }
            }
        }
        return dates.min()
    }
    fileprivate func evaluate(show: Podcast, episode: Episode?, prepared: PreparedShowFilter?) -> FilterResult {
        let version = rules?.ruleVersion ?? "unavailable"
        func simple(_ d: Decision, _ reason: String) -> FilterResult { .simple(d, version: version, reason: reason) }
        guard policy.enabled else { return simple(.allow, "过滤已关闭") }
        guard let rules else { return simple(.block, "规则加载失败，已安全阻止访问；请家长恢复有效规则") }
        let categories = rules.categories.filter { $0.enabled && policy.enabledCategoryIDs.contains($0.id) }
        guard Set(categories.map(\.id)) == policy.enabledCategoryIDs else { return simple(.block, "启用的类别缺失或不可用") }
        if let id = episode?.id {
            if policy.episodeBlocklist.contains(id) { return simple(.block, "家长单集禁止") }
            if policy.episodeAllowlist.contains(id) { return simple(.allow, "家长单集允许") }
        }
        if policy.showBlocklist.contains(show.id) { return simple(.block, "家长节目禁止") }
        if policy.showAllowlist.contains(show.id) { return simple(.allow, "家长节目允许") }
        if let category = prepared.map({ $0.blockedCategory }) ?? blockedCategory(for: show) {
            var denied = simple(.block, "家长禁用分类：\(category.title)")
            var evidence = RuleEvidence(ruleID: "parent-apple-category", kind: "parentCategory", fields: [.showCategories], value: category.path.joined(separator: " / "), contribution: 0)
            evidence.family = "appleCategories"; evidence.matchedIdentity = category.appleID
            denied.evidence = [evidence]; return denied
        }
        if let id = episode?.id {
            if categories.contains(where: { $0.episodeBlocklist.contains(id) }) { return simple(.block, "词库单集黑名单") }
            if categories.contains(where: { $0.episodeAllowlist.contains(id) }) { return simple(.allow, "词库单集白名单") }
        }
        if categories.contains(where: { $0.showBlocklist.contains(show.id) }) { return simple(.block, "词库节目黑名单") }
        if categories.contains(where: { $0.showAllowlist.contains(show.id) }) { return simple(.allow, "词库节目白名单") }
        var fields = prepared?.fields ?? Self.showFields(show)
        fields[.episodeTitle] = TextNormalizer.normalize(episode?.title ?? "")
        fields[.episodeDescription] = TextNormalizer.normalize(episode?.summary ?? "")
        fields[.rssMetadata] = TextNormalizer.normalize(show.metadata + "\n" + (episode?.metadata ?? ""))
        for term in policy.customKeywords {
            let word = TextNormalizer.normalize(term)
            let matched = ContentField.allCases.filter { !word.isEmpty && fields[$0, default: ""].contains(word) }
            if !matched.isEmpty {
                var result = simple(.block, "家长自定义屏蔽词")
                result.evidence = [.init(ruleID: "parent-keyword", kind: "custom", fields: matched, value: term, contribution: 0)]
                return result
            }
        }
        var overall = simple(show.hasRSSMetadata ? .allow : .review, show.hasRSSMetadata ? "未达到限制阈值" : "目录信息不完整，需先获取 RSS 元数据")
        for c in categories {
            let config = c.recognition ?? RecognitionConfiguration()
            let signals = prepared?.signals[c.id] ?? AdvancedSignals.evaluate(c, show: show, now: now)
            var keywordFields = fields
            if signals.evidence.contains(where: { $0.family == "appleCategories" && $0.kind != "staleMetadata" }) { keywordFields[.showCategories] = "" }
            if signals.evidence.contains(where: { $0.family == "publishers" && $0.kind == "publisher" }) { keywordFields[.author] = "" }
            var evidence: [RuleEvidence] = []; var strong = 0.0; var normal = 0.0; var exclusions = 0.0
            func hit(_ id: String, _ kind: String, _ value: String, _ score: Double, _ matched: [ContentField], _ weight: Double? = nil) -> Double {
                let w = weight ?? matched.map { c.fieldWeights[$0.rawValue, default: 0] }.max() ?? 0
                let contribution = score * w
                if contribution > 0 { evidence.append(.init(ruleID: id, kind: kind, fields: matched, value: value, contribution: kind == "exclusion" ? -contribution : contribution)) }
                return contribution
            }
            if config.keywords {
            for (kind, array) in [("strong",c.strongKeywords),("keyword",c.keywords),("exclusion",c.exclusions)] {
                for r in array {
                    let term = TextNormalizer.normalize(r.term)
                    let matched = r.fields.filter { keywordFields[$0, default: ""].contains(term) }
                    let score = hit(r.id, kind, r.term, r.score, matched)
                    if kind == "strong" { strong += score } else if kind == "exclusion" { exclusions += score } else { normal += score }
                }
            }
            for r in c.combinationKeywords {
                let terms = r.terms.map(TextNormalizer.normalize)
                if r.scope == .sameField {
                    let matched = r.fields.filter { f in terms.allSatisfy { keywordFields[f, default: ""].contains($0) } }
                    normal += hit(r.id, "combination", r.terms.joined(separator: " + "), r.score, matched)
                } else {
                    let groups = terms.map { term in r.fields.filter { keywordFields[$0, default: ""].contains(term) } }
                    if groups.allSatisfy({ !$0.isEmpty }) {
                        let weight = groups.map { $0.map { c.fieldWeights[$0.rawValue, default: 0] }.max() ?? 0 }.min() ?? 0
                        normal += hit(r.id, "combination", r.terms.joined(separator: " + "), r.score, Array(Set(groups.flatMap { $0 })).sorted { $0.rawValue < $1.rawValue }, weight)
                    }
                }
            }
            for r in c.regexRules {
                guard let regex = try? NSRegularExpression(pattern: r.pattern) else { return simple(.block, "正则规则失效") }
                let matched = r.fields.filter { f in let t = keywordFields[f, default: ""]; return regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
                normal += hit(r.id, "regex", r.pattern, r.score, matched)
            }
            }
            for i in evidence.indices { evidence[i].family = "keywords" }
            let keywordScore = strong + max(0, normal - exclusions)
            evidence += signals.evidence
            let jointReady = config.combination == .score || (
                (config.appleCategories || config.publishers || config.keywords) &&
                (!config.appleCategories || signals.categorySignal) && (!config.publishers || signals.publisherSignal) && (!config.keywords || keywordScore > 0))
            let score = jointReady ? keywordScore + signals.categoryScore + signals.publisherScore : 0
            let directBlock = jointReady && (signals.categoryBlock || signals.publisherBlock)
            let decision: Decision = directBlock || score >= c.thresholds.block ? .block : (signals.review || score >= c.thresholds.review) ? .review : .allow
            overall.score = max(overall.score, score)
            overall.evidence += evidence
            if decision != .allow { overall.categoryIDs.append(c.id) }
            if rank(decision) > rank(overall.decision) { overall.decision = decision; overall.reason = "\(c.name)：\(decision == .block ? (directBlock ? "分类或发布账号规则禁止" : "达到拦截阈值") : "需要家长确认")" }
        }
        return overall
    }
    public func isCategoryAllowed(_ category: PodcastCategory) -> Bool {
        guard policy.enabled else { return true }
        guard let rules, policy.enabledCategoryIDs.isSubset(of: Set(rules.categories.filter(\.enabled).map(\.id))) else { return false }
        let blocked = policy.blockedAppleCategories ?? []
        if blocked.contains(category.id) { return false }
        if let parent = category.parent, !isCategoryAllowed(parent) { return false }
        return true
    }
    public func blockedCategory(for show: Podcast) -> PodcastCategory? {
        guard policy.enabled else { return nil }
        for observation in show.classificationObservations ?? [] {
            if observation.namespace == "apple.podcasts.genre", let id = observation.id, policy.blockedAppleCategories?.contains(id) == true {
                return PodcastCategories.category(id) ?? PodcastCategory(appleID: id, path: [observation.name], title: observation.name.isEmpty ? id : observation.name)
            }
            for category in PodcastCategories.matching(observation) where !isCategoryAllowed(category) { return category }
        }
        // Old library files had flat category names only; preserve restrictions during migration.
        for name in show.categories {
            let observation = ClassificationObservation(namespace: "rss.itunes.category", name: name, source: .rss, sourceURL: show.feedURL)
            for category in PodcastCategories.matching(observation) where !isCategoryAllowed(category) { return category }
        }
        return nil
    }
    private func rank(_ d: Decision) -> Int { d == .block ? 2 : d == .review ? 1 : 0 }
    fileprivate static func showFields(_ show: Podcast) -> [ContentField: String] {
        [.showTitle: show.title + "\n" + (show.directoryTitle ?? ""), .showDescription: show.summary,
         .showCategories: show.categories.joined(separator: "\n"), .author: show.author].mapValues(TextNormalizer.normalize)
    }
}

public struct PreparedShowFilter: Sendable {
    fileprivate let filter: ContentFilter
    fileprivate let show: Podcast
    fileprivate let blockedCategory: PodcastCategory?
    fileprivate let fields: [ContentField: String]
    fileprivate let signals: [String: AdvancedSignals]
    fileprivate init(filter: ContentFilter, show: Podcast) {
        self.filter = filter; self.show = show
        blockedCategory = filter.blockedCategory(for: show); fields = ContentFilter.showFields(show)
        signals = Dictionary(uniqueKeysWithValues: (filter.rules?.categories ?? [])
            .filter { $0.enabled && filter.policy.enabledCategoryIDs.contains($0.id) }
            .map { ($0.id, AdvancedSignals.evaluate($0, show: show, now: filter.now)) })
    }
    public func evaluate(episode: Episode? = nil) -> FilterResult { filter.evaluate(show: show, episode: episode, prepared: self) }
}

public enum AccessEntry: String, Codable, CaseIterable, Sendable {
    case search, detail, episodeList, playback, subscription, download, queue, history, rssImport, externalLink, autoplay, discovery, recommendation, categoryList, charts
}
public struct AccessGate {
    public var filter: ContentFilter
    public init(filter: ContentFilter) { self.filter = filter }
    public func authorize(_ entry: AccessEntry, show: Podcast, episode: Episode? = nil) throws -> FilterResult {
        let result = filter.evaluate(show: show, episode: episode)
        guard result.decision == .allow else { throw PodcastError.blocked("\(entry.rawValue)：\(result.reason)") }
        return result
    }
}
