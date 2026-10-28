import Foundation
import PodcastModels

public struct RecognitionConfiguration: Codable, Sendable {
    public enum Combination: String, Codable, Sendable { case score, allEnabledSources }
    public var appleCategories: Bool = true
    public var publishers: Bool = true
    public var keywords: Bool = true
    public var combination: Combination = .score
    public var metadataMaxAgeDays: Int = 30
    public init() {}
}
public enum SignalAction: String, Codable, Sendable { case score, review, block }
public struct ClassificationRule: Codable, Sendable {
    public struct Match: Codable, Sendable {
        public let ids: [String]; public let names: [String]; public let paths: [[String]]; public let primaryOnly: Bool
    }
    public let id: String; public let enabled: Bool; public let match: Match
    public let action: SignalAction; public let score: Double; public let note: String; public let sources: [String]
}
public struct PublisherRule: Codable, Sendable {
    public struct Identity: Codable, Sendable { public let namespace: String; public let id: String }
    public struct Confirmation: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case pending, confirmed, rejected }
        public let status: Status; public let by: String; public let at: String; public let evidence: [String]
    }
    public enum Scope: String, Codable, Sendable { case allShows, selectedShows }
    public let id: String; public let enabled: Bool; public let identities: [Identity]; public let names: [String]
    public let role: PublisherRole; public let scope: Scope; public let showIDs: [String]
    public let action: SignalAction; public let score: Double; public let confirmation: Confirmation; public let expiresAt: String; public let note: String
}
public enum AdvancedRulesValidator {
    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: value)
    }
    static func validate(_ category: FilterCategory, existingIDs: Set<String>) throws {
        var ids = existingIDs
        func invalid(_ detail: String) throws { throw PodcastError.rule("v1.1：\(detail)") }
        func strings(_ values: [String], maxLength: Int = 128, minCount: Int = 0) -> Bool {
            values.count >= minCount && values.count <= 256 && Set(values).count == values.count && values.allSatisfy { !$0.isEmpty && $0.count <= maxLength }
        }
        func common(_ id: String, _ score: Double, _ note: String) throws {
            guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil, ids.insert(id).inserted,
                  score.isFinite, score > 0, score <= 100, note.count <= 2000 else { return try invalid("重复 ID 或非法评分 \(id)") }
        }
        if let config = category.recognition { guard (1...365).contains(config.metadataMaxAgeDays) else { return try invalid("元数据有效期无效") } }
        guard (category.classificationRules?.count ?? 0) <= 256, (category.publisherRules?.count ?? 0) <= 1000 else { return try invalid("扩展规则过多") }
        for r in category.classificationRules ?? [] {
            try common(r.id, r.score, r.note)
            guard strings(r.match.ids), strings(r.match.names), strings(r.sources, maxLength: 2000, minCount: 1), r.match.paths.count <= 256,
                  r.match.ids.allSatisfy({ $0.range(of: "^[0-9]{1,12}$", options: .regularExpression) != nil }),
                  r.match.names.allSatisfy({ !TextNormalizer.normalize($0).isEmpty }),
                  r.match.paths.allSatisfy({ strings($0, minCount: 1) && $0.allSatisfy { !TextNormalizer.normalize($0).isEmpty } }),
                  !r.match.ids.isEmpty || !r.match.names.isEmpty || !r.match.paths.isEmpty else { return try invalid("分类匹配为空或非法") }
        }
        for r in category.publisherRules ?? [] {
            try common(r.id, r.score, r.note)
            guard r.identities.count <= 256, Set(r.identities.map { $0.namespace + ":" + $0.id }).count == r.identities.count,
                  r.identities.allSatisfy({ $0.namespace == "apple.podcasts.artist" && $0.id.range(of: "^[0-9]{1,24}$", options: .regularExpression) != nil }),
                  strings(r.names, maxLength: 256), r.names.allSatisfy({ !IdentityName.normalize($0).isEmpty }),
                  !r.identities.isEmpty || !r.names.isEmpty, strings(r.showIDs, maxLength: 2048),
                  r.scope == .selectedShows ? !r.showIDs.isEmpty : r.showIDs.isEmpty else { return try invalid("账号身份、名称或节目范围无效") }
            guard let confirmed = date(r.confirmation.at), let expires = date(r.expiresAt), confirmed < expires,
                  !r.confirmation.by.isEmpty, r.confirmation.by.count <= 256, strings(r.confirmation.evidence, maxLength: 2000, minCount: 1) else { return try invalid("确认、来源或期限无效") }
            if r.confirmation.status == .confirmed && r.identities.isEmpty { return try invalid("已确认账号必须提供稳定身份") }
            if r.scope == .allShows && (r.role == .aggregator || r.role == .unknown) && r.action != .review { return try invalid("聚合或未知主体不能整账号评分/封禁") }
        }
    }
    static func validateStructure(_ category: [String: Any]) throws {
        func keys(_ raw: Any?, _ required: [String]) throws -> [String: Any] {
            guard let o = raw as? [String: Any], Set(o.keys) == Set(required) else { throw PodcastError.rule("v1.1 扩展缺少字段或存在未知字段") }; return o
        }
        if category.keys.contains("recognition") { _ = try keys(category["recognition"], ["appleCategories","publishers","keywords","combination","metadataMaxAgeDays"]) }
        for key in ["classificationRules", "publisherRules"] where category.keys.contains(key) {
            guard let array = category[key] as? [Any] else { throw PodcastError.rule("v1.1 扩展必须为数组") }
            for raw in array {
                if key == "classificationRules" {
                    let o = try keys(raw, ["id","enabled","match","action","score","note","sources"])
                    _ = try keys(o["match"], ["ids","names","paths","primaryOnly"])
                } else {
                    let o = try keys(raw, ["id","enabled","identities","names","role","scope","showIDs","action","score","confirmation","expiresAt","note"])
                    _ = try keys(o["confirmation"], ["status","by","at","evidence"])
                    guard let identities = o["identities"] as? [Any] else { throw PodcastError.rule("identities 必须为数组") }
                    for identity in identities { _ = try keys(identity, ["namespace","id"]) }
                }
            }
        }
    }
}
/// Identity names retain punctuation; a punctuation-stripping fuzzy match must not merge accounts.
public enum IdentityName {
    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>(); value.countLimit = 2048; value.totalCostLimit = 1024 * 1024; return value
    }()
    public static func normalize(_ name: String) -> String {
        if let cached = cache.object(forKey: name as NSString) { return cached as String }
        let result = (name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cache.setObject(result as NSString, forKey: name as NSString, cost: (name.utf16.count + result.utf16.count) * 2)
        return result
    }
}
