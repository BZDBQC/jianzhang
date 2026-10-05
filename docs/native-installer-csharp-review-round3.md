# Windows 安装事务 C# 第三轮独立审查

日期：2026-10-05。结论：**BLOCK / not clear**。第二轮“成功升级后删除用户新增文件”缺陷已修复；本轮复现一项新的 HIGH：移动目录前释放文件锁的窗口内发生个人文件编辑后，失败升级不能自动恢复原安装。

审查范围：`scripts/native-toolchain/installer-transaction.cs`、`installer-transaction-file-tests.cs`。生产源码保持不变；只写本报告和自有 `.qa` 文件证据，没有运行完整 installer/uninstaller、Main、Preflight、整体 Commit/Rollback 或 Registry API。NSIS/PowerShell 的跨模块问题由 packaging reviewer 单独报告。

冻结源码 SHA-256：helper `b09690ef5d63492528fe284b79dd143623354b4c726bc89d457784f504143d4f`；file-only tests `6115eb2819d99dca5efe3eea149c4b3e35b3b1946312af19352b17244135f5d5`。

## [HIGH] 解锁窗口内的个人文件编辑使失败升级永久停在恢复状态

File: `scripts/native-toolchain/installer-transaction.cs:422`、`:423`、`:425`、`:443`；恢复入口 `:164`。

Issue: CommitPayload 在复制并校验个人文件后，释放全部旧文件句柄，然后把旧目录移动到 marker/old，再重锁和核对 Prepare 时的完整 oldFiles 清单。若用户或编辑器恰好在释放句柄的窗口内保存个人 notes/导出文件，目录移动成功，但新旧 SHA 不同，因此 CheckFiles 抛异常。此时 phase 为 MovingOld，原安装目录已经不存在。自动 Rollback 的第一步仍执行相同的 `CheckFiles(old, journal.oldFiles, true)`，再次拒绝同一合法个人文件变化；下次 Preflight 同样不能完成恢复。即使编辑器已关闭、磁盘和权限都正常，也不能继续安装，旧应用留在恢复目录。新编辑仍在备份中，未发生直接数据删除，但失败升级没有恢复旧安装，违背故障恢复要求。

确定文件复现：使用当前 file-only SeedOwned/BeginUpgrade 创建自有旧程序和个人 `data/notes.json`，在 CommitPayload 的原锁释放之后、原 Directory.Move 之前追加一段用户编辑，再执行原共享文件逻辑。返回 InvalidDataException，检查结果为 `phase=MovingOld`、`installExists=false`、`oldBackupExists=true`、`journalExists=true`。直接调用整体 Rollback 之前实际执行的同一个纯文件 CheckFiles 检查，也返回相同的 InvalidDataException。该检查未进入任何 Registry/shortcut 恢复路径。

Evidence: `.qa/installer-csharp-race-review/fixture/evidence.json`。为确定注入窗口，仅在 `.qa/installer-csharp-race-review/instrumented-helper.cs` 临时副本的原 `locks.Dispose/Clear` 后插入 FileBoundary 测试 hook；没有改变 CommitPayload 的原文件逻辑，没有改生产源码。此为确定的文件故障注入证据，不冒称真实 NSIS 安装或外部编辑器并发验收。

Fix: 失败恢复应保留并还原可信旧安装中的个人内容变化，而不是要求个人文件始终匹配升级准备时的 SHA。可在重新锁定旧备份后，将合法的个人文件变化持久记录为新的恢复快照，或在回滚时使用已验证的旧 payload 身份区分托管文件与个人内容，仅对可信托管入口作必要校验，并把包含最新个人内容的完整旧目录安全移回。继续拒绝路径/链接与身份不符，不能通过删除变化文件或用 staging 中的旧副本覆盖用户新编辑解决。补解锁窗口编辑个人文件、重锁失败、再次启动安装恢复的回归，核对原程序可用及最新编辑保留。

## 已确认修复与正向证据

- `.jianzhang-payload.json` 记录真实候选 payload 和实际 Uninstall.exe 的 SHA/长度；token 绑定清单 SHA。读取拒绝缺失/损坏身份、非规范路径、重复大小写路径、根路径逃逸和 reparse points。生产安装清单与个人文件清单分离。
- 旧清单外及已改写的旧托管文件被当作个人文件；复制到 stage 后核对字节/SHA，且不会重新列入新 owned 清单。目录与空目录也保留。新 payload 路径冲突或类型冲突在移动旧目录前拒绝，不覆盖用户内容；缺少旧可信清单时停止并给出安全迁移步骤。
- 当前纯文件成功路径实际执行两次同版升级及每次旧备份清理，保留中文/空格目录、JSON/CSV/XLSX、notes 和空目录。个人 notes 在两次升级之间的修改也保留；改写的旧废弃托管文件成为个人内容并保留。模拟卸载仅按验证的托管文件清单删除，个人文件仍完整。它不等于真实 NSIS 卸载验收。
- CheckUninstallOwnership 检查本版 config 与 owned 清单，拒绝仍存在的托管路径中的用户修改/目录，允许已被成功删除的程序文件缺失以支持卸载重试。跨 NSIS 的身份删除顺序由另一个 reviewer 报告，不在这里重复。
- 第一轮初始 journal 原子发布、终态 journal 保留与 cleanup sibling 幂等清理、RolledBack 不重复恢复备份的修复仍保持。

## 独立验证与边界

本轮 `git diff -- '*.cs'` 仍不显示新增未跟踪文件，随后直接审查冻结目标源。独立重新编译 production、INSTALLER_QA 两种 helper，`csc.exe /warnaserror+` 均通过；重新编译并运行原未修改 file-only harness，**56/56 通过，registry_access=none**。源码身份与 owner 证据匹配。

独立证据：`.qa/installer-csharp-round3-532c9b23a47f4efe87154658ed8f02d4/evidence.json`、`file-tests.log`。owner 的 12 项 packaging/NSIS syntax 检查另见 `.qa/packaging-unit-3e106345254f4f00b070bab7bf958c9a/evidence.json`；本报告不把语法编译或文件模拟计入真实安装通过。

本机没有 .NET SDK；第一轮 dotnet build/format 已尝试且因缺 SDK 失败，后续沿用系统 .NET Framework csc 构建证据，不冒称 SDK 检查通过。QA/FileTests hook 仍被编译符号隔离，生产构建不包含文件故障注入入口。

| 严重度 | 本轮未解决数量 |
|---|---:|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 0 |

修复上述自动恢复缺陷并独立复审后才能解除 helper 源码阻断；完整首装/升级/卸载、登记/shortcut 回滚及真实进程中断仍由 Root 执行。Windows 10、安卓真机及真实短信继续为约定未验证范围。
