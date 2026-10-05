# Windows 安装事务 C# 第七轮独立审查

日期：2026-10-05。结论：**CLEAR，零未解决 CRITICAL/HIGH。第六轮内部路径预算导致恢复清理阻断的问题已关闭。** 结论限定以下冻结身份及纯文件审查，不替代实际 NSIS 安装验收。

| 源文件 | SHA-256 |
|---|---|
| installer-transaction.cs | 2724a706822440cb7c8cda03e1d2a95edc7cd1fc4cb58940bfa15a7eadab4e81 |
| installer-transaction-file-tests.cs | 0a6450e1c2d7afee2d7ee8388500da60c3dc9f19a139bcdf68b138ecaa2c7330 |

## 路径预算修复复核

ValidateConfig（helper:123）在 Main 任何事务分派前执行纯检查：所有必要内容根、stage、old、failed、可读恢复副本版本根、candidate-cleanup 身份、事务及卸载 preparing/cleanup 日志、卸载入口备份、个人复制暂存、快捷方式备份和写入探针路径。文件必须短于260，目录短于248，同时检查文件父目录。

不仅检查 manifest：既有个人文件、空目录以及已存在事务/preparing/cleanup 树也纳入预算；legacy PathTooLongException 转为明确中文错误，要求选择默认或较短路径。检查没有写入、移动、删除或修改旧树。MoveNewAside 在移动候选前再次预算当前内容（helper:684），覆盖记账程序或用户在首次校验之后新增的晚期个人路径。无法安全保留的路径在移动前停止。

此次选择早期拒绝不支持的目标，并未启用系统长路径，也不声称超过当前预算的目标能够安装。此前已生成的超长恢复目录会明确停止并保留全部内容，未尝试强行删除或迁移。使用说明应提示选择默认或较短目录。

## 原始长路径精确复验

使用第六轮同一原始失败 fixture，最终 payload 最大 **177 字符**，退休身份路径 **262 / 260**。保持原 ValidateConfig 复现操作，仅将测试结果文件写到新 review 根，以免测试本身改变旧 fixture。

现实际结果：`validateConfigAccepted=false`，中文错误说明无法安全创建暂存和恢复目录；没有进入事务操作。将测试前已冻结的完整 **33 项目录、普通文件、隐藏身份文件、字节数和 SHA** 快照与测试前后实际树比较，全部相同，旧安装、个人文件和原 RolledBack marker 均保持原样。

证据：`.qa/r7-04763921/original-long-path-evidence.json`、`original-long-snapshot-evidence.json`。旧快照：`.qa/installer-csharp-round6-758556faa2a441369c330f8f6c3a27f2/pre-r7-long-fixture-snapshot.json`。仅调用 ValidateConfig，无 Registry、Main、Preflight、整体 Rollback 或实际安装器。

## 独立验证

- 生产和 INSTALLER_QA helper 使用系统 .NET Framework csc，x86、optimize、warnaserror+，分别编译通过。
- 当前冻结源与原始完整 file-only harness 在短自有 `.qa/r7-04763921/f` 下 **156 项通过**，exit 0，registry_access=none。包含此前严格句柄删除、原子替换拒绝、个人文件晚期编辑/冲突、崩溃重试和卸载 durable journal 回归，并增加旧/新超预算目标不变性、manifest/个人文件/空目录预算拒绝及最大接受边界。
- 最大接受边界用例实际让退休 owned manifest 达到 **259 字符**，执行完整纯文件升级、晚期个人文件回滚、卸载与 Completed 清理，成功且个人字节保留。验证了拒绝边界附近的正常目标，而非一律拒绝较长路径。
- `git diff -- '*.cs'` 已执行；新增工作区源码按实际冻结内容直接审查。dotnet SDK 先前已确认不可用，build/format 不记为通过。
- 源 SHA 编译、执行、结束复核一致。没有改实现、注册表、系统长路径设置或运行实际安装器/卸载器。FileBoundary/QA 故障注入的生产隔离保留。

编译/完整测试日志及身份：`.qa/r7-04763921/compile-file-evidence.json`、`file-tests.log`。第六轮超长 fixture 的确定失败证据保留；先前未归因 IO/绑定失败历史也不由本轮成功倒推原因。

CRITICAL：0。HIGH：0。审查结论：**CLEAR（限定上述冻结身份及审查范围）**。实际完整安装、升级、快捷方式/登记失败回滚、卸载以及约定三轮候选验收由 Root 继续执行。Windows 10、Android 真机及真实短信仍未验证。
