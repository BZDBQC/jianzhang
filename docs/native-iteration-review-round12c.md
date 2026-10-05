# 原生迭代独立复审，第十二轮窗口可见性

结论：**当前 Windows 冷启动 QA 冻结仍 BLOCKED，待补总 deadline 的最终判定。** Normal 窗口配置、渲染后等待可见句柄、关闭/SQL 后接受样本及故障诊断均通过本轮审查，但真实 helper 会接受刷新期间已经超时的可见句柄。生产四文件的原批准不受影响。

## 冻结范围与独立执行

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/measure-windows-startup.ps1` | `4c006b3d49aa3c0fc98d32195a339cdd640440799dbcb55d62afdaa681d146a2` |
| `tests/native-qa/windows-startup-isolation-fixtures.ps1` | `64072446968f660782e4a2cbbf72fd53940c558cd4b33f469fe3e6cc322b4033` |
| `docs/native-startup-isolation.md` | `076f74a5d6b4b4741498521caa4b89ea39cd4b6b08ff051614b2a8854688f62d` |

输入为 `.qa/windows-startup-visible-r12-freeze.json`。读取 staged/unstaged diff、新 helper、完整相关 fixture 与故障资料。独立纯 fixture **16/16 组、exit 0**，保留原真实 readiness AST **18/18**；两份 PS Parser 为 0 错误，独立运行前后两份脚本 SHA 匹配冻结值。

- `.qa/windows-startup-visible-independent-r12c.log`
- `.qa/startup-isolation-pure-198ad0cbc4e44a16a8a1387b8be88dec/evidence.json`
- 同目录 `readiness-cases.json` 与 `window-style.json`
- `.qa/windows-startup-visible-independent-parser-r12c.json`

这些 fixture 不执行生产 EXE，也没有运行顶层二十样本基准。

## 已确认的修复与原故障证据

实际 StartInfo Assignment AST 配置为 `WindowStyle.Normal`，保留 `CreateNoWindow=true`、精确单参数、stdout/stderr 重定向与 `UseShellExecute=false`。交互窗口需要可见；抑制 console 与隐藏测量 GUI 是两个不同设置。

独立读取作者仅一次诊断记录，提取后保存在 `.qa/windows-hidden-diagnostic-independent-summary-r12c.json`：PID 2288 的 native ready 为 1625 ms；ready 后 32 次观察从 1727.40 到 3704.29 ms，主窗口始终属于该 PID、enabled=true、visible=false，Refresh 后句柄全部为 0。CloseMainWindow 为 false；仅该 child 被终止，关闭后只读 SQL 证明完整 guest/sequence 0/零笔账本。原资料为 `.qa/windows-close-diagnostic-r12-db68b48be8b14c78b7077d8a298644f5/evidence.json`。这不是有效冷启动样本，也不是修复后真实运行结果。

独立核对官方文档：首次 `ShowWindow` 的显示参数可能被启动程序提供的 STARTUPINFO 替代；这与 Hidden 启动后原 runner 的首次 Show 无法显示相符。[Microsoft ShowWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow) `Process.MainWindowHandle` 属于关联进程；隐藏进程返回 0，刷新缓存需调用 Refresh。[Microsoft MainWindowHandle](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.mainwindowhandle?view=net-10.0) 因此 Normal 调整及同一 Process 的 Refresh 等待具有直接依据；本轮未再次启动客户端证明动态恢复。

AST 顺序确认：匹配隔离 DB marker 与 post-ledger renderer ready 后调用 `Wait-StartupMainWindow`，可见句柄出现后停止 clock、取 elapsed，再 CloseMainWindow、等待关闭、exit 0 和只读 SQL，最后才加入 samples/logs。刷新与窗口观察始终只使用创建的 Process，没有搜索或关闭其他应用窗口。完整 engine/AOT/plugins/CRT/assets 的 payload、来源及前后 hash guard 保留，采样数量与性能阈值没有降低。

## [HIGH] 刷新耗时越过总 deadline 后仍返回成功

文件：`scripts/native-toolchain/measure-windows-startup.ps1` 的 `Wait-StartupMainWindow`。

当前仅在 while 入口检查 `$Clock.ElapsedMilliseconds -lt $TimeoutMs`。进入循环后，`Refresh()`、MainWindowHandle 读取、观察记录都可能使总时钟超过 deadline；若此时句柄非零，代码直接 Stop 并 return，没有最后一次期限判定。外部调用也不会再次检查 deadline。随后关闭与 SQL 正常时会接受这个超时样本。

独立执行真实 helper，以自有 fake Process 的 Refresh 延迟 60 ms、`TimeoutMs=20` 模拟阻塞：实际 **visibleAtMs=94.3567、accepted=true、clockStopped=true**。这是真实函数分支的负测，不是复制表达式或真实客户端运行。缩短 timeout 使用 helper 本身允许的参数范围，避免等待十五秒；同样的漏洞存在于默认 15000 ms 期限。

冻结证据：`.qa/windows-startup-visible-deadline-independent-r12c.json`，SHA-256 `bc65cc7914a3ef984f0f5c96857dbb87e5bfe71a4c639838b91c0cc11eb4c88a`，绑定原脚本 SHA `4c006b…`。

最小修复建议：成功句柄分支先 Stop，再在 return 前检查最终 elapsed；`Elapsed >= TimeoutMs` 则抛出总 deadline 错误。补真实 helper 的 delayed Refresh 负测，证明超时句柄不被接受。时长本身目前被如实记录，此缺陷并非隐瞒 p95 值；它违反明确要求的总启动期限和超时拒绝合同，所以修复前不批准正式二十样本运行。

## 原始错误与诊断独立故障验证

独立提取并执行真实 per-sample Try/Catch/Finally AST，仅使用 fake Process 及已拥有的 `.qa` 文件。模拟 renderer marker 存在而隔离 selection 缺失，随后同时模拟 Kill 抛错；原 readiness 异常继续抛出，cleanupError 独立记录，stderr 与失败信息保留，Dispose 执行，samples/logs 均为 0，没有正常性能输出。

再模拟 diagnostic 已存在而写入拒绝：原异常仍保持，已有诊断 hash 未变，异常不会被写诊断失败覆盖。两项均通过，证据 `.qa/startup-cleanup-review-r12c-416cb6fe96f1465f80b928e2f195b572/evidence.json`，日志 `.qa/windows-startup-cleanup-independent-r12c-final-fixture.log`。

自有 mock 前两个尝试有构造问题：null Task 的泛型绑定错误及 PowerShell 把其结果转为空串，未到达预定业务负例；它们不计产品故障或测试通过。最终 mock 使用明确 JSON renderer 文本，实际原异常和 cleanup/diagnostic 条件均按设计触发。没有改作者代码。

## 验证边界

本轮不执行实际 EXE、ADB 或注册表/安装器操作。真实可见窗口二十次 release 测量仍未通过；不能把一次 Hidden 诊断或纯 fixture 当作性能证据。完整安装与当前候选双端完整回归也需要独立运行证据；Windows 10、Android 真机、真实短信未验收。原报告和红证据保留，当前生产键盘/安装状态不由本次静态复审改写。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 1 | pending |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **Windows 冷启动 QA BLOCKED — 等待最终 elapsed 期限检查与真实 delayed Refresh 回归后重新冻结。** Normal 配置与失败诊断的已验证部分保持认可；实际性能结论未产生。
