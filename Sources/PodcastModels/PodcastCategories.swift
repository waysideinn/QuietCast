import Foundation

public struct PodcastCategory: Codable, Identifiable, Hashable, Sendable {
    public let appleID: String?
    public let path: [String]
    public let title: String
    public let aliases: [String]
    public let featured: Bool
    public init(appleID: String? = nil, path: [String], title: String, aliases: [String] = [], featured: Bool = false) {
        self.appleID = appleID; self.path = path; self.title = title; self.aliases = aliases; self.featured = featured
    }
    public var id: String { appleID ?? "name:" + path.joined(separator: "/") }
    public var parent: PodcastCategory? { guard path.count > 1 else { return nil }; return PodcastCategories.all.first { $0.path == Array(path.dropLast()) } }
    public var children: [PodcastCategory] { PodcastCategories.all.filter { $0.path.count == path.count + 1 && $0.path.starts(with: path) } }
}
/// Category taxonomy (not a hand-maintained show list). IDs are used where verified; other subcategories retain exact standard paths.
public enum PodcastCategories {
    public static let all: [PodcastCategory] = {
        let roots: [(String, String, String, Bool, [String])] = [
            ("1301","Arts","艺术",false,["Books","Design","Fashion & Beauty","Food","Performing Arts","Visual Arts"]),
            ("1321","Business","商业",false,["Careers","Entrepreneurship","Investing","Management","Marketing","Non-Profit"]),
            ("1303","Comedy","喜剧",false,["Comedy Interviews","Improv","Stand-Up"]),
            ("1304","Education","教育",true,["Courses","How To","Language Learning","Self-Improvement"]),
            ("1483","Fiction","小说",false,["Comedy Fiction","Drama","Science Fiction"]),
            ("1511","Government","政府",false,[]), ("1487","History","历史",true,[]),
            ("1512","Health & Fitness","健康与健身",false,["Alternative Health","Fitness","Medicine","Mental Health","Nutrition","Sexuality"]),
            ("1305","Kids & Family","儿童与家庭",false,["Education for Kids","Parenting","Pets & Animals","Stories for Kids"]),
            ("1502","Leisure","休闲",false,["Animation & Manga","Automotive","Aviation","Crafts","Games","Hobbies","Home & Garden","Video Games"]),
            ("1310","Music","音乐",false,["Music Commentary","Music History","Music Interviews"]),
            ("1489","News","新闻",true,["Business News","Daily News","Entertainment News","News Commentary","Politics","Sports News","Tech News"]),
            ("1314","Religion & Spirituality","宗教与精神生活",false,["Buddhism","Christianity","Hinduism","Islam","Judaism","Religion","Spirituality"]),
            ("1533","Science","科学",true,["Astronomy","Chemistry","Earth Sciences","Life Sciences","Mathematics","Natural Sciences","Nature","Physics","Social Sciences"]),
            ("1324","Society & Culture","社会与文化",true,["Documentary","Personal Journals","Philosophy","Places & Travel","Relationships"]),
            ("1545","Sports","体育",false,["Baseball","Basketball","Cricket","Fantasy Sports","Football","Golf","Hockey","Rugby","Running","Soccer","Swimming","Tennis","Volleyball","Wilderness","Wrestling"]),
            ("1318","Technology","科技",true,[]), ("1488","True Crime","真实犯罪",false,[]),
            ("1309","TV & Film","电视与电影",false,["After Shows","Film History","Film Interviews","Film Reviews","TV Reviews"])
        ]
        let known = AppleCategoryMetadata.ids
        let translations = ["Mental Health":"心理健康","Drama":"剧情","Science Fiction":"科幻小说","Comedy Fiction":"喜剧小说","Books":"图书","Language Learning":"语言学习","Self-Improvement":"自我提升","Natural Sciences":"自然科学","Social Sciences":"社会科学","Documentary":"纪录","Philosophy":"哲学","Relationships":"人际关系","Personal Journals":"个人日记","Places & Travel":"名胜与游记","Education for Kids":"儿童教育","Stories for Kids":"儿童故事"]
        var values: [PodcastCategory] = []
        for (id,name,title,featured,children) in roots {
            values.append(PodcastCategory(appleID: id, path: [name], title: title, aliases: Array(Set([name,title] + (AppleCategoryMetadata.aliases[id] ?? []))).sorted(), featured: featured))
            for child in children {
                let observedTitle = known[child].flatMap { AppleCategoryMetadata.aliases[$0]?.first }
                let title = translations[child] ?? observedTitle?.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? child
                values.append(PodcastCategory(appleID: known[child], path: [name,child], title: title, aliases: Array(Set([child,title] + (known[child].flatMap { AppleCategoryMetadata.aliases[$0] } ?? []))).sorted(), featured: child == "Mental Health"))
            }
        }
        return values
    }()
    public static var roots: [PodcastCategory] { all.filter { $0.path.count == 1 } }
    public static var featured: [PodcastCategory] { all.filter(\.featured) }
    public static func category(_ key: String) -> PodcastCategory? { all.first { $0.id == key } }
    private static func normalized(_ name: String) -> String {
        (name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name)
            .folding(options: [.caseInsensitive,.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    // The taxonomy is immutable. Transliteration belongs here, never inside each row's filter pass.
    private static let normalizedTaxonomy = all.map { ($0, $0.path.map(normalized), Set($0.aliases.map(normalized))) }
    public static func matching(_ observation: ClassificationObservation) -> [PodcastCategory] {
        guard observation.namespace == "apple.podcasts.genre" || observation.namespace == "rss.itunes.category" else { return [] }
        let path = observation.path.map(normalized), name = normalized(observation.name)
        return normalizedTaxonomy.compactMap { category, categoryPath, aliases in
            if observation.namespace == "apple.podcasts.genre", let id = observation.id, id == category.appleID { return category }
            if path.count > 1 { return categoryPath == path ? category : nil }
            return aliases.contains(name) ? category : nil
        }
    }
}
