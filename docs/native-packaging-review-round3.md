# 简账构建与安装合同第三轮独立审查

日期：2026-10-05（Asia/Shanghai）。结论：**WARNING，1 项新的 HIGH 待修复**。第二轮三个 HIGH 的源码修复已复核。此结论不等于安装或平台验收通过。

范围与方法：先检查 staged/worktree diff；目标仍为新增未跟踪文件，因此读取完整 PowerShell/NSIS 源码及调用周边。审查两个 build 脚本、source/environment 合同、Windows package 与 NSIS、Windows startup measure。helper 本体由独立 C# 审查负责，本报告只读取其安装身份和 uninstall-preflight 边界。没有改生产代码，没有执行安装器、卸载器、注册表探测、Flutter tester 或正式性能测量。

## [HIGH] 卸载过早删除身份文件，后续失败后保留的卸载器不能重试

File: `scripts/package-windows-client.ps1:129`、`:130`；`clients/flutter/packaging/windows/installer.nsi:394`、`:407`、`:412`、`:417`；`scripts/native-toolchain/installer-transaction.cs:282`、`:349`。

Issue: 新增的 uninstall-preflight 必须读取 `.jianzhang-install-id` 与 `.jianzhang-payload.json`，两者缺失就停止，不允许删除文件。但是 package 生成的 BUNDLE_DELETE 在普通 payload 后立即删除这两个身份文件；NSIS 随后才删除快捷方式、注册表和 `Uninstall.exe`。若任一后段操作失败，退出 2 并保留/恢复卸载器登记，但再次运行会在新 preflight 因身份文件已被上一轮删除而永久拒绝。

确定故障序列：全部 payload 及身份文件删除成功 → `简账.lnk` 被独占不能删除（或登记删除失败）→ `uninstall_failed` → 原 `Uninstall.exe` 仍在 → 用户解除占用后重试 → `ReadOwnedPayload` 因缺少两份身份文件拒绝。即使最后删除 uninstaller 失败并成功恢复 registry，其恢复入口同样缺少 preflight 所需身份，不能正常重试。该问题属于新增身份防护与 NSIS 删除顺序的行为回归，不要求执行被禁止的独立 Registry probe 才能确定。

Fix: 将身份元数据保留到所有可能失败且需要重试的删除阶段完成，或采用可验证、幂等的卸载恢复状态。最后清理身份与 uninstaller 的边界也应确保中断或任一删除失败后可以继续，不能只移动两行而留下等价的最终窗口。补完整安装器 QA：后段快捷方式/登记/最后文件删除失败，退出非零、账本和用户文件保留；解除故障后同一个卸载器能完成重试。

## 第二轮 HIGH 修复复核

- **完整启动 payload 证据**：PayloadManifest 现为必填；schema-2 delivery source 与 build source、buildPayload 与 release payload 比较，记录安装器 SHA 并核对真实文件；测量目录的全部记录 payload 逐项检查大小、路径及 SHA，包含 AOT、engine、plugins、SQLite、CRT、assets，测量后再次检查完整 payload 和 sidecar SHA。允许附加用户文件不会让记录 payload 缺失或变化被忽略。保留进程外 Stopwatch 起点、native post-ledger rendered-frame marker、20–100 次 fresh-process 样本、失败不输出通过结果及 nearest-rank p95。真实 20 次仍未由本审查执行。
- **根/祖先 junction 防护**：Assert-NoReparsePath 自卷根逐层检查已有祖先及目标的类型与 ReparsePoint；Assert-WorkspacePath 加规范化边界。两 build 脚本在创建/枚举/清理前检查 client/build-client，删除前检查后代；Windows plugin junction 仅在已验证的自身目录中非递归 unlink。共享 Get-TreeFiles 也检查根及祖先，排除之前的根 junction 穿透缺陷。
- **Android release 生成合同**：只精确排除生成的 GeneratedPluginRegistrant、plugin metadata 与 `.dart_tool` 生成输入；手写 Activity、pubspec 与 lockfile 仍纳入 source。复制 metadata 与最终生成 metadata/registrant分别记录 SHA。正式 build 移除 --no-pub，使官方 release 插件生成与 Gradle 正式依赖一致，并复核生成前后手写输入合同。Root 实际 debug → release 重新生成及 `compileReleaseJavaWithJavac` 已成功；这份证据仅证明编译路径修复，不表示 APK 已通过签名/16 KB/安装验收。

## 其他合同与证据

- Windows package 仍验证 SDK、版本、完整 source/build payload，复制独占稳定 snapshot，分别记录 CRT、installer source、helper/config SHA，NSIS 编译后复核输入再原子发布 setup。
- NSIS prepare → 同卷 stage → commit 保留明确退出码；提取失败/用户中止调用 rollback，统一 TransactionRunner 先切离 stage 当前目录。嵌入 config SHA 与 helper contract 相匹配；QA 故障参数只在 QA 编译中解析。
- 新 uninstall-preflight 在删除前核对当前 owned metadata 身份与本卸载器版本/完整文件合同；修改过的 owned 路径停止卸载，missing payload 允许前半段删除后的重试。上述 HIGH 发生在身份文件删除后的后半段。
- 卸载删除清单由完整安装 payload 生成，无递归删除用户目录；支持数据目录未列入。用户附加文件升级保留和清理时的 helper 行为另见 C# 专项报告，本报告不代其审批。
- 六份目标 PowerShell 当前 AST 解析均为 0 errors。已核对 Root 的 `.qa/build-path-verification.json`：16/16、targetUnchanged=true、时间 `2026-10-05T06:34:21.5265942Z`。本轮未重复执行同一 deterministic suite。
- `.qa/android-release-classpath-verification.log` 最后记录 BUILD SUCCESSFUL in 57s、55 actionable tasks、正式 Java compile 与 debug→release regeneration PASS，并明确 No APK published。
- 当前 release/APK 重建由 Root 进行。完整 Windows 首装/升级/卸载、真实 20 次启动与六个 Android API 的安装运行仍待实际 QA；Windows 10、安卓真机、真实短信保持约定未验证范围。

## 审查时源码身份

| 文件 | SHA-256 |
|---|---|
| build-windows.ps1 | c5fef036fef5572a023dc80c8762334a7f5404a48aad9518bd5c6569f5af48c2 |
| build-android.ps1 | 0a08e6f7493dd80d5b7338452d4b01e4928518aa811965a3fbee68c1778e9fd7 |
| source-contract.ps1 | f29c01694a178dae18e73801bef9e90c3ebd3288e33c522f0b6b98f66586ad44 |
| environment-scope.ps1 | 63a5c157c8f18150817ee5270b84c3742f3a27c9569050bbe0bc33a696cb4db2 |
| package-windows-client.ps1 | 40fa6549ab0198d15dc9d2933461a5023245eb60687f16a3278c3987726cf0fe |
| measure-windows-startup.ps1 | f338f57e1b6624eba2bc89d51804d64145eb83dead9c59dbe2aed20c7390e7a8 |
| installer.nsi | 78e0e50c90835606f0e5333da61a2f41bb83b9a4a212406baaea9c0420e0b1c7 |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 1 | warn |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: WARNING — 新的卸载失败重试 HIGH 应在最终安装验收前修复并独立复核。
