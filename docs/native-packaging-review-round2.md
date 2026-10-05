# 简账构建、打包与启动证据第二轮独立审查

日期：2026-10-05（Asia/Shanghai）。结论：**WARNING，3 项 HIGH 待修复**。本报告只审 PowerShell/NSIS 和启动测量合同；安装事务 helper 本体及其用户文件保护由独立 C# 审查负责。

范围：`build-windows.ps1`、`build-android.ps1`、`source-contract.ps1`、`environment-scope.ps1`、`package-windows-client.ps1`、`installer.nsi`、`measure-windows-startup.ps1`，并读取 Flutter 原生 readiness 调用、SDK 安装与模拟器环境恢复的周边代码。先检查 staged/worktree diff；目标脚本和客户端目前是新增未跟踪文件，因此直接读取完整目标文件。没有修改生产代码，没有运行安装器、卸载器、注册表探测或 Flutter tester。

## [HIGH] 被测 Windows 程序只核对 runner，允许旧 AOT 程序生成当前候选的性能证据

File: `scripts/native-toolchain/measure-windows-startup.ps1:21`、`:22`、`:75`。

Issue: 测量前只检查当前 source manifest 和被测 `jianzhang.exe` 的 SHA；测量后仍只检查 exe。Flutter 的实际程序在 `data/app.so`，引擎、插件、SQLite 与 assets 也来自 exe 所在目录。保留同一 native runner，换入旧 `app.so` 或其他库，脚本仍接受这个目录，并把调用者提供的当前 BuildId 写入 release 性能结果。这使启动指标不能证明最终完整候选的行为。

纯文件复现：构造包含 exe 与 `data/app.so` 的自有 fixture，记录完整 payload，随后仅修改 `app.so`。脚本使用的 exe 判定仍为 true，而完整 payload SHA 已变化；没有执行假 exe，也没有产生真实性能结果。

Evidence: `.qa/packaging-review-round2-0b6f1beb9a28407cafa93b4cea673019/evidence.json` 的 `startup`。

Fix: 根据 schema-2 build/package manifest 验证被测目录中完整执行 payload 的路径、大小和 SHA，包含 AOT、engine、plugins、SQLite、assets、CRT；把来源/manifest/payload 身份记录到结果，测量结束后再次核对。允许安装器自己的 token/uninstaller 或用户附加文件时，仍须逐项验证所有记录 payload，并拒绝缺失、改变或外部链接的执行输入。实际 20 次完整样本仍需运行。

## [HIGH] 构建清理没有拒绝 build-client 根和祖先 junction，路径守卫可穿透到其他目录

File: `scripts/native-toolchain/build-windows.ps1:27`、`:37`、`:40`、`:42`；`scripts/native-toolchain/build-android.ps1:33`、`:42`、`:46`、`:48`。

Issue: 清理前只验证枚举出的子目录 FullName 字面前缀、子目录自身及其后代 reparse points，没有先验证 `buildClient` 根或 `.tools` 等祖先。若 build-client 根本身为 junction，目标中的普通 `lib` 目录仍具有形如 `.../build-client/lib` 的枚举路径，自身没有 ReparsePoint，现有守卫接受；随后的递归 Remove-Item 会通过根 junction 操作真实目标。源码快照对根 reparse point 的检查在这些删除之后，不能阻止删除。

纯文件复现：在自有 `.qa` fixture 中建立 build-client junction 指向另一个自有目录，里面创建普通 `lib/valuable.txt`；现有两类清理条件均接受。证据记录 `rootIsJunction=true`、`childCleanupGuardAccepts=true`。没有执行递归删除，只非递归 unlink 自己创建的 junction，目标文件仍保留。

Evidence: 同一 `evidence.json` 的 `cleanup`。

Fix: 在 New-Item、枚举、unlink 和任何清理之前，沿 workspace → `.tools` → build-client 逐层拒绝 reparse points，检查已有节点为目录，并确认规范化绝对路径位于所属工作区。递归清理前继续保留后代检查。增加根 junction 和祖先 junction 的纯文件拒绝回归，确认外部目标完全不变。

## [HIGH] Android 快照带入测试生成的插件注册器，正式 APK 构建确定失败

File: `scripts/native-toolchain/source-contract.ps1:25`、`:26`；`scripts/native-toolchain/build-android.ps1:50`、`:67`；`clients/flutter/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java:29`。

Issue: Android 快照把生成的 `GeneratedPluginRegistrant.java` 当成源输入复制，当前文件含 `dev.flutter.plugins.integration_test.IntegrationTestPlugin`。正式 release 的 Gradle 依赖没有该测试插件，`--no-pub` 构建没有把这个注册器与正式构建的插件依赖合同保持一致。Root 的真实构建在 `:app:compileReleaseJavaWithJavac` 因该类不存在失败，不能生成交付 APK。

Evidence: `.tools/android-release-build-proxy.log:16`、`:24`、`:26`，该次 `assembleRelease` 171.7 秒后 exit 1。该日志由 Root 的实际构建产生；本审查没有并行重跑构建。

Fix: 使正式快照的插件元数据、生成注册器和 Gradle release 依赖由同一正确生成阶段产生，排除测试生成物影响正式编译。不要通过把 integration_test 编入正式运行时来掩盖错误。先覆盖“刚运行过原生测试再 release”的回归，再实际构建并验证 APK 签名、包信息和 16 KB 属性。

## 上轮修复的复核结果

- P1：打包读取 schema-2 build manifest，匹配 pubspec 版本与实际 Flutter framework/engine，完整 source/payload SHA 均核对；在独占目录复制稳定 payload、安装源码、文档和 helper，单独记录 CRT 来源、版本与 SHA，NSIS 返回后复核所有输入，最后同卷原子发布 setup。静态合同已消除上轮“仅存在性检查接受旧 bundle”的缺陷。
- P2/P3：NSIS 不再直接覆盖旧安装，解压到同卷 stage 后调用事务 helper；prepare/commit/rollback 均检查退出码。统一 TransactionRunner 在调用前 SetOutPath 到 PLUGINSDIR，并检查失败，解除 staging 当前目录锁。helper 的注册/快捷方式恢复、日志故障恢复及附加用户文件保护另见 C# 独立报告，不能由本报告代替通过。
- P4：构建、打包、Flutter 安装与 emulator 启动均在 finally 恢复进程环境；原先缺失的变量通过 Remove-Item Env 删除，而非留下空值。安装密钥只置于 Android 构建进程环境并恢复，没有日志输出密钥。
- P5：Assert-FlutterVersion 核对实际 machine 输出的 framework version/revision/channel/Dart；SDK 安装器在不一致时验证 staging 后替换并复核。已安装入口存在不再等于请求 SDK 正确。
- Windows 默认 current-user LOCALAPPDATA Programs 安装；运行库复制到完整 packaging snapshot。NSIS 卸载生成清单只删除 payload、token、uninstaller 和空目录，账本支持目录不在清单中；升级 helper 对附加用户文件的风险已交 C# 审查 owner。
- Android 构建发布前检查旧证书 SHA、包名/版本/minSDK、16 KB ZIP 与 64 位 ELF alignment，任一失败抛异常。当前正式构建失败，因此没有把这些条件记为已执行通过。

## 验证与身份

六份目标 PowerShell AST 解析为 0 errors，仅说明语法。纯文件 fixture 复现两项合同缺口，未执行假程序、安装器、注册表操作或递归删除。Windows 真实启动样本、安装/升级/卸载、安卓各 API 的实际安装运行仍由 Root 验收；Windows 10、安卓真机和真实短信保持约定验证边界。

| 文件 | 审查时 SHA-256 |
|---|---|
| build-windows.ps1 | c8f9ef8b84de9b9db73feaf9fb9e1999679e06fb75105b79ea94fc3e8ecb8862 |
| build-android.ps1 | a428a8ab46845d786d1f12ae0abc07e0d2ba0a146191f15ea4f1f91a76b04e94 |
| source-contract.ps1 | ca53bd0c9c656b7e47c58442ec90dcc18bb21104515e9b4e8f656a532a7707ea |
| environment-scope.ps1 | 63a5c157c8f18150817ee5270b84c3742f3a27c9569050bbe0bc33a696cb4db2 |
| package-windows-client.ps1 | ae2ddccd60cde5b0ba7ae170af03867bc83e98ae52ba898ba7b822b514c95f49 |
| measure-windows-startup.ps1 | 53521eccf25aef8605c2efcc96ae6dfbd74f6b97928d6fa98b3200fe826f5661 |
| installer.nsi | be737e7c34d43fdb4faf52ecbd89d95f9a0403673419a419cb1b2c268efbc6d9 |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 3 | warn |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: WARNING — 3 HIGH 问题应在最终构建及性能验收前解决；本报告不把编译或静态审查替代真实安装与平台验收。
