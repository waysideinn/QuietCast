import Foundation
import PodcastModels

struct AdvancedSignals {
    var evidence: [RuleEvidence] = []
    var categoryScore = 0.0
    var publisherScore = 0.0
    var categorySignal = false
    var publisherSignal = false
    var categoryBlock = false
    var publisherBlock = false
    var review = false
    static func evaluate(_ category: FilterCategory, show: Podcast, now: Date) -> AdvancedSignals {
        let config = category.recognition ?? RecognitionConfiguration()
        var result = AdvancedSignals()
        func fresh(_ date: Date) -> Bool { date <= now.addingTimeInterval(300) && now.timeIntervalSince(date) <= Double(config.metadataMaxAgeDays) * 86400 }
        if config.appleCategories {
            for rule in category.classificationRules ?? [] where rule.enabled {
                let matching = (show.classificationObservations ?? []).filter { observation in
                    guard observation.namespace == "apple.podcasts.genre" || observation.namespace == "rss.itunes.category", !rule.match.primaryOnly || observation.primary == true else { return false }
                    let idMatch = observation.namespace == "apple.podcasts.genre" && observation.id.map(rule.match.ids.contains) == true
                    return idMatch || rule.match.names.map(IdentityName.normalize).contains(IdentityName.normalize(observation.name)) || rule.match.paths.contains { $0.map(IdentityName.normalize) == observation.path.map(IdentityName.normalize) }
                }
                guard let match = matching.first(where: { fresh($0.observedAt) }) ?? matching.first else { continue }
                let stale = !fresh(match.observedAt)
                var e = RuleEvidence(ruleID: rule.id, kind: stale ? "staleMetadata" : "classification", fields: [.showCategories], value: match.path.isEmpty ? match.name : match.path.joined(separator: " / "), contribution: !stale && rule.action == .score ? rule.score : 0)
                e.family = "appleCategories"; e.namespace = match.namespace; e.matchedIdentity = match.id; e.source = match.source.rawValue; e.sourceURL = match.sourceURL
                result.evidence.append(e)
                if !stale { result.categorySignal = true }
                if stale || rule.action == .review { result.review = true }
                else {
                    result.categorySignal = true
                    if rule.action == .block { result.categoryBlock = true }
                    else { result.categoryScore = max(result.categoryScore, rule.score) }
                }
            }
        }
        if config.publishers {
            for rule in category.publisherRules ?? [] where rule.enabled && rule.confirmation.status != .rejected {
                guard let expiry = AdvancedRulesValidator.date(rule.expiresAt), let confirmed = AdvancedRulesValidator.date(rule.confirmation.at), expiry > now, confirmed <= now else { continue }
                guard rule.scope == .allShows || rule.showIDs.contains(show.id) else { continue }
                let identities = show.publisherIdentities ?? []
                let stable = identities.filter { observation in
                    observation.namespace == "apple.podcasts.artist" && observation.source != .rss && rule.identities.contains { $0.namespace == observation.namespace && $0.id == observation.id }
                }
                let named = identities.first { IdentityName.normalize($0.name).isEmpty == false && rule.names.map(IdentityName.normalize).contains(IdentityName.normalize($0.name)) }
                let legacyNameMatch = rule.names.map(IdentityName.normalize).contains(IdentityName.normalize(show.author)) && !show.author.isEmpty
                guard let match = stable.first(where: { fresh($0.observedAt) }) ?? stable.first ?? named ?? (legacyNameMatch ? PublisherIdentity(namespace: "rss.itunes.author", name: show.author, role: .unknown, source: .rss, sourceURL: show.feedURL) : nil) else { continue }
                let stableMatch = stable.contains(match)
                let roleSafe = rule.scope == .selectedShows || ((rule.role == .publisher || rule.role == .creator) && match.role != .aggregator)
                let authoritative = stableMatch && fresh(match.observedAt) && rule.confirmation.status == .confirmed && roleSafe
                let kind = !fresh(match.observedAt) ? "staleMetadata" : !stableMatch ? "identityUnavailable" : !authoritative ? "publisherReview" : "publisher"
                var e = RuleEvidence(ruleID: rule.id, kind: kind, fields: [.author], value: match.name, contribution: authoritative && rule.action == .score ? rule.score : 0)
                e.family = "publishers"; e.namespace = match.namespace; e.matchedIdentity = match.id; e.source = match.source.rawValue; e.sourceURL = match.sourceURL; e.role = rule.role.rawValue; e.confirmation = rule.confirmation.status.rawValue
                result.evidence.append(e)
                if authoritative { result.publisherSignal = true }
                if !authoritative || rule.action == .review { result.review = true }
                else {
                    result.publisherSignal = true
                    if rule.action == .block { result.publisherBlock = true }
                    else { result.publisherScore = max(result.publisherScore, rule.score) }
                }
            }
        }
        if config.publishers {
            let identityRequired = (category.publisherRules ?? []).contains { rule in
                guard rule.enabled, rule.action != .review, rule.confirmation.status == .confirmed,
                      let expiry = AdvancedRulesValidator.date(rule.expiresAt), let confirmed = AdvancedRulesValidator.date(rule.confirmation.at),
                      expiry > now, confirmed <= now else { return false }
                return rule.scope == .allShows || rule.showIDs.contains(show.id)
            }
            let hasFreshStableIdentity = (show.publisherIdentities ?? []).contains { identity in
                identity.namespace == "apple.podcasts.artist" && identity.source != .rss &&
                identity.id.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } == true && fresh(identity.observedAt)
            }
            if identityRequired && !hasFreshStableIdentity {
                result.review = true
                if !result.evidence.contains(where: { $0.family == "publishers" && $0.kind == "identityUnavailable" }) {
                    var missing = RuleEvidence(ruleID: "publisher-identity-required", kind: "identityUnavailable", fields: [.author], value: "缺少可验证的发布账号身份，无法排除已启用的账号限制", contribution: 0)
                    missing.family = "publishers"; missing.namespace = "apple.podcasts.artist"; missing.confirmation = "unavailable"
                    result.evidence.append(missing)
                }
            }
        }
        // Multiple rules derived from one metadata family must not multiply its contribution.
        for family in ["appleCategories", "publishers"] {
            let indexes = result.evidence.indices.filter { result.evidence[$0].family == family && result.evidence[$0].contribution > 0 }
            let best = indexes.max { result.evidence[$0].contribution < result.evidence[$1].contribution }
            for i in indexes where i != best { result.evidence[i].contribution = 0; result.evidence[i].kind += "DuplicateEvidence" }
        }
        return result
    }
}
