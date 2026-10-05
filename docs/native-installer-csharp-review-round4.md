# Windows 安装事务 C# 第四轮独立审查

日期：2026-10-05。结论：**BLOCK / not clear**。第三轮旧目录解锁后发生个人文件编辑而不能恢复的 HIGH 已修复；本轮复现一项新的 HIGH：候选目录已安装但事务尚未提交时发生的个人新增/修改，在失败回滚清理中被删除。

冻结源码身份：helper SHA-256 `ef412c607c95029851656a9c62bfc89b83b4cbdc73fe10534da586dcf5e4ea14`；file-only tests `f51c3fd64873bea00aa695b1c50f57bef0da54f0c5c5b6599da72bafb3e12675`。审查前后身份一致。没有改实现；只写报告和自有 `.qa` 文件测试，未运行 installer/uninstaller、Registry、Preflight、完整 Commit/Rollback。

## [HIGH] PayloadInstalled 后的个人新增/修改被回滚清理删除

File: `scripts/native-toolchain/installer-transaction.cs:592`、`:604`、`:569`、`:653`。

Issue: CommitPayload 已把候选 stage 移到原安装目录后，后续登记或快捷方式仍可能失败。此期间外部编辑器/文件导出可以在原路径更新已有个人 notes 文件或保存新的 JSON 备份。失败 RestorePayload 用 MoveNewAside 把整个候选目录（连同这些最新个人内容）移入 marker/failed-GUID，并还原 old；随后 RolledBack 的 FinishRollbackCleanup 对所有子树递归删除，把 failed-GUID 中最新编辑和新备份永久删除。旧安装恢复成功但恢复的是旧个人副本，最新用户内容丢失。新的旧目录恢复身份校验只处理 old 中的变化，没有处理 PayloadInstalled 后候选目录中的变化。

确定复现：以原 file-only SeedOwned/BeginUpgrade 创建受控安装，再调用原 RunPayload 到 `PayloadInstalled`；追加 `data/notes.json` 并新建 `我的新备份.json`；模拟后续登记失败的文件路径，直接调用原 RestorePayload，设置 RolledBack 并 Save，再调用原 FinishRollbackCleanup。没有额外测试 hook、没有修改生产逻辑、没有进入登记/shortcut 分支。

实际结果：`originalInstallationRestored=true`；清理前最新备份存在于恢复目录，`latestExistsBeforeCleanup=true`；清理后 `latestNotesEditSurvives=false`、`newUserBackupSurvives=false`、`recoveryDirectorySurvives=false`。证据：`.qa/installer-late-personal-review-26687d33d475458982ad5450c91fc448/fixture/evidence.json`。

可再次运行该独立纯文件复现，参数必须是新的自有目录，例如：

```powershell
& '.qa/installer-late-personal-review-26687d33d475458982ad5450c91fc448/late-personal-review.exe' '.qa/installer-late-personal-review-26687d33d475458982ad5450c91fc448/repro-again'
```

该 exe 的源码为同目录 `late-personal-review.cs`，与本轮冻结 helper/tests 共同编译，入口 `JianzhangInstaller.LatePersonalReview`。不执行 installer Main，不访问 Registry；上述目标目录尚未创建，重复复现应换用新的目录名。

Fix: 回滚前核对候选目录真实 owned 清单，识别清单外及个人路径中自初始 preservedFiles 快照发生的新增/修改，并安全保留。旧目录与候选目录均有变化时保存双方内容，不能静默选择一方覆盖另一方。可以将可安全恢复的最新个人内容移回原安装，冲突时保存独立恢复副本并说明位置；不能直接递归清理包含未保存用户内容的 failed-GUID。加入 PayloadInstalled 后编辑/新增/同路径双侧修改、登记失败回滚、进程中断后再次恢复的文件回归，核对最新内容及双方冲突副本。

## 上轮修复及卸载协议复核

- RestorePayload 现在固定核对旧 owned 清单/token 哈希及无链接的目录身份，再原子恢复完整旧目录，不再强制个人内容匹配 Prepare 时的旧 SHA。原 harness 覆盖解锁窗口内 edit/add/delete、重锁失败、目录移动锁定失败，以及再次 ReadJournal 后恢复；最新个人内容保留。第三轮 HIGH 解除。
- BeginUninstall 在独立 sibling 完整写入、flush 卸载恢复日志及实际 Uninstall.exe 副本，再发布 `Uninstalling` marker。初始发布前中断不形成无日志活动 marker。
- 活动卸载 record 绑定 config，内嵌 owned 清单/token 校验身份，托管文件缺失仅在可信卸载已开始时允许。托管路径出现修改或目录时停止并保留内容；没有 record 的缺失托管文件拒绝开始卸载。
- DeleteUninstallPayload 在每个文件持锁期间重新核对 SHA/长度再删除，部分失败可从持久 record 重试。FinishUninstall 保留入口直到普通 payload 全部移除；逐个删除身份文件后持久记录 `Completed`，再删除最后 Uninstall.exe。身份删除中断/锁定、最终入口失败均有原入口和可信 record 供重试；成功留下的小恢复记录由下一次实际安装预检清理。
- 原 initial journal/终态 journal/cleanup sibling 的恢复修复仍保持。生产与安装 QA 不定义 INSTALLER_FILE_TESTS，纯文件故障注入未进入生产。NSIS 实际入口/登记失败的跨模块顺序由独立 packaging review 核对；本报告不替代真实卸载验收。

## 独立验证与限制

本轮先执行 `git diff -- '*.cs'`，新增未跟踪文件仍不在该 diff 中，随后直接审查目标源。独立使用系统 .NET Framework csc 对 production 和 INSTALLER_QA 编译，`/warnaserror+` 均通过；重新编译并执行原未修改 file-only harness，**94/94 通过，registry_access=none**。这些既有测试没有覆盖上述候选目录晚期个人变化路径。

独立证据：`.qa/installer-csharp-round4-61be1ee6e93c4b5caa30119d3e7afb89/evidence.json`、`file-tests.log`。owner 的 94 file-only/12 packaging checks 另见 `.qa/packaging-unit-57a342f2f22849f7bc084b56de2b6b06/evidence.json`。本机无 .NET SDK，第一轮 dotnet build/format 已尝试失败，当前没有把这些 SDK 检查记为通过。

| 严重度 | 本轮未解决数量 |
|---|---:|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 0 |

候选目录晚期个人数据保留修复并复审前继续阻断源码通过。完整安装、升级、卸载及登记故障由 Root 后续实际验收；Windows 10、安卓真机、真实短信仍为约定未验证边界。
