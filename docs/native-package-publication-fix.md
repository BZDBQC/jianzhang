Windows 安装包原子发布修复记录，尚未代表完整重新打包通过。

PowerShell 7.6.5 / .NET 10.0.11 下，将普通 `$null` 作为
`File.Replace(candidate, output, backup)` 的第三参数，会在当前重载绑定中
成为空字符串，抛出 `System.ArgumentException`，HResult `0x80070057`，
消息为 `The path is empty. (Parameter 'path')`。隔离真实文件复现保留了
旧目标完整字节及候选文件；同一对路径改用 `[NullString]::Value` 后成功。
证据：`.qa/replace-null-repro-6d738644c8c44f529ff5f93a589df0ff/evidence.json`。

生产修改只将该参数改为 `[NullString]::Value`，保留现有输出时的
`File.Replace` 和首次输出时的 `File.Move`。没有先删除旧 EXE，也没有修改
事务帮助程序、Flutter 或产物登记流程。
微软说明允许用实际 null 不生成替换备份；`NullString` 专用于向接受
字符串参数的方法传递 null。
[File.Replace 文档](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace?view=net-10.0)，
[NullString 文档](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.language.nullstring?view=powershellsdk-7.4.0)。

新增 `scripts/native-toolchain/test-package-publication.ps1` 从生产脚本 AST
提取并实际执行发布语句，只在全新的 `.qa` 子目录操作静态样本，不调用
NSIS、构建器、安装器或注册表。已有 `verify-packaging.ps1` 纳入该回归。

验证结果：

- 旧生产语句真实失败，见 `.qa/package-publication-before.log`。
- 修复后两轮各 10 项成功：首次发布、同一目标连续两次原子覆盖，
  锁定目标、锁定候选、只读目标、候选缺失的失败保旧，以及解除三类
  故障后的重试。失败均核对旧 EXE 与旧 sidecar manifest 字节不变，
  适用时也核对候选完整保留。成功未出现额外替换备份。
- 日志：`.qa/package-publication-after-1.log`、
  `.qa/package-publication-after-2.log`。最终冻结测试另连续两轮成功，日志
  `.qa/package-publication-final-1.log`、`.qa/package-publication-final-2.log`；
  对应完整 evidence 目录为
  `.qa/package-publication-ef644c66dcae43118632440ee0d258d8` 和
  `.qa/package-publication-3028f2b3d4484f9db34a4c67c1c7c564`。
- Windows PowerShell 5.1 直接运行被系统 AllSigned 策略拒绝，日志
  `.qa/package-publication-windows-powershell51.log`；未修改或绕过策略，
  不能将该运行环境记为通过。

这些局部测试不验证安装包与 sidecar 成对提交，也不代替完整打包或真实
安装验收；这里的 sidecar 断言只确认发布操作失败时没有改动原文件。
独立审查和完整候选重新打包由根代理安排。

原始整包失败对应根代理 tool chunk `8364f9`、session `29688`、exit 1。
该次未保存 Tee 日志，因此这里不引用不存在的整包日志文件；上述独立
文件 fixture 是可重复的主要故障证据。
# 1175 发布失败的后续诊断

此前 `$null` 重载问题的修复和 10 项纯文件回归没有证明真实安装包
可以覆盖发布。Root 的完整打包会话 `45498`（工具输出块 `d01332`）
随后在实际 `File.Replace` 操作中报告“无法删除要被替换的文件”；该错误
被记录为待解释的 1175 发布失败。原会话没有保存异常 HRESULT 或日志
文件，因此不能用不存在的日志或后续成功副本实验代替原始失败证据。

本轮没有重试或替换真实旧 Output。其 SHA-256 仍为
`0b9d97a963110aa461a30aa27fa025096964e92bad69f55576143ec9d879855f`，
保留候选包为
`19b951615be749e84e4b0834ab022d5c2d4bf57f5980ffdd2778dbb3e99cbe54`。
真实文件的普通共享探针、属性和权限检查，以及同目录、跨目录真实 PE
副本上的替换均通过。普通文件映射和两种映像映射下的副本替换也通过。
这些证据不证明原失败时没有占用，不足以把原因归于权限、映像映射、
安全软件或临时 I/O；没有修改系统设置，也没有运行注册表探针。

证据文件：

- `.qa/package-1175-file-metadata.json`、
  `.qa/package-1175-sharing-probes.json`、
  `.qa/package-1175-parent-metadata.json`。
- `.qa/package-1175-pe-copy-356f6fd8230c45ca990e230adab3b49d/evidence.json`。
- `.qa/package-1175-map-dd4047e1d1494632816df9c6dd67181e/evidence.json`。

最小源码变更仅给原子发布增加持久诊断。每次发布在本轮唯一
`installer-input-*` 目录中先保存 `artifact-publication-before.json`；
失败时保存 `artifact-publication-failure.json`，包含异常链的类型、
HRESULT、Win32 错误码、原始异常字符串和调用位置，以及候选 EXE、
旧 EXE、旧 manifest 的前后长度、属性、SHA-256。若占用导致哈希不可读，
诊断保留已经读到的属性并明确记录 `readError`。它不会声称这时已证明
文件字节未变。错误仍会抛出，不自动重试，不先删除旧包。

生产发布函数的 11 项纯文件回归连续两次通过，输出分别为：

- `.qa/package-publication-2e32d56bcfec4ff0a3a59655721e51a8/evidence.json`。
- `.qa/package-publication-e361245786da499b88c0d3f78e925a58/evidence.json`。

故障覆盖旧包占用、候选包占用、旧包只读、候选缺失及诊断目录不可用。
前四项核对持久诊断与实际抛出的最内层异常一致，包括错误码、原始
异常及调用位置；全部故障核对已有 EXE、已有 manifest 及适用的候选
字节保持不变。正常首次发布和覆盖发布保留原子 Move/Replace 行为。
此次验证不包含完整 NSIS 打包或真实安装；原 1175 覆盖发布仍待受控
复现及独立审查，不作为已经修复或安装验收通过。

[Microsoft 的 ReplaceFileW 文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew)
说明 1175 时两文件保留原名，而其他特定错误可能具有不同结果。
本轮没有因此引入任何重试，也没有改用忽略属性或 ACL 错误的选项。
