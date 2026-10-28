import PodcastModels
import ContentFiltering
import Foundation
import Security
import CommonCrypto

public protocol SecureRecordStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
public struct KeychainRecordStore: SecureRecordStore {
    public init() {}
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.quietcast.family.parent", kSecAttrAccount as String: "parent-record-v1"] }
    public func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PodcastError.pin("家长安全存储不可用 (\(status))，已保持锁定。") }
        return data
    }
    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PodcastError.pin("无法写入家长安全存储 (\(addStatus))") }
        } else if status != errSecSuccess { throw PodcastError.pin("无法更新家长安全存储 (\(status))") }
    }
}
public enum PINKDF {
    public static let rounds: UInt32 = 210_000
    public static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PodcastError.pin("系统随机数不可用") }
        return Data(bytes)
    }
    public static func derive(pin: String, salt: Data, rounds: UInt32 = rounds) throws -> Data {
        guard rounds >= 1, salt.count >= 16 else { throw PodcastError.pin("密码参数无效") }
        var output = [UInt8](repeating: 0, count: 32)
        let password = Array(pin.utf8)
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw PodcastError.pin("密码派生失败") }
        return Data(output)
    }
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
public struct ParentGrant: Hashable {
    fileprivate let id: UUID
    fileprivate let expires: Date
}
private struct ParentRecord: Codable {
    var version = 1
    var salt: Data
    var verifier: Data
    var rounds: UInt32
    var failures = 0
    var retryAfter: Date?
    var policy = ParentalPolicy()
    var importedRules: Data?
}
/// Keep on the application main actor. No public reset/delete API exists.
public final class ParentAuthority {
    private let store: any SecureRecordStore
    private let now: () -> Date
    private var record: ParentRecord?
    private var activeGrant: ParentGrant?
    public var configured: Bool { record != nil }
    public var policy: ParentalPolicy { record?.policy ?? ParentalPolicy() }
    public var importedRules: Data? { record?.importedRules }
    public var retryAfter: Date? { record?.retryAfter }
    public init(store: any SecureRecordStore = KeychainRecordStore(), now: @escaping () -> Date = Date.init) throws {
        self.store = store; self.now = now
        if let data = try store.read() {
            do {
                let value = try JSONDecoder().decode(ParentRecord.self, from: data)
                guard value.version == 1, value.salt.count == 32, value.verifier.count == 32, value.rounds >= PINKDF.rounds, value.rounds <= 1_000_000, value.failures >= 0 else { throw PodcastError.pin("家长安全记录损坏") }
                record = value
            } catch { throw PodcastError.pin("家长安全记录无法读取，过滤保持锁定；不会自动清空 PIN。") }
        }
    }
    public func setup(pin: String, confirmation: String, recoveryAcknowledged: Bool) throws -> ParentGrant {
        guard record == nil else { throw PodcastError.pin("已设置家长 PIN，请验证原 PIN") }
        try validatePIN(pin, confirmation)
        guard recoveryAcknowledged else { throw PodcastError.pin("请先确认 PIN 无法找回并妥善保管") }
        let salt = try PINKDF.randomSalt()
        let value = ParentRecord(salt: salt, verifier: try PINKDF.derive(pin: pin, salt: salt), rounds: PINKDF.rounds)
        try persist(value)
        return grant()
    }
    public func authenticate(pin: String) throws -> ParentGrant {
        guard var value = record else { throw PodcastError.pin("尚未设置家长 PIN") }
        if let retry = value.retryAfter, retry > now() { throw PodcastError.pin("尝试过多，请在 \(Int(ceil(retry.timeIntervalSince(now())))) 秒后重试") }
        let candidate = try PINKDF.derive(pin: pin, salt: value.salt, rounds: value.rounds)
        guard PINKDF.constantTimeEqual(candidate, value.verifier) else {
            value.failures = min(30, value.failures + 1)
            if value.failures >= 5 { value.retryAfter = now().addingTimeInterval(min(3600, 30 * pow(2, Double(value.failures - 5)))) }
            try persist(value); activeGrant = nil
            throw PodcastError.pin(value.failures >= 5 ? "PIN 错误，已启用延迟限制" : "PIN 错误，还可尝试 \(5 - value.failures) 次后启用延迟")
        }
        value.failures = 0; value.retryAfter = nil; try persist(value)
        return grant()
    }
    public func isAuthorized(_ grant: ParentGrant?) -> Bool { grant != nil && grant == activeGrant && grant!.expires > now() }
    public func lock() { activeGrant = nil }
    public func updatePolicy(_ policy: ParentalPolicy, grant: ParentGrant) throws {
        try require(grant)
        guard var value = record else { throw PodcastError.pin("未配置 PIN") }
        guard policy.customKeywords.count <= 100, policy.customKeywords.allSatisfy({ $0.count <= 128 && !TextNormalizer.normalize($0).isEmpty }) else { throw PodcastError.pin("屏蔽词最多 100 个，每个 1～128 字") }
        value.policy = policy; try persist(value)
    }
    public func importRules(_ data: Data, grant: ParentGrant) throws -> RuleSet {
        try require(grant)
        let rules = try RulesLoader.decode(data)
        guard var value = record else { throw PodcastError.pin("未配置 PIN") }
        let available = Set(rules.categories.filter(\.enabled).map(\.id))
        guard !value.policy.enabled || value.policy.enabledCategoryIDs.isSubset(of: available) else { throw PodcastError.rule("新规则缺少当前启用的类别；未替换原规则") }
        value.importedRules = data
        try persist(value)
        return rules
    }
    public func changePIN(_ pin: String, confirmation: String, grant: ParentGrant) throws {
        try require(grant); try validatePIN(pin, confirmation)
        guard var value = record else { throw PodcastError.pin("未配置 PIN") }
        value.salt = try PINKDF.randomSalt(); value.verifier = try PINKDF.derive(pin: pin, salt: value.salt)
        value.rounds = PINKDF.rounds; try persist(value)
    }
    private func validatePIN(_ pin: String, _ confirmation: String) throws {
        guard (6...12).contains(pin.count), pin.utf8.allSatisfy({ (48...57).contains($0) }), pin == confirmation else { throw PodcastError.pin("请输入一致的 6～12 位数字 PIN") }
    }
    private func require(_ grant: ParentGrant) throws { guard isAuthorized(grant) else { throw PodcastError.pin("家长授权已过期，请重新验证 PIN") } }
    private func grant() -> ParentGrant { let g = ParentGrant(id: UUID(), expires: now().addingTimeInterval(120)); activeGrant = g; return g }
    private func persist(_ value: ParentRecord) throws { try store.write(JSONEncoder().encode(value)); record = value }
}
