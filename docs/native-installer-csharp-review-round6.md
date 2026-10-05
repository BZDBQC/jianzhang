# Windows 安装事务 C# 第六轮独立审查

日期：2026-10-05。结论：**BLOCK / not clear：第五轮原子替换导致个人数据删除的 HIGH 已关闭；本轮发现一项内部派生路径超长导致恢复清理持续阻断的 HIGH。**

冻结 helper SHA-256：`5a487f1d687444acce19ccbd8b71d7c32b6d6879c1abdc8d541d3ce18699d68c`。
冻结 file-only tests SHA-256：`931c1cc23e05b883395d2905ecac64140b18cbd00994e8a93f3a33d8f2e27697`。

没有改动实现。仅在自有 `.qa` 目录编译与执行纯文件测试、制作诊断测试副本及调用无登记副作用的路径校验函数；没有执行实际安装器、卸载器、Registry、Main、整体 Preflight 或整体 Rollback。源码前后 SHA 相同。

## 已关闭：严格共享模式与同句柄删除

`LockFile`（helper:153）将共享模式收紧为 READ，禁止其他打开者直接写入、重命名或原子替换当前核对对象。`DeleteLockedFile`（helper:161）通过同一 SafeFileHandle 调用 FileDispositionInfo，没有按路径删除 fallback。候选内容、候选身份、卸载普通 payload、卸载身份、最后卸载入口、终态日志及已提交旧备份的核验后删除均使用该方式。

核对原生声明：FileDispositionInfo 为类值 4，其结构包含一个 BOOLEAN 字段；当前 `ref byte` 与 size=1 对应此合同。句柄请求 DELETE 权限，失败保留异常及原对象。[Microsoft FILE_DISPOSITION_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_disposition_info)、[SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)。API 可用性说明不代替 Windows 10 实测。

重新编译第五轮两份原始 reviewer 复现源码，未修改复现操作：候选回滚与卸载 payload 在已持锁状态尝试 File.Replace，均被拒绝，最新编辑器待保存字节保留。候选回滚成功且原安装恢复；卸载注入的外部保存异常保留当前托管文件与可重试状态。证据位于 `.qa/installer-csharp-round6-758556faa2a441369c330f8f6c3a27f2/candidate-fixture/evidence.json` 和同目录 `uninstall-fixture/evidence.json`。

旧侧个人文件合并先保留双方可读恢复副本，再用 DuplicateHandle 的同对象流写入与 Flush(true)，避免在严格锁下按路径替换。目录原子移动前明确释放旧文件句柄，移动后重新获取并核验；可信旧目录恢复仍允许个人文件最新编辑、增删，未退回历史个人内容 SHA 作为恢复阻断。

## [HIGH] 已接受的安装路径在内部退休目录派生后超长，终态恢复无法清理

File: `scripts/native-toolchain/installer-transaction.cs:122`、`:734`、`:749`、`:753`。

Issue: ValidateConfig 仅要求最终 payload 路径短于 248，未预算 `.__jianzhang_transaction/candidate-cleanup-<GUID>` 与身份文件等内部路径。合法且被校验接受的目标经过退休目录拼接后能够达到 260 字符以上。.NET Framework 的 File.Exists 对这些路径返回 false，DeleteCandidateIdentity 未锁定或删除身份文件；随后 Directory.Delete(..., false) 因目录非空失败。RolledBack 日志保留，但后续 CleanupCandidateTerminals 重复相同路径判断和失败，恢复无法自动完成。

这不是向 helper 传入已经超长的最终 payload：对实际失败 fixture 调用未修改的 ValidateConfig，返回 accepted=true，最长最终 payload 路径为 **177 字符**。退休后 owned manifest 和 token 分别为 **262 / 260 字符**。

### 确定复现与证据

1. 将冻结 helper/tests 编译为原 FileTests 入口（`INSTALLER_FILE_TESTS`，x86，warnaserror+）。执行 exe，fixture 参数为 `C:/Users/RM/Desktop/001/jianzhang/.qa/installer-csharp-round6-758556faa2a441369c330f8f6c3a27f2/file-fixture`。
2. 第一个 atomic identity 回滚用例失败：`Atomic rollback test did not reach locked deletion`。不是预期 File.Replace 断点失败；进入退休目录后两份 identity 仍存在，active journal 为 RolledBack，恢复的原安装和个人备份仍在。
3. 在该 fixture 的 client 上单独调用 ValidateConfig，接受目标；最终 payload 最大177。证据为该 fixture 的 `atomic-rollback-identity-.jianzhang-payload.json/path-budget-evidence.json`。

原失败日志：`.qa/installer-csharp-round6-758556faa2a441369c330f8f6c3a27f2/file-tests.log`。文件-only harness 的 Reject 接受先于目标边界的 IOException，之后断言正确阻止假通过。仅在 `.qa` 复制测试源并增加异常日志，完整诊断使用更长 fixture 时还得到明确 PathTooLongException，HRESULT `0x800700CE`；日志为同目录 `diagnostic-complete.log`。没有把这些失败归因为文件锁或系统扫描。

Fix: 在任何 Prepare/发布日志/目录移动前预算最终 payload、暂存、备份、候选退休身份和卸载 preparing/cleanup 日志等必要派生路径，超出当前运行库可可靠操作的边界时明确拒绝且不改变旧安装。保留已生成长路径恢复目录的安全重试/拒绝说明。增加纯路径预算拒绝回归，最终 payload 虽短于248但内部路径越界时不得进入事务。不能仅把测试 fixture 改短就声称该安装目标兼容问题已解决。

## 验证结果与限制

- `git diff -- '*.cs'` 执行；本轮文件仍为新增工作区源码，没有可用的 tracked 差异。按冻结源直接审查相关方法和测试。
- 生产及 INSTALLER_QA helper 以系统 .NET Framework csc 编译，x86、optimize、warnaserror+ 均通过。dotnet SDK 先前已确认缺失，build/format 无法运行；没有将不可运行检查记为通过。
- 同一冻结编译出的原 FileTests，在短自有根 `.qa/r6-7a88cf55/f` 完整 **145 项通过**，exit 0，registry_access=none；日志和身份记录为 `.qa/r6-7a88cf55/evidence.json`。这是有效的正常路径回归证据，也不能覆盖上述长内部路径缺陷。
- 两份第五轮原始 atomic 复现均确认替换被拒绝、最新待保存字节保留。
- FileBoundary 注入仅存在于 INSTALLER_FILE_TESTS；Step 注入仅存在于 INSTALLER_QA。生产 ValidateConfig 明确拒绝故障注入参数或 QA 根配置，没有加入生产可用的注入入口。
- owner 的最终两个145+12通过记录保留；其较早未归因日志替换/绑定失败历史不由本次成功倒推原因。本次另有确定路径越界失败，与这些未归因历史区分。

实际 NSIS 首装、升级、快捷方式及完整登记回滚、卸载、Windows 10 与用户机器兼容仍由 Root 完成。本报告不宣告完整 Windows 安装验收通过。

CRITICAL：0。HIGH：1（内部派生路径预算）。第五轮数据删除 HIGH：closed。结论：**BLOCK / not clear**。
