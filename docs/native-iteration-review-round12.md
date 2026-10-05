# 原生迭代独立审查，第十二轮

结论：**生产启动隔离四文件 APPROVE；Windows 冷启动 QA 脚本暂时 BLOCKED**。真实 EXE 冷启动尚未执行。独立审查发现 readiness 拒绝条件在其明确支持的 Int32 分支失效，需要最小括号修复、补实际表达式负测并重新冻结。

## 冻结范围

以 `.qa/windows-startup-isolation-freeze.json` 为输入，独立测试前后与报告落盘前七项 SHA 均匹配；没有修改作者生产源码、测试或脚本。

| 文件 | SHA-256 |
| --- | --- |
| `clients/flutter/lib/main.dart` | `b5b18ea438a360c5ff7883e9c5a8ed324c8b18851f4875f306fdc6e0fb5a4b27` |
| `clients/flutter/lib/app/controller.dart` | `d820e4f9dc9093cc4b7bbf064bb53840fa43848bd7be0183de37d6159d13a42c` |
| `clients/flutter/lib/app/startup_configuration.dart` | `88c4de444903ba335693f61309bc444eced9531ac71fce16f4316a3d99b68cd5` |
| `clients/flutter/test/app/startup_configuration_test.dart` | `84e4b5cd7603552f37285a09f33a99f0319da1a3e82c35643fe89408432f7cd0` |
| `scripts/native-toolchain/measure-windows-startup.ps1` | `65fb5cac12fc9ea0c0256452f77cc9a52cf5f9e1606d02f96fa75c7dbaea0483` |
| `tests/native-qa/windows-startup-isolation-fixtures.ps1` | `8730e818f4a99cc2f6d9594ad3ef0ede1378e56d6ff45273d40b81642164ded5` |
| `docs/native-startup-isolation.md` | `1ae3d3f139b7f2b2c9b72c2608642821dafbb71c8cdaa4fb2fa199cae39f517d` |

## 生产启动隔离：APPROVE

读取了 staged/unstaged diff、完整新配置、main/provider 变更和仓储 connect 路径，并核对 Windows runner 参数传递与既有渲染就绪链路。

`StartupConfiguration.resolve` 在 `runApp`、ProviderScope 和数据库 provider 创建前运行。普通无参或无 QA 前缀参数保持默认路径；显式 QA 参数只允许 Windows、单个完整参数及既定 `.qa/startup-<GUID>/sample-<两位数>/jianzhang.sqlite` 结构。非法、重复、未知 QA 参数抛错，不会启动默认账本。数据库与当前 EXE 必须共用 `.qa` 根；相对、UNC/device、点路径和分隔符别名拒绝。

EXE、样本目录、marker 的每级祖先通过 `GetFileAttributesW` 检查缺失、文件类型及 reparse bit。签名为 DWORD 返回值与 UTF-16 指针入参；每次 `toNativeUtf16` 分配均由 finally 中的 `calloc.free` 释放，没有新建系统 handle。样本初始只能有 marker，marker 大小及身份字段逐项验证。配置成功后非空路径经 provider 一直传到 `LedgerRepository.open(path:)` 与 SQLite `File(path)`；没有错误捕获后回退 KnownFolders 的分支。普通模式的 null 路径才使用既有默认位置。

独立执行 **10/10** 目标测试通过，含真实自有 junction 拒绝、中文空格路径、marker 错误、既存 DB/WAL/备份拒绝和 provider 在指定自有路径创建零笔 guest 数据库。默认路径测试仅读取配置和 initial provider 的 null 值，没有打开真实默认数据库。独立 analyzer 无问题。

- `.qa/flutter-startup-isolation-independent-r12.log`
- `.qa/flutter-startup-isolation-independent-analyze-r12.log`

该批准支持重建两个平台，不代表新发布包或真实冷启动已经验收。

## Windows QA 脚本：一项待修复问题

### [HIGH] Int32 分支可抵消缺失数据库标记或错误 renderer 的拒绝条件

文件：`scripts/native-toolchain/measure-windows-startup.ps1:143`。

当前表达式：

```powershell
if(!$observedFixture -or !$ready -or $ready.rendererFirstFrame -ne $true -or $ready.readyMs -isnot [long] -and $ready.readyMs -isnot [int] -or $ready.readyMs -lt 0)
```

PowerShell 的这组逻辑运算从左向右结合；整数类型子句缺少括号。当 `readyMs=[int]12` 时，末段 `-and $ready.readyMs -isnot [int]` 为 false，会将前面缺失 selection 或错误 renderer 的 true 抵消。独立提取原文件真实 IfStatement AST 条件，以下两个应拒绝场景均实际返回 false：

- `$observedFixture=$null`，renderer 为 true，readyMs 为 Int32 12。
- 已有 selection，renderer 为 false，readyMs 为 Int32 12。

最小修复：把整数类型判断分组为 `($ready.readyMs -isnot [long] -and $ready.readyMs -isnot [int])`，并在纯 fixture 中执行实际 AST 条件，覆盖 Int32/Int64 的缺失 selection、false renderer 与有效 readiness。

**实际影响边界：**当前 PowerShell 7.6.5 的真实 `ConvertFrom-Json` 将小整数解析为 `System.Int64`；独立对照证实该真实 JSON 通道的两个错误场景目前能拒绝。此次发现是源代码明确接受的 Int32 分支缺陷，并非已经发生的真实 EXE 假通过。它仍违反该条件的完整拒绝合同，且形成对解析器数值类型的隐藏依赖；按 root 要求，在修复并重新独审前不执行实际冷启动。

冻结复现：`.qa/startup-readiness-red-r12-26158a5507904708a92015a63fee73bc/evidence.json`，SHA-256 `8eb0b553380b09562fb30b127fa6b32f77afd74c8e4d049d2171bfbfb33b8c60`。记录原 AST 表达式、原脚本 SHA、PS/.NET 版本、八个类型明确的场景；**2 个拒绝条件失败，6 个对照符合预期**。没有执行生产 EXE。

复现日志：`.qa/windows-startup-readiness-red-independent-r12.log`。自有额外检查 `.qa/windows-startup-review-r12.ps1` 在发现该负例时停止，因此其尚未执行完的计时/二十样本附加 fixture 不能计为通过。

## 其他独立证据与保留合同

冻结 PS helper 的独立纯 fixture **9/9 组**通过：新样本独立且 DB 尚不存在、重复 sample 拒绝、runId/sample 边界、EXE 与 `.qa` 归属、真实自有 junction 拒绝，以及实际 `mode=ro` SQLite 的完整性/guest/sequence/schema/零笔验证。非空、错误工作空间、sequence、schema、损坏和缺失 DB 均拒绝；正常只读检查前后 DB 字节一致。负向 Python traceback 为预期拒绝证据。

- `.qa/windows-startup-isolation-independent-fixtures-r12.log`
- `.qa/startup-isolation-pure-79655780287d4f3db636a0b2b9a11675/evidence.json`

该 fixture 只提取 helper 函数，没有执行测量脚本顶层、真实客户端或安装器。Python reader 连接仅存在于这个短生命周期子进程，退出即释放；`with sqlite3.connect` 本身是事务上下文，并不等价于显式 `close`。

静态核对确认完整 payload/source/EXE/manifest 的原前后 guard 保留，样本建立与参数组装在计时前，Stopwatch 启动后才创建真实子进程，收到就绪后的 elapsed 在关闭/SQL 查询前取值。Count 默认 20、范围 20..100；p95 为 `ceil(Count*0.95)-1`。每笔采样完成关闭后才验证其显式 DB。失败仅清理当前创建的子进程，不更改用户、KnownFolders、注册表或默认账本。静态核对不作为实际二十样本性能证明。

## 验证边界

本轮没有启动实际 EXE、运行 ADB、安装/卸载软件或修改系统设置。未测真实二十样本冷启动、当前候选全套回归及性能阈值；Windows 10、Android 真机、真实短信仍未验收。已知 Win32 1175 安装包原子发布故障不属于本轮增量，未由本轮解决。连续三轮完整干净回归不能由这些目标测试累计。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 1 | pending |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **生产四文件 APPROVE；Windows 冷启动 QA BLOCKED**，等待类型判断最小分组修复和重新冻结后的独立负测。禁止将现有静态/fixture 通过当作冷启动验收。
