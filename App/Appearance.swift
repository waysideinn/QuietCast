import SwiftUI
import UIKit

extension UIColor {
    static let listeningAccent = UIColor { traits in
        if traits.userInterfaceStyle == .dark { return UIColor(red: 0.32, green: 0.82, blue: 0.85, alpha: 1) }
        return UIColor(red: 0.0, green: 0.43, blue: 0.46, alpha: 1)
    }
}
extension Color { static let listeningAccent = Color(uiColor: .listeningAccent) }
