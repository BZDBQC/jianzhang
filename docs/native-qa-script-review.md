# 双端 QA 脚本独立审查

日期：2026-10-05（Asia/Shanghai）。结论：**WARNING，2 项 HIGH 和 1 项 MEDIUM**。审查仅针对新增 QA 脚本；生产 PowerShell/NSIS 第四轮审批没有撤回。

范围：`test-windows-installer.ps1`、`test-android-ui.ps1`、`measure-android-startup.ps1`。先检查 staged/worktree diff，新增脚本直接读取完整文件与 artifact/source、Flutter readiness 周边调用。三份 PowerShell AST 均 0 errors。本轮没有执行安装器、卸载器、ADB、注册表探测或 Flutter tester，没有改实现。

## [HIGH] Windows RoundId 拼接后的文件和 ACL 目标未重新验证，能够越出 QA 根目录

File: `scripts/native-toolchain/test-windows-installer.ps1:6`、`:118`、`:119`、`:120`、`:178`、`:187`、`:194`。

Issue: 仅对输入 QaRoot/OutputDirectory 进行边界与链接校验，RoundId 未限制。RoundId 被直接拼入 target、external、first、fileTarget、ACL parent，后续 New-Item、WriteAllText、SetAttributes、Set-Acl 没有再次验证派生绝对路径属于本次 QA 根。`$qaPath` 自身安全不能保证这些派生路径安全。最终 NSIS 的 QA 目录 guard 无法保护脚本自己先执行的文件写入与 ACL 操作。

只计算路径的确定复现：QaRoot=`.../jianzhang/.qa/review-owned-root`、RoundId=`x\..\..\..\escaped`，两条 target/external 表达式经 GetFullPath 都得到 `.../jianzhang/escaped`，位于 `.qa` 外。没有创建或写入该目录。

Fix: 对 RoundId 使用固定安全标识符格式校验；同时在每个派生文件/目录使用前做 canonical Assert-WorkspacePath、QaRoot 后代边界、类型与 reparse-point 检查。结果文件与 byte-identical uninstaller copy 也应验证各自的最终路径。增加异常 RoundId/root/ancestor-link 的纯路径拒绝回归，确认没有 QA 外写入或权限改变。

## [HIGH] Windows 安装和 Android UI 测试接受旧候选，结果没有验证当前源码来源

File: `scripts/native-toolchain/test-windows-installer.ps1:18`、`:19`、`:54`、`:208`；`scripts/native-toolchain/test-android-ui.ps1:106`、`:109`、`:180`。

Issue: Windows 只验证 setup 与自身 sidecar 的 SHA、schema-2 和 qa=true，再按这份 sidecar 的 payload 验证安装结果，没有将 delivery source/buildPayload 与当前源码和当前 build manifest 核对。源码修复后，旧的有效 2.0.0 QA setup 及其旧 manifest 仍能完整跑过测试，并把调用者传入的新 BuildId 写为 pass。Android UI 同样只将已安装 APK SHA 与旧 release manifest 比较，没有核对 source manifest 和当前 client source。两个脚本可以产生真实执行但不属于当前候选的证据。

Fix: 在首次运行/修改设备前复用 build/package provenance 合同。Windows 核对 current client source、schema-2 Windows build source/payload、delivery source/buildPayload/版本/完整 payload、buildManifestSha 与实际 setup SHA；Android UI 核对 schema-2 release、source-manifest identity 与 current handwritten source，并核对指定实际 artifact。记录源、候选和 sidecar 身份，测试结束后重新验证冻结输入，拒绝中途变化。完整回归调用者仍须把这些身份与统一 BuildId 对应，不能单靠任意字符串标注。

## [MEDIUM] Windows 故障回滚只比较两个登记字段，不能验证完整旧登记恢复

File: `scripts/native-toolchain/test-windows-installer.ps1:41`、`:49`、`:50`、`:139`。

Issue: 18 个实际升级故障用例的注册回滚断言仅比较 InstallLocation 与 DisplayVersion。Publisher、DisplayIcon、UninstallString、NoModify/NoRepair、其他原有值及子键若丢失或被部分改写，这些用例仍报告 pass。Snapshot 已覆盖安装树与 shortcut 字节，但不包含登记状态。

Fix: 在完整 QA installer 工作流中只读捕获该 QA registration key 的全部值、类型和子键，故障后比较完整快照；首装失败仍应断言整个 key 不存在。读取属于已授权完整安装测试的状态断言，不需要另行执行或绕过被拒绝的独立 Registry probe。

## 已核对的正向证据与边界

- Windows subprocess 隐藏运行、使用实际退出码、超时只结束本次 child；卸载通过 UUID 自有目录中的 byte-identical copy + `_?=` 同步执行，finally 非递归删除 copy 与空目录，避免把 NSIS launcher 提前退出误当工作成功。
- Windows 故障检测检查失败退出码和全安装树 SHA 快照、个人导出、后续重试；ACL 保存并 finally 恢复，外部 marker 仅能证明该自有外部文件保留，不代替真实账本数据验证。
- Android UI 的 `@(Adb ...)[0]` 读取避免单行字符串被 `[0]` 取首字符；明确校验实际 API 与已安装 APK SHA。保存三种交易、手续费及唯一备注，重启要求笔数增加 3，并遍历账单找回三条备注；旋转截图要求宽度大于高度，键盘/返回与 settings 清理有记录。远端临时 XML/PNG 使用 UUID 前缀，只删除自己的两个文件。
- Android startup 校验 APK 与 schema-2 release/source manifest、当前 handwritten source，采样前后 pull 安装 APK 核对完整 SHA；每次 force-stop 后确认旧 PID 不在，用 fresh logcat stream、唯一 launch token、新 PID native_ready 和 AMS Fully drawn 双证据避免取旧日志。至少 20 个完整样本才计算 p95；配置 SHA 写入 raw，由外层验证实际固定配置文件。测量未读取 widget Stopwatch 作为正式性能。
- Android startup 逐次 finally 结束自己的 log reader 与本包测试进程，临时 pull copy 仅在自有 UUID 目录中创建和清理。未发现 `@(Invoke-Adb ...)[0]` 修正引入的确定行为缺陷。
- 本报告没有宣告任何实际安装、API、性能或视觉验收通过；Win10、Android 真机与真实短信边界保持不变。

## 审查时身份

| 文件 | SHA-256 |
|---|---|
| test-windows-installer.ps1 | 690b7362d1eb1e62cf1bad40d44c03a557a4a5496752b4b0dbe574bd0fa78885 |
| test-android-ui.ps1 | 2acca7afc38a19a0af2fb04a6560c3266f41fda27a3b0243a3056648e6924bd7 |
| measure-android-startup.ps1 | 5fba4ad96a0e8932495a5c2feed033e2ed280cc77bbe5a89e8642d756cb2c6ff |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 2 | warn |
| MEDIUM | 1 | info |
| LOW | 0 | note |

Verdict: WARNING — 2 HIGH 应在把 QA 结果计入最终三轮候选回归前解决；完整登记快照应补足实际故障恢复证据。
