# Windows 安装事务 C# 独立审查

日期：2026-10-05。结论：**BLOCK / not clear**，两项 HIGH 恢复缺陷待修复。发现的另一项 HIGH 当前目录锁定缺陷已静态复核修复，真实安装验收仍待执行。

审查范围：`scripts/native-toolchain/installer-transaction.cs`、`installer-transaction-file-tests.cs`，以及 NSIS 调用边界。只写本报告，没有改生产代码，没有运行安装器、卸载器、注册表探测或 Registry API。使用 `dotnet-patterns` 指南。

源码身份：helper SHA-256 `5dfb0325c7e55b88fff4fbe097028a4787af0c0432baedf699e1ce985fcc95aa`；file-only tests SHA-256 `df2343ec1d886ad5861d35473e1529ec25bfd0c4c0d40b0b8423c2816028fb07`。

## 未解决发现

### [HIGH] 清理失败先删除恢复日志，下一次安装无法恢复

File: `scripts/native-toolchain/installer-transaction.cs:319`、`:359`、`:364`、`:214`。

Issue: 回滚成功后或已提交安装的下次清理直接调用 `Directory.Delete(marker, true)`。递归删除不是事务；日志可以先被删除，然后因 `stage`、`failed-*` 或 `old` 中某个文件仍被占用而抛异常。此时 marker 和剩余文件仍在，但 journal 已丢失。下次 Preflight 无条件 ReadJournal，必定报“事务目录缺少恢复日志”并停止，无法按已完成回滚/已提交状态继续。错误信息承诺保留恢复标记供重试，但当前实现没有保留可供恢复的日志。此缺陷不直接删除账本数据库，仍阻断安装故障恢复验收。

可执行纯文件复现：在自有 marker 中先创建 `journal.json`，再创建 `stage/locked.bin`；用 `File.Open(..., FileAccess.Read, FileShare.Read)` 持有 locked.bin，然后调用 `Directory.Delete(marker, true)`。实际结果为 IOException，`journalSurvives=false`、`lockedFileSurvives=true`、`markerSurvives=true`。没有调用 installer Main、Preflight、Rollback 或 Registry。

Evidence: `.qa/installer-cleanup-review-f569acc11b4b4ede91a9d57fb3c4cd51/evidence.json`。

Fix: 保留已 flush 的 `Committed`/`RolledBack` journal，先清理其他文件和子树；任一清理失败都保留日志供幂等重试，最后才移除日志和 marker。最后删除边界也须避免“日志已删、目录仍在”阻断下一次运行，例如先把已完成清理的 marker 原子重命名为受控清理残留目录，再移除该目录；不能无校验地删除所有无日志 marker。增加持有文件锁导致清理失败、释放后重试的回归，并核对完整旧 payload 和安装入口。

### [HIGH] 初始日志发布中断留下永久阻断的事务目录

File: `scripts/native-toolchain/installer-transaction.cs:182`、`:208`、`:210`、`:214`。

Issue: Prepare 先 `Directory.CreateDirectory(marker)`，再 Save 初始日志，并且 Save 返回后才置 `canRollback=true`。确定故障步骤：marker 创建成功 → 初次 FileStream 创建/Write/Flush 因磁盘耗尽、文件占用或进程中断失败 → marker 中没有正式 `journal.json`（可能只有 `.new`）。此阶段旧 payload 尚未移动，但错误处理不回滚；后续 Preflight 看到 marker 后 ReadJournal，必定因缺日志停止。即使磁盘空间或锁定问题已解除，重新安装也不会自行恢复。当前 QA Step 注入仅覆盖 Commit，无法覆盖这个初始窗口。

Fix: 在独立、同卷、受控临时事务目录中完整写入并 flush 初始 journal，再以原子目录重命名发布 marker；失败的未发布目录不能阻断下次安装。或者建立经过身份、路径、phase 和完整性校验的初始日志恢复协议，安全处理正式日志缺失而 `.new` 存在的场景。补首次日志创建/写入/flush 失败和发布前进程中断测试，确认下一次安装可继续且不触碰旧 payload 或账本。

## 本轮发现并已修复

### [HIGH → 修复待安装复测] NSIS 当前目录锁住 staging，目录提交必然失败

File: `clients/flutter/packaging/windows/installer.nsi:149`；原提取入口 `:283`；`scripts/native-toolchain/installer-transaction.cs:257`。

Issue: 原 NSIS 在 SetOutPath stage 后直接 ExecWait helper。SetOutPath 会调用 Win32 SetCurrentDirectory；NSIS 和 helper 的当前目录落在 staging 树内，因此 `Directory.Move(stage, install)` 被 Windows 当前目录锁拒绝，随后回滚的递归清理也受到同一锁限制。此问题影响首装和升级。

纯文件复现：将进程 CurrentDirectory 设置为自有空 stage，Directory.Move 抛 IOException；把 CurrentDirectory 改为 stage 外的 fixture 根目录后，同一个 Move 成功。Evidence: `.qa/installer-cwd-review-3619197b80ec4ac7bac227e9ecafac53/evidence.json`。

Root 已在统一 TransactionRunner 宏中加入 `SetOutPath "$PLUGINSDIR"` 与错误检查，再 ExecWait。本审查已复核该改动，commit、rollback、cleanup 均经过此宏。此修复解决源码调用边界，最终完整安装 QA 仍需确认。

依据：[NSIS 官方实现 EW_CREATEDIR](https://raw.githubusercontent.com/NSIS-Dev/nsis/master/Source/exehead/exec.c) 与 [Microsoft SetCurrentDirectory 文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setcurrentdirectory)。Microsoft 文档确认进程当前目录在运行期间被锁定，不能移动或删除。

## 验证与边界

- 执行 `git diff -- '*.cs'`，无输出；两份源码为新增未跟踪文件，随后直接审查完整目标源码。
- 执行 `dotnet --list-sdks`、`dotnet build`、`dotnet format --verify-no-changes`。本机只有 dotnet runtime，没有 .NET SDK，后两项因 `No .NET SDKs were found` 失败；不得记录为通过。
- 使用系统 .NET Framework `csc.exe` 对当前 helper 分别编译 production 和 `INSTALLER_QA`，两者 `/warnaserror+` 均通过。独立重新编译并执行 file-only entry point，结果 **9/9，registry_access=none**。Evidence: `.qa/installer-csharp-review-4d940663ffd54db29dfab2378f8e42a9/evidence.json` 与 `file-tests.log`。
- QA `Environment.Exit(99)`、故障抛异常和 steps.log 写入位于 `#if INSTALLER_QA`；production ValidateConfig 拒绝非零故障参数及 qaRoot，NSIS production 不解析 QA 开关。未发现生产伪故障注入路径。
- 已确认 SHA 检查、canonical path/prefix 检查、拒绝 reparse points、SafeFileHandle/COM 对象释放、旧 payload 全目录快照及备份、写入前记录 shortcut/registry touched 状态。错误传播有上下文，不会报告失败安装为成功。
- 9 个 file-only tests 不覆盖 Registry/shortcut 回滚、真实安装/升级/卸载、进程崩溃后恢复或 Windows 10。最终 full installer QA 由 Root 执行。Windows 10、安卓真机和真实短信继续为约定未验证范围。

| 严重度 | 未解决数量 |
|---|---:|
| CRITICAL | 0 |
| HIGH | 2 |
| MEDIUM | 0 |

本轮结论限定为安装事务源码审查；恢复缺陷修复并独立复审后，才能解除源码阻断，再开展完整安装验收。
