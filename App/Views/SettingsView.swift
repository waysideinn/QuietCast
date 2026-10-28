import PodcastCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var parent = false
    var body: some View {
        Form {
            Section("播放") {
                Picker("快退秒数", selection: preference(\.backwardSeconds)) { ForEach([Double(5),10,15,30,45,60], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                Picker("快进秒数", selection: preference(\.forwardSeconds)) { ForEach([Double(5),10,15,30,45,60], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                Toggle("连续播放", isOn: preference(\.continuous))
                Picker("下载空间上限", selection: preference(\.downloadLimitGB)) { ForEach([1,3,5,10,20], id: \.self) { Text("\($0) GB").tag($0) } }
            }
            Section("家长管理") {
                Button { parent = true } label: { Label("验证家长 PIN", systemImage: "lock.shield") }
                Text(store.authority?.configured == true ? "已设置 PIN；查看或修改家长规则必须验证。" : "尚未设置 PIN。请由家长完成首次设置。默认已启用示例过滤。").font(.caption).foregroundStyle(.secondary)
                if let error = store.securityError { Text(error).font(.caption).foregroundStyle(.red); Button("设备解锁后重试安全存储") { store.retrySecurity() } }
            }
            Section("关于听芽") {
                Text("原生播客播放器 · iOS 16+")
                Text("搜索来自 Apple iTunes 公开目录，音频与封面来自节目发布者的公开 RSS。App 不上传收听记录，没有账号或付费 AI。").font(.footnote).foregroundStyle(.secondary)
                Text("家长过滤依赖节目元数据和词库，不能识别音频中未写入元数据的内容。当前内置规则是接口样例，正式词库待接入。").font(.footnote).foregroundStyle(.secondary)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）").font(.caption)
                NavigationLink("过滤规则说明") { RuleInformationView() }
            }
        }.navigationTitle("设置").sheet(isPresented: $parent) { ParentAccessView { grant in ParentSettingsView(grant: grant) } }
    }
    private func preference<Value>(_ keyPath: WritableKeyPath<PlayerPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.library.preferences[keyPath: keyPath] }, set: { value in
            store.change { $0.preferences[keyPath: keyPath] = value }
            store.player.updatePreferences(store.library.preferences)
        })
    }
}
