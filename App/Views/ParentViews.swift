import Combine
import PodcastCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ParentAccessView<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let content: (ParentGrant) -> Content
    @State private var grant: ParentGrant?
    @State private var pin = ""
    @State private var confirm = ""
    @State private var acknowledged = false
    @State private var error: String?
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            Group {
                if let grant, store.authority?.isAuthorized(grant) == true {
                    content(grant)
                } else {
                    Form {
                        Section {
                            Label("家长管理", systemImage: "lock.shield").font(.title2.bold())
                            Text(store.authority?.configured == true ? "请输入家长 PIN。授权两分钟后或 App 离开前台时失效。" : "首次启用请设置 6～12 位数字 PIN，只有家长可以修改内容规则。")
                        }
                        if let securityError = store.securityError, store.authority == nil { Text(securityError).foregroundStyle(.red) }
                        else {
                            Section("家长 PIN") {
                                SecureField("6～12 位数字", text: $pin).keyboardType(.numberPad).textContentType(.password)
                                if store.authority?.configured != true {
                                    SecureField("再次输入 PIN", text: $confirm).keyboardType(.numberPad).textContentType(.newPassword)
                                    Text("没有云端找回或偏好设置重置入口。忘记 PIN 无法恢复，请立即存入密码管理器。卸载 App 不保证清除 Keychain；覆盖安装请保持相同 Bundle ID 与签名身份。").font(.footnote).foregroundStyle(.secondary)
                                    Toggle("我已记录 PIN 并理解无法找回", isOn: $acknowledged)
                                }
                                if let until = store.authority?.retryAfter, until > tick { Text("可重试时间：\(until.formatted(date: .omitted, time: .standard))").font(.footnote) }
                                if let error { Text(error).foregroundStyle(.red) }
                                Button(store.authority?.configured == true ? "验证" : "设置并进入") {
                                    Keyboard.dismiss()
                                    do { grant = try store.authenticate(pin: pin, confirm: confirm, acknowledged: acknowledged); pin = ""; confirm = ""; error = nil }
                                    catch { self.error = error.localizedDescription; pin = "" }
                                }.disabled(pin.isEmpty || (store.authority?.retryAfter ?? .distantPast) > tick)
                            }
                        }
                    }
                }
            }.navigationTitle("家长授权").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.id(grant).onReceive(timer) { tick = $0; if let g = grant, store.authority?.isAuthorized(g) != true { grant = nil } }
            .onDisappear { store.lockParent() }
    }
}
@MainActor
struct UnlockView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: UnlockRequest
    let grant: ParentGrant
    @State private var error: String?
    var body: some View {
        Form {
            Section("拦截原因") { Text(request.show.title).font(.headline); if let ep = request.episode { Text(ep.title) }; VerdictView(result: request.result) }
            Section("设置持久例外") {
                if request.episode != nil { Button("允许此单集") { allow(episode: request.episode) } }
                Button("允许整个节目") { allow(episode: nil) }
                Text("例外会保存在家长安全存储中。授权后请重新执行播放或下载。").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("家长解锁")
    }
    private func allow(episode: Episode?) { do { try store.setException(show: request.show, episode: episode, allow: true, grant: grant); dismiss() } catch { self.error = error.localizedDescription } }
}
@MainActor
struct VerdictView: View {
    let result: FilterResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.reason)
            Text("判定 \(result.decision.rawValue) · 分数 \(result.score, specifier: "%.2f") · 版本 \(result.ruleVersion)").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                if let family = evidence.family { Text("规则来源：\(family) · \(evidence.source ?? "本地规则")").font(.caption).foregroundStyle(.secondary) }
                if let identity = evidence.matchedIdentity { Text("匹配身份：\(evidence.namespace ?? "") / \(identity)").font(.caption) }
                if let confirmation = evidence.confirmation { Text("账号确认状态：\(confirmation) · 角色：\(evidence.role ?? "unknown")").font(.caption) }
                Text("\(evidence.ruleID) · \(evidence.kind) · \(evidence.fields.map(\.rawValue).joined(separator: ", ")) · \(evidence.value) · \(evidence.contribution, specifier: "%.2f")").font(.caption)
            }
        }
    }
}
@MainActor
struct ShowParentActions: View {
    @EnvironmentObject private var store: AppStore
    let show: Podcast
    let grant: ParentGrant
    @State private var error: String?
    var body: some View {
        Form {
            Section { Text(show.title).font(.headline); VerdictView(result: store.result(show: show)) }
            Section {
                Button("永久允许这个节目") { perform { try store.setException(show: show, episode: nil, allow: true, grant: grant) } }
                Button("永久禁止这个节目", role: .destructive) { perform { try store.setException(show: show, episode: nil, allow: false, grant: grant) } }
                Button("移除该节目例外") { perform { var p = store.policy; p.showAllowlist.remove(show.id); p.showBlocklist.remove(show.id); try store.updatePolicy(p, grant: grant) } }
            }
            Section("单集规则") {
                ForEach(store.library.episodes.values.filter { $0.podcastID == show.id }.sorted { $0.title < $1.title }) { episode in
                    VStack(alignment: .leading) {
                        Text(episode.title)
                        HStack { Button("允许") { perform { try store.setException(show: show, episode: episode, allow: true, grant: grant) } }; Button("禁止", role: .destructive) { perform { try store.setException(show: show, episode: episode, allow: false, grant: grant) } } }.buttonStyle(.borderless)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("节目家长规则")
    }
    private func perform(_ body: () throws -> Void) { do { try body(); error = nil } catch { self.error = error.localizedDescription } }
}
@MainActor
struct ParentSettingsView: View {
    @EnvironmentObject private var store: AppStore
    let grant: ParentGrant
    @State private var keyword = ""
    @State private var importFile = false
    @State private var error: String?
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    var body: some View {
        Form {
            Section("过滤模式") {
                Toggle("开启内容过滤", isOn: Binding(get: { store.policy.enabled }, set: { value in modify { $0.enabled = value } }))
                ForEach(store.rules?.categories ?? [], id: \.id) { category in
                    Toggle(category.name, isOn: Binding(get: { store.policy.enabledCategoryIDs.contains(category.id) }, set: { value in modify { if value { $0.enabledCategoryIDs.insert(category.id) } else { $0.enabledCategoryIDs.remove(category.id) } } })).disabled(!category.enabled)
                    Text(category.description).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(store.policy.enabledCategoryIDs.subtracting(Set(store.rules?.categories.filter(\.enabled).map(\.id) ?? []))).sorted(), id: \.self) { missing in
                    Button("移除缺失类别：\(missing)") { modify { $0.enabledCategoryIDs.remove(missing) } }
                }
                Text("色情擦边、恐怖猎奇、赌博等类别尚无词库，暂不可启用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Podcasts 分类") {
                NavigationLink("查看全部分类与子分类限制") { AppleCategorySettingsView(grant: grant) }
            }
            Section("使用记录") {
                NavigationLink("搜索记录") { ParentSearchHistoryView(grant: grant) }
            }
            Section("规则文件") {
                Text("版本：\(store.rules?.ruleVersion ?? "加载失败")")
                if store.rules?.status == "example" { Text("示例词库，不能视为正式防护；等待任务 B 的研究规则。").foregroundStyle(.orange) }
                Button("从本地 JSON 导入并验证") { importFile = true }
                Text("验证失败不会替换原词库。更新后立即重新校验播放、队列和下载权限。").font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义屏蔽词") {
                HStack { TextField("家长明确希望屏蔽的词", text: $keyword).submitLabel(.done).onSubmit { addKeyword() }; Button("添加") { addKeyword() }.disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(store.policy.customKeywords, id: \.self) { term in HStack { Text(term); Spacer(); Button("删除", role: .destructive) { modify { $0.customKeywords.removeAll { $0 == term } } } } }
            }
            Section("家长例外") {
                ForEach(Array(store.policy.showAllowlist.union(store.policy.showBlocklist)).sorted(), id: \.self) { id in
                    exceptionRow(id, title: store.library.podcasts[id]?.title ?? id, blocked: store.policy.showBlocklist.contains(id), episode: false)
                }
                ForEach(Array(store.policy.episodeAllowlist.union(store.policy.episodeBlocklist)).sorted(), id: \.self) { id in
                    exceptionRow(id, title: store.library.episodes[id]?.title ?? id, blocked: store.policy.episodeBlocklist.contains(id), episode: true)
                }
                NavigationLink("为已加载节目添加允许 / 禁止") {
                    List(store.library.podcasts.values.sorted { $0.title < $1.title }) { show in NavigationLink(show.title) { ShowParentActions(show: show, grant: grant) } }.navigationTitle("选择节目")
                }
            }
            Section {
                NavigationLink("被拦截记录（\(store.blockEvents.count)）") {
                    List(store.blockEvents) { event in
                        NavigationLink { Form { Text(event.show.title).font(.headline); if let ep = event.episode { Text(ep.title) }; Text("入口：\(event.entry.rawValue)"); Text(event.date, style: .date); VerdictView(result: event.result); Button("纠正：允许此内容") { perform { try store.setException(show: event.show, episode: event.episode, allow: true, grant: grant) } }; Button("允许整个节目") { perform { try store.setException(show: event.show, episode: nil, allow: true, grant: grant) } } } } label: { VStack(alignment: .leading) { Text(event.episode?.title ?? event.show.title); Text(event.result.reason).font(.caption).foregroundStyle(.secondary) } }
                    }.navigationTitle("拦截记录")
                }
            }
            Section("修改家长 PIN") {
                SecureField("新 PIN（6～12 位数字）", text: $newPIN).keyboardType(.numberPad)
                SecureField("确认新 PIN", text: $confirmPIN).keyboardType(.numberPad)
                Button("保存新 PIN") { Keyboard.dismiss(); perform { try store.authority?.changePIN(newPIN, confirmation: confirmPIN, grant: grant); newPIN = ""; confirmPIN = "" } }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("家长管理")
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in perform { guard let url = try result.get().first else { return }; try store.importRules(url, grant: grant) } }
    }
    private func addKeyword() {
        Keyboard.dismiss()
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        modify { $0.customKeywords.append(term) }; keyword = ""
    }
    private func exceptionRow(_ id: String, title: String, blocked: Bool, episode: Bool) -> some View {
        HStack { VStack(alignment: .leading) { Text(title).lineLimit(2); Text(blocked ? "禁止" : "允许").font(.caption).foregroundStyle(blocked ? .red : .green) }; Spacer(); Button("移除", role: .destructive) { modify { p in if episode { p.episodeAllowlist.remove(id); p.episodeBlocklist.remove(id) } else { p.showAllowlist.remove(id); p.showBlocklist.remove(id) } } } }
    }
    private func modify(_ body: (inout ParentalPolicy) -> Void) { perform { var p = store.policy; body(&p); try store.updatePolicy(p, grant: grant) } }
    private func perform(_ body: () throws -> Void) { do { try body(); error = nil } catch { self.error = error.localizedDescription } }
}

@MainActor
struct ParentSearchHistoryView: View {
    @EnvironmentObject private var store: AppStore
    let grant: ParentGrant
    @State private var records: [SearchRecord] = []
    @State private var error: String?
    @State private var confirmClear = false
    var body: some View {
        List {
            Section {
                Text("仅在本机保留最近 200 个不同关键词；相同关键词合并计数。记录搜索提交，包括未找到结果或网络失败的搜索。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if records.isEmpty && error == nil {
                Text("还没有搜索记录").foregroundStyle(.secondary)
            }
            Section {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.term)
                        Text("搜索 \(record.count) 次 · \(record.lastSearchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }.onDelete { offsets in
                    remove(Set(offsets.map { records[$0].id }))
                }
            }
        }.navigationTitle("搜索记录")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空", role: .destructive) { confirmClear = true }.disabled(records.isEmpty && error == nil)
            } }
            .confirmationDialog("删除全部搜索记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空全部记录", role: .destructive) { remove(nil) }
                Button("取消", role: .cancel) {}
            }
            .onAppear { reload() }
    }
    private func reload() {
        do { records = try store.parentSearchRecords(grant: grant); error = nil }
        catch { records = []; self.error = error.localizedDescription }
    }
    private func remove(_ ids: Set<String>?) {
        do { try store.deleteSearchRecords(ids: ids, grant: grant); reload() }
        catch { records = []; self.error = error.localizedDescription }
    }
}
