import SwiftUI
import UIKit

@MainActor
enum Keyboard {
    static func dismiss() {
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) where window.isKeyWindow {
            window.endEditing(true)
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Read UIKit's committed text at Return, rather than racing a later SwiftUI onChange delivery.
@MainActor
struct PodcastSearchField: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "搜索节目、作者或关键词"
        field.returnKeyType = .search; field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.adjustsFontForContentSizeCategory = true; field.font = .preferredFont(forTextStyle: .body)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityLabel = "搜索节目、作者或关键词"; field.accessibilityIdentifier = "explore.search"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(44, (uiView.font?.lineHeight ?? 22) + 12))
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.markedTextRange == nil && field.text != text { field.text = text }
    }
    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) { field.resignFirstResponder(); field.delegate = nil }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PodcastSearchField
        init(_ parent: PodcastSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.unmarkText()
            let committed = field.text ?? ""
            parent.text = committed
            field.resignFirstResponder()
            Keyboard.dismiss()
            parent.onSubmit(committed)
            return false
        }
    }
}
