# 源码保存、重新拉取和版本开发

## 仓库保存什么

保存完整 App 源码、Xcode 工程、本地 Swift Package、规则、测试、构建脚本、中文文档与脱敏后的研究材料。不保存 Xcode／Swift 缓存、设备备份、手机收听数据、IPA、签名证书、Apple 账号和原个人提交历史。这些缓存可以重建，签名应由使用者自己完成。

## 将来换电脑或重新拉取

```sh
# 将占位地址替换为本项目实际仓库地址
git clone <仓库地址> QuietCast
cd QuietCast
git switch main
open QuietCast.xcodeproj
```

安装完整 Xcode 后，按 README 运行核心测试、模拟器构建和 `Scripts/build-ipa.sh`。需要恢复固定版本时，先 `git tag --list`，再 `git switch --detach v1.1.2`。继续开发可从该版本创建自己的新分支。

首次上传之后，**先在另一个目录从远端完整克隆并检查源码、词库、文档和标签**，再决定是否删除旧本地目录。最占空间的 `build/`、`.build/` 是可重建缓存；本次上传任务不会自动删除它们。若有唯一的手机沙盒备份或尚未发布的版本记录，请先另外加密保存。Git 不会恢复 App 手机端状态。

## 后续做版本

```sh
git switch main
git pull --ff-only
git switch -c codex/next-version
# 修改源码，更新版本号与说明，执行相应测试
git diff --check
git status --short
# 运行发布扫描，再逐项检查本次要提交的文件
python3 Scripts/audit-public.py .
git add <明确检查过的文件>
git commit -m "说明本次修改"
git push -u origin codex/next-version
```

提交前配置仓库级公开作者身份，例如 `git config user.name "QuietCast Contributors"` 和 `git config user.email "quietcast@example.invalid"`，不要依赖本机默认用户名／邮箱。占位邮箱不用于接收邮件。公开 GitHub 仓库的所属账号仍会显示在 URL 和拥有者信息中；作者脱敏不隐藏平台上的仓库归属。

发布版本时同步 App 的版本与 build、README 和版本记录，再创建标签并推送。标签只固定源码，安装 IPA 仍需要自己构建并签名。

## 不要误提交

`.gitignore` 已覆盖常见凭据、构建文件和设备资料，但忽略规则无法撤销已经跟踪的文件。不要把真实手机记录、账户凭据或已签名包放进源码目录；每次发布前扫描工作树与提交内容。若不慎上传真实密钥，立即撤销密钥并处理仓库历史，单纯删除最新文件不足以消除旧提交中的泄露。
