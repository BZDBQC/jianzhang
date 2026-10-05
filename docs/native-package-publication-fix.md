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
