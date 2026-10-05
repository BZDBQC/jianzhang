# 简账构建与安装合同第四轮独立审查

日期：2026-10-05（Asia/Shanghai）。结论：**APPROVE，当前 PowerShell/NSIS 审查范围内未发现 CRITICAL/HIGH 问题**。第三轮卸载失败后不能重试的 HIGH 已在源码合同层解决；实际完整安装/卸载仍待 Root QA。

范围：Windows package 与 NSIS 冻结版本，安装 helper 的 uninstall 调用合同，以及共享 source/path/environment 合同和 Windows startup measurement。检查 staged/worktree diff；目标为新增未跟踪文件，直接读取完整修改文件及相关调用点。只写本报告，没有改实现，没有运行真实/假 payload 安装器、卸载器、独立 Registry probe 或 Flutter tester。

## 已解决：卸载身份过早删除后的重试失败

安装/卸载共享同一个整个操作期间的 NSIS mutex。NSIS 卸载现在按以下顺序调用并检查 helper 的非零退出码：

1. `uninstall-preflight` 核对 owned 身份、版本、本卸载器 config 和现存文件；清理已提交安装恢复目录。
2. `uninstall-begin` 在同卷 preparing sibling 写完整恢复日志与卸载器副本、flush 并校验，再原子发布 uninstall 目录。
3. `uninstall-delete-payload` 在每个 owned 文件仍持有替换锁时核对 SHA 后删除。缺失文件只在可信 `Uninstalling`/`Completed` 记录存在时允许；现存修改文件、个人目录及身份改变继续拒绝。
4. 生成的 BUNDLE_DELETE 只删除空托管目录，随后 NSIS 删除本安装的快捷方式和登记；这些阶段失败时保留身份、恢复日志与原卸载器供重试。
5. `uninstall-finish` 验证普通 payload 已移除，再处理身份文件；身份删除中断仍可从记录恢复。先 flush `Completed`，最后删除 `Uninstall.exe`；最后入口删除失败也有完整记录可重试。此后仅非递归 RMDir，非空用户目录安全保留，不将残留小型恢复目录清理当成失败。该恢复目录由下一次实际安装预检清理。

关键位置：`scripts/package-windows-client.ps1:125`、`:130`；`clients/flutter/packaging/windows/installer.nsi:343`、`:382`、`:406`、`:411`、`:438`；`scripts/native-toolchain/installer-transaction.cs:356`、`:406`、`:420`、`:441`。

这套顺序不再依赖已删除的 token/owned 文件作为唯一重试依据。恢复记录绑定原清单、token 与卸载器 config，预检没有把无记录的缺失 payload 自动解释成正常卸载。恢复登记分支也保留相同卸载器和持久记录。helper 内部并发、日志实现及用户文件保护由 C# 专项独立审查负责，本报告只核对其与 NSIS 的合同。

## 构建、发布与测量合同复核

- 打包仍要求 schema-2 current source、版本、SDK 与完整 build payload；独占 snapshot 包含整个 Flutter payload、CRT、README，记录所有 input/helper/config SHA，NSIS 编译后复查，再同卷原子发布 setup。package 生成删除清单不再直接删除 payload 或两份身份文件，避免绕开 helper 的锁与重试协议。
- NSIS 安装仍使用 prepare → 同卷 stage 解压 → commit。提取失败和用户中止调用 rollback；统一 TransactionRunner 在所有命令前切离 staging 当前目录并检查失败。config SHA 作为固定实参传入，QA 注入只存在 QA 编译路径。
- build/source 合同中的根与祖先 junction/type/boundary guard、Android handwritten/generated inputs 分开哈希、官方 debug→release 插件重生成修复仍保留，未出现第三轮已解决问题的回退。
- Windows startup script 在运行前与测量后核对完整被测 payload，包括 AOT、engine、SQLite、plugins、CRT、assets；绑定真实 installer/manifest/source/buildPayload 身份。进程外 Stopwatch 从 fresh process launch 开始，到原生 post-ledger rendered-frame marker；逐次关闭自己的子进程，20–100 样本完成才写结果，计算 nearest-rank p95。
- 新增必填 `ConfigurationSha256` 有 64 位小写十六进制格式校验，写入 raw 结果。它由 QA 调用者传入，并非此脚本自动观察硬件配置；验收时须由外层检查实际配置文件 SHA 与该值一致。没有把尚未执行的 20 次测量记录为通过。

## 证据与身份

- 六份目标 PowerShell 当前 AST 解析均为 0 errors，最新测量脚本再次解析为 0 errors。
- 已读取 `.qa/packaging-unit-57a342f2f22849f7bc084b56de2b6b06/evidence.json`：时间 `2026-10-05T07:06:54.7592315Z`，exitCode 0，94 个纯文件测试、12 个打包检查，production/QA C# warnaserror 与 NSIS syntax 编译通过，`installerExecuted=false`、`registryAccess=none`。对应测试源码包含部分 payload 删除后重试、身份删除前后故障、三个文件占用后重试、晚期 shortcut 删除 surrogate、真实子进程退出边界及个人文件保留；surrogate 不等于真实 .lnk/登记阶段验收。
- 证据中的 package/NSIS/helper SHA 与当前冻结文件一致。没有重复执行已通过的 deterministic suite。

| 文件 | 审查时 SHA-256 |
|---|---|
| package-windows-client.ps1 | 9b704b8e8e355a21fba7c80ffda7d29e12e64c2b395619c000d141fa60e6b582 |
| installer.nsi | f7bde8557fd46accb49c2e07e1668a8a92c541aea774a6ebb4f7a29adb1b1fd9 |
| installer-transaction.cs（调用合同） | ef412c607c95029851656a9c62bfc89b83b4cbdc73fe10534da586dcf5e4ea14 |
| measure-windows-startup.ps1 | 5bed7142dc3e57851081c93d20a0dc5fd738f2d535df8c95b5298bbc5ff595c5 |

真实 Windows 首装/升级/卸载、占用/只读/中文空格目录、注册和快捷方式失败恢复、最终候选启动性能及 Android 多 API 安装运行仍需 Root 完成。Windows 10、安卓真机和真实短信继续为约定未验证边界。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: APPROVE — 第四轮冻结 PowerShell/NSIS 合同通过独立源码审查；真实安装、故障恢复与性能验收尚未由本报告宣告通过。
