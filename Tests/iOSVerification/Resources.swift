import Foundation
private final class VerificationResources: NSObject {}
extension Bundle {
    static var module: Bundle { Bundle(for: VerificationResources.self) }
}
