import SwiftUI
import PodcastCore

@MainActor struct AppleCategorySettingsView: View {
    @EnvironmentObject private var store: AppStore
    let grant: ParentGrant
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("禁用父分类会隐藏所有子分类。只禁用子分类会保留父分类与其他子分类。家长明确允许的节目或单集例外仍按原优先级生效。").font(.footnote).foregroundStyle(.secondary) }
            ForEach(PodcastCategories.roots) { category in
                Section {
                    toggle(category, inherited: false)
                    ForEach(category.children) { child in toggle(child, inherited: store.policy.blockedAppleCategories?.contains(category.id) == true) }
                } header: { Text(category.title) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Apple 分类限制")
    }
    private func toggle(_ category: PodcastCategory, inherited: Bool) -> some View {
        Toggle(isOn: Binding(get: { !inherited && store.policy.blockedAppleCategories?.contains(category.id) != true }, set: { allowed in
            do {
                var policy = store.policy; var blocked = policy.blockedAppleCategories ?? []
                if allowed { blocked.remove(category.id) } else { blocked.insert(category.id) }
                policy.blockedAppleCategories = blocked; try store.updatePolicy(policy, grant: grant); error = nil
            } catch { self.error = error.localizedDescription }
        })) {
            VStack(alignment: .leading) { Text(category.title); if inherited { Text("随父分类隐藏").font(.caption).foregroundStyle(.secondary) } }
        }.disabled(inherited)
    }
}
