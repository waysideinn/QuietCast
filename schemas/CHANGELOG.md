# 共享规则格式变更

## 1.1 — 2026-10-26

新增每类别可选 recognition、classificationRules、publisherRules；新增精确 Apple 分类 ID/名称/路径、发布账号稳定身份与确认/失效/部分节目范围，解释输出增加可选来源字段。新加载器和当前 Schema 接受 1.0 与 1.1，缺省新字段不改变旧词库的关键词判定。1.0 文件仍不能带未定义字段；旧版 App 不会误读新版规则。

原始 Schema 冻结为 content-filter.v1.0.schema.json；初始三文件提交仍为 9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360。v1.0 示例保留原样。新示例为 rules/example-multisource.json，仍明确标记 example，不含启用的真实账号名单。

新增运行时家长分类限制、RSS/目录来源元数据及缓存字段均为可缺省字段；旧 library.json、Keychain policy 与拦截日志可继续解码。分类设置属于家长本地策略，不由词库文件擅自覆盖。

精确语义见 content-filter-v1.1.md。任务 B 已通过其现有聊天收到契约通知；规则导入仍需通过 Schema 与 Swift 语义验证，不直接导入 research sidecar。
