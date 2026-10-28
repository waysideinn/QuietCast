#if DEBUG
import SwiftUI

/// Opt-in measurements for hosted layout tests; no fixture controls ship in Release.
@MainActor
enum LayoutDiagnostics {
    static var activeID: UUID?
    static var frames: [String: CGRect] = [:]
}
private struct LayoutCaptureKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var layoutCaptureID: UUID? {
        get { self[LayoutCaptureKey.self] }
        set { self[LayoutCaptureKey.self] = newValue }
    }
}
private struct LayoutCapture: ViewModifier {
    @Environment(\.layoutCaptureID) private var captureID
    let id: String
    func body(content: Content) -> some View {
        content.background {
            if let captureID {
                GeometryReader { geometry in
                    Color.clear.onAppear { if LayoutDiagnostics.activeID == captureID { LayoutDiagnostics.frames[id] = geometry.frame(in: .global) } }
                        .onChange(of: geometry.frame(in: .global)) { if LayoutDiagnostics.activeID == captureID { LayoutDiagnostics.frames[id] = $0 } }
                }
            }
        }
    }
}
extension View { func captureLayout(_ id: String) -> some View { modifier(LayoutCapture(id: id)) } }
#else
import SwiftUI
extension View { func captureLayout(_ id: String) -> some View { self } }
#endif
