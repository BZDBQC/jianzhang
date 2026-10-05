# Windows 安装事务 C# 第二轮独立审查

日期：2026-10-05。结论：**BLOCK / not clear**。第一轮两项未解决 HIGH 已修复；交叉审查发现一项新的 HIGH：升级后清理会删除安装目录中的用户新增文件。完整安装、升级、卸载及登记失败验收尚未完成。

范围：`scripts/native-toolchain/installer-transaction.cs`、`installer-transaction-file-tests.cs`，复核 NSIS TransactionRunner 调用边界。只写本报告；没有改生产源码，没有运行 installer/uninstaller、Preflight、完整 Rollback 或 Registry API。继续采用 `dotnet-patterns` 指南。

源码 SHA-256：helper `2764773b790172ce54295d6152a1f9046423dd2dda26eea1d2d91e557e78e4f8`；file-only tests `b3d1b086ccfe2902f5ed740b02281eb4f35853351d8628e188968480cccc938b`。独立复编译前后身份一致，与 owner 的 evidence 相符。

## 本轮未解决发现

### [HIGH] 升级把用户新增文件移入旧程序备份，后续清理永久删除

File: `scripts/native-toolchain/installer-transaction.cs:163`、`:187`、`:291`、`:294`、`:399`、`:412`。

Issue: 已登记安装目录通过 Preflight 时，任意新增文件都被接受；oldFiles 收录整个目录，包括用户通过系统文件选择器保存在该目录的 JSON/CSV/XLSX 导出、notes.json 等。Commit 把整个旧目录移到 `marker/old`，再用仅包含候选 payload 的 stage 替换安装目录，没有把用户新增文件保留在新安装中。下一次安装的 Preflight 或卸载 CleanupCommitted 对 marker/old 递归删除，最终永久删除这些用户文件。NSIS 卸载仅删除候选清单的保护在此之前已失效，因为用户文件已经被升级移出了安装目录。

确定触发场景：正常安装简账 → 用户将完整账本 JSON 导出到该安装目录，或放入 `我的备份/2026-10.json` → 正常同目录升级。升级成功后该文件在安装目录不可见，只存于事务 old 目录 → 再次升级或卸载，清理旧备份后文件永久消失。SQLite 主账本位于安装目录之外，并不能保护这份用户明确保存的导出/备份文件。本项来自 packaging reviewer 的交叉发现，已独立核对完整源码路径；没有冒称执行过真实 installer/Registry。

Fix: 升级前区分安装器所有的 payload 与其他已有文件；未知文件应在新安装中完整保留，或在任何移动/删除旧目录之前明确拒绝升级并说明如何移动个人文件。若采用保留方案，应将非 payload 文件复制到新 staging 并核对字节/SHA，且后续卸载与旧备份清理不得删除它们；版本变更时应依赖旧安装的可信 payload 清单，不能把所有旧文件当作安装器所有。对没有旧清单的历史安装采用保守策略。补带中文/空格目录、JSON/CSV/XLSX、用户 notes 文件及备份子目录的升级→再次升级→卸载回归，逐次核对文件内容；备份只能作为回滚机制，不能代替最终保留用户文件。

## 原 HIGH 的复核

**初始 journal 发布窗口已修复。** `installer-transaction.cs:229` 在同卷 `marker.preparing-GUID` sibling 中写入初始 journal，通过 WriteThrough 与 `Flush(true)` 完成落盘，再 `Directory.Move` 发布 marker。创建、写入、flush 或发布前失败不会留下没有正式日志的 marker；发布前进程退出留下的未发布 sibling 不参与 Preflight 的活动 marker 判断，下一次可发布新事务。正式 marker 发布之后发生进程中断，初始 journal 已可供下一次恢复。纯文件测试覆盖创建/写入/flush/发布前失败、flush 前与发布前子进程退出，且验证旧程序清单未变、下一次日志可读取。

**清理失败丢失恢复日志已修复。** `installer-transaction.cs:402` 仅允许 `Committed`/`RolledBack` 终态清理；核对持久日志身份后先删除 payload/backup 子树，并保留正式 journal。子树文件仍被占用时，操作失败而日志仍可读取，释放锁后可继续。其余文件移除后，活动 marker 原子改名为严格命名的 `cleanup-GUID` sibling，再删除最后日志与空目录。日志删除前失败和删除后退出留下的状态均由 `CleanupTerminalDirectories` 幂等清理。终态 sibling 有未知文件、链接或身份不符时会停止并保留内容，不执行宽泛删除。

**RolledBack 重试避免重复恢复已删除备份。** `installer-transaction.cs:331` 直接走 `FinishRollbackCleanup`；不再校验已经清理的旧备份或执行登记/shortcut 恢复。文件 harness 只调用该纯文件清理方法，未调用整体 Rollback，因此测试不能进入 Registry 分支。

**NSIS 当前目录锁定修复保持有效。** `installer.nsi:149` 的统一 TransactionRunner 先 `SetOutPath "$PLUGINSDIR"`，检查错误后 ExecWait。commit、rollback、cleanup 均经过此宏，提取期间的 stage 当前目录不会被带入目录提交/删除操作。原纯文件锁定复现和官方依据保留在第一轮报告；最终 NSIS 安装仍须实际复测。

## 独立验证

- 本轮执行 `git diff -- '*.cs'`，新增未跟踪源码仍不在该 diff 中，随后直接审查当前目标文件及新方法。
- 独立使用 .NET Framework `csc.exe /warnaserror+` 编译 production 与 `INSTALLER_QA` helper，均通过。使用独立 `/main:JianzhangInstaller.FileTests` 编译 file-only harness，**30/30 通过，registry_access=none**。
- 独立证据：`.qa/installer-csharp-round2-ad704d52acde4fe4be9671e1c687554e/evidence.json`、`file-tests.log`。owner 证据 `.qa/packaging-unit-809a16ae0d70437998d7b7bbeec34fd8/evidence.json` 可另行核对，本结论没有把 owner 的 NSIS syntax smoke 记为真实安装通过。
- 新文件故障 hook 仅在 `INSTALLER_FILE_TESTS` 中编译；生产打包不定义该符号，安装 QA 只定义 `INSTALLER_QA`。生产仍拒绝非零 QA 参数与 qaRoot。未发现测试 hook 进入生产构建的路径。
- 复核了 canonical path/prefix 和 reparse-point 检查、终态 journal 身份校验、同卷 rename、文件占用时保留可恢复状态及错误传播。30 项测试验证失败恢复场景的旧程序清单保持不变，但不覆盖成功升级后用户新增文件的保留；该缺口对应上述新 HIGH。
- `dotnet --list-sdks` 仍为空。本机没有 .NET SDK，第一轮 `dotnet build` 与 `dotnet format --verify-no-changes` 已尝试并失败；本轮不重复不可执行的 SDK 检查，也不记为通过。该独立 helper 使用已验证的 .NET Framework csc 构建路径。

| 严重度 | 本轮未解决数量 |
|---|---:|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 0 |

第一轮的两项恢复缺陷解除；新增用户文件丢失缺陷修复并复审前继续阻断完整 installer QA。首装、同目录升级、卸载保留账本及个人文件、全部登记/shortcut 故障注入、真实进程中断后恢复、只读/占用及中文空格目录仍需 Root 的实际证据。Windows 10、安卓真机和真实短信维持约定未验证边界。
