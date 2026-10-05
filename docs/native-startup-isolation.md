# Windows 原生冷启动测试的数据隔离

## 原因与边界

Windows 的 `path_provider_windows` 通过 `SHGetKnownFolderPath` 查询当前用户的 RoamingAppData。仅为进程设置 `APPDATA`、`LOCALAPPDATA` 不能改变该路径。默认数据库的打开过程会更新当前工作空间、清理过期暂存导入和孤立备份，因此不能在真实用户默认账本上直接执行二十次冷启动测试。

正常启动继续使用原有默认数据库位置，无账号也可使用。Android 不使用此 Windows QA 配置。没有增加系统用户、修改 Known Folder/注册表、移动默认账本或修改系统环境。

## 已实现的显式隔离合同

Windows runner 既有 `GetCommandLineArguments()` 与 `set_dart_entrypoint_arguments()` 已正确传递参数，未修改 C++ runner。只有显式参数 `--jianzhang-qa-database=<绝对路径>` 会开启隔离；普通启动无需参数。

客户端先于 `runApp` 和数据库 provider 校验以下条件：

- 只能在 Windows 使用，一个完整参数，未知、重复或畸形 QA 参数拒绝。
- 实际 EXE 和数据库归属于同一 `.qa` 根；拒绝相对路径、UNC/device 路径、`.`/`..` 和非规范分隔符。
- 数据库必须是 `.qa/startup-<32 位小写 GUID>/sample-<两位索引>/jianzhang.sqlite`。
- EXE、样本目录、marker 及其每级祖先通过原生 `GetFileAttributesW` 检查；任何 reparse point、缺失或错误文件类型拒绝。UTF-16 参数在每次原生调用结束时释放。
- 样本目录初始只能包含 `startup-fixture.json`；已有数据库、WAL、备份等文件会拒绝。
- marker 的 `schemaVersion=1`、purpose、runId、样本索引、完整 EXE/数据库路径及初始零笔/数据库不存在声明必须逐项匹配。

已请求 QA 配置而校验失败会在数据库 provider 创建前抛出错误，不回退至真实用户账本。校验成功后只覆盖初始数据库路径 provider，继续使用同一个 SQLite 仓储、事务、后台连接及关闭逻辑。没有重写数据业务或在每次启动重哈希整个 payload。

## 测量方法

`scripts/native-toolchain/measure-windows-startup.ps1` 要求 PowerShell 7 和可用 Python sqlite3；只接受 `.qa` 内的完整已安装程序副本。保留既有 release build、来源、完整 Flutter 引擎/AOT/plugins/CRT/assets、安装包及前后 SHA-256 合同检查。

每次测量创建独立 GUID run 中的全新样本目录，生成绑定该 EXE 和索引的 marker，再通过 `ProcessStartInfo.ArgumentList` 传递一个完整参数，兼容路径中的中文和空格。计时从创建该子进程开始，包含本次数据库创建、账本加载、原生渲染和主窗口可见就绪，以后两者较晚时点结束；不清除操作系统文件缓存。客户端输出选择的 QA 数据库 marker，脚本必须观察到匹配路径/样本后才接受既有 post-ledger 原生 rendered-frame 就绪标记，并在原 15 秒总超时内取得本 Process 的可见主窗口。

关闭该子进程后，Python 以 `mode=ro` 确认 SQLite 完整性为 `ok`、schema 1、仅 guest 工作空间、sequence 0、账单为 0 笔。无此证明不产生通过的性能记录。失败时仅终止该测试创建的子进程，fixture 原样保留，便于排查。

输出明确记录 `dataState=fresh-empty-guest-ledger`、runId、每个样本的路径/marker/参数、原生与外部耗时及关闭后 SQL 状态。这是**全新零笔账本的进程冷启动**，包含 QA 路径校验，但不包含默认 Known Folder 路径查询；不是十万笔账本保存/筛选指标，也不是 OS 缓存清空后的启动性能。十万笔指标使用另外的原生性能用例。

## 验证证据

此次实现仅进行了针对性代码/fixture 验证，尚未运行真实二十次 release EXE 冷启动，未构建新发布包。

- `.qa/flutter-startup-isolation-targeted.log`：10 项 Dart 测试通过，包含真实 owned junction 拒绝、中文空格 EXE 路径、marker 逐项错误、旧 DB/WAL 拒绝及 provider 实际创建独立空 SQLite。默认路径测试只读取初始配置/provider 的 null 值，从未打开默认数据库。
- `.qa/flutter-startup-isolation-analyze.log`：针对性 analyzer 无问题。
- `.qa/windows-startup-isolation-pure.log` 与 `.qa/startup-isolation-pure-*/evidence.json`：9 组 PowerShell fixture 验证，包含独立样本、重复拒绝、边界/归属/实际 junction、只读 SQLite 前后字节一致及非空/损坏/schema 错误拒绝。负向 SQL 测试的预期 traceback 保留在日志中；没有执行生产 EXE。

生产源码变更需要独立审查和重建。真实冷启动、当前版本 Windows 键盘与完整双端回归仍须在冻结候选上完成，不能用这些针对性测试替代验收。

## R12：就绪拒绝条件的运算符分组

独立审查发现测量脚本明确允许的 `Int32` 耗时分支中，原 `-or/-and` 混合条件会错误接受“没有选中 QA 数据库”或“渲染尚未就绪”。当前 PowerShell 的实际 JSON 解析结果为 `Int64`，不能据此忽略被代码允许的 `Int32` 分支。修复只给两个类型拒绝谓词整体加括号，未修改生产 Dart 文件或发布二进制。

新增 fixture 直接从测量脚本的真实 `IfStatementAst` 提取条件并执行，覆盖 18 个场景：Int32/Int64 的缺数据库选择、渲染 false/缺失、有效值和零值；缺 ready、负数、浮点、字符串以及实际 JSON 解析正反例。

- 修复前 `.qa/windows-startup-readiness-ast-before.log` 退出 1；`.qa/startup-isolation-pure-f32cf14fe81d4b6eb6da50958fda3e50/readiness-cases.json` 记录 3 个真实条件失败，分别为 Int32 下缺数据库选择、渲染 false、渲染字段缺失。
- 修复后 `.qa/windows-startup-readiness-ast-after.log` 退出 0；`.qa/startup-isolation-pure-ed13b2aa53ca471d977f564385753ff9/readiness-cases.json` 18/18 通过，连同原 9 组验证为 10 组全部通过。

此次仍未执行真实冷启动 EXE、ADB 或注册表操作。上述是拒绝条件的回归证据，不替代 release 冷启动测量。

## R12：真实窗口可见性与失败诊断

随后 root 首次实际冷启动测量取得隔离数据库及 renderer ready 标记，但 `CloseMainWindow()` 返回 false，未产生有效二十次报告。进一步只运行了一个全新 owned 零笔 fixture；`.qa/windows-close-diagnostic-r12-db68b48be8b14c78b7077d8a298644f5/evidence.json` 保存了 child PID 2288、stdout、原生就绪 1625ms、每次 cached/refreshed MainWindowHandle 和仅本 child 的原生窗口属性。

在 ready 后及其后两秒，实际 `FLUTTER_RUNNER_WIN32_WINDOW` 始终存在、enabled=true、visible=false；每次 `Refresh()` 后 MainWindowHandle 仍为 0。关闭请求为 false，诊断最终仅终止该 child，只读 SQL 确认为完整 guest 零笔账本。这不是已修复的性能样本，不是异步显示等待就能解决的成功案例，也不是正式冷启动 p95。

原因是测量脚本将交互式客户端设为 `WindowStyle.Hidden`。原生 runner 虽调用 `ShowWindow(SW_SHOWNORMAL)`，首次调用仍由 launch 的 startup information 控制，因此窗口被隐藏。[Microsoft ShowWindow 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow) 说明了首次显示的 startup information 规则。`Process.MainWindowHandle` 只表示关联 Process 的可见主窗口，并需 Refresh 更新缓存；`CloseMainWindow` 在没有主窗口或窗口 disabled 时返回 false。[MainWindowHandle](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.mainwindowhandle?view=net-10.0)、[CloseMainWindow](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.closemainwindow?view=net-10.0)

测量脚本最小修复为 `WindowStyle.Normal`，保留 `CreateNoWindow` 以抑制 console。待校验 renderer ready 后，刷新该 Process 的 MainWindowHandle，取得非零可见窗口后停止外部时钟，再正常关闭、确认 exit 0、校验只读 SQL，最后才将样本加入接受列表。不搜索或关闭其他应用窗口，不降低原性能阈值，不将隐藏窗口样本计为通过。持续不可见、child 提前退出或计时器已停止均为失败。

失败时在 Output 的已拥有 `.qa` 目录创建唯一 `<Output文件名>-failure-<runId>-<sample>.json`，保留 stdout/stderr、fixture、原生 ready、窗口观察、PID、关闭/cleanup状态、原始异常及来源/payload哈希。写入被拒或存储失败时保留原始采样异常；不会覆盖已有诊断。失败文件中的已接受部分样本不构成完整性能结果。

- `.qa/windows-startup-visible-before-r12.log`：真实 StartInfo assignment AST 检查先复现 Hidden，退出 1；红证据 `.qa/startup-isolation-pure-4fedce940ab24a3fbd2d6befe1c5fabe/window-style.json`。
- `.qa/windows-startup-visible-after-r12.log`：原 readiness 18 场景继续全部通过；新增实际 StartInfo assignments/精确参数、真实窗口等待 helper 的延迟句柄与计时停止、退出/永不可见/停止时钟拒绝、真实 AST 顺序及拥有范围失败 JSON 写入测试，合计 16 组通过。绿证据 `.qa/startup-isolation-pure-e789d15595914c9d9140879a9dbefca7/evidence.json`。

该修复仅修改测量脚本和 pure fixture；生产四文件保持冻结 SHA，没有改 runner 或重新构建。未再运行修复后的真实 EXE，也未执行 ADB、注册表或正式二十次基准。独立复审后由 root 在当前冻结候选上执行实际可见客户端测量。

## R12c：Refresh 跨越总超时后的拒绝

独立审查又复现了 deadline 边界：若 `Process.Refresh()` 及句柄读取跨过总超时，原 helper 只在循环开始检查时间，取得非零句柄后仍可能接受。补充回归测试直接执行从真实脚本 AST 提取的 `Wait-StartupMainWindow`，令 fake Process 的 Refresh 延迟 60ms，使用 20ms 总超时，并验证确实调用 Refresh 一次、观察到迟到的句柄。

- `.qa/windows-startup-deadline-before-r12c.log` 退出 1；红证据 `.qa/startup-isolation-pure-8a3fd7a90cdb497a8820bc95cecbb83b/late-refresh-deadline.json` 记录超时后的句柄仍被接受。
- 最小修复是在 `Clock.Stop()` 后、返回成功前检查精确 `Elapsed.TotalMilliseconds >= TimeoutMs`，超限抛出原有总超时错误。默认 15 秒及其他测量阈值保持不变。
- `.qa/windows-startup-deadline-after-r12c.log` 退出 0；绿证据 `.qa/startup-isolation-pure-e203da501f344eb485caa1f88a4cef89/late-refresh-deadline.json` 记录迟到句柄被拒绝，所有 17 组 fixture 及保留的 18 个 readiness 场景通过。

本次只执行 pure fixture，没有启动 EXE、ADB 或修改生产四文件。真实二十次基准仍由 root 在独立复审通过后完成。
