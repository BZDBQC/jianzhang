# R15 性能分阶段诊断独立审查

结论：APPROVE。本轮只读审查没有发现置信度超过 80% 的未解决代码问题。此结论覆盖 QA 诊断代码，不代表 Android 或 Windows 的本轮性能实测通过，也不计入连续三轮回归。

审查基线为 Git `d3a3665`，唯一受审 Dart 文件为 `clients/flutter/integration_test/native_performance_test.dart`。最终 SHA-256 为 `08f54fc91db1c17f2456e80a2086ae6646e76a28906497b146081c3fc3e000fc`。已读取 staged、working diff、完整受审文件，以及仓库连接、读取回调、关闭路径和 Flutter/Dart 的本机实现。其他作者正在修改的安装诊断文档与 JavaScript 门禁不属于本审查的批准范围。

## 默认模式与测量完整性

`JIANZHANG_QA_TRACE_PHASES` 使用 Dart `bool.fromEnvironment` 的默认 false。原 `LedgerRepository.open` 正是委托给 `SqliteLedgerRepository.connect`；新调用在默认模式传入 `afterRead: null`，数据库、后台执行器、工作区和仓库逻辑保持一致。诊断时钟与容器的初始化位于采样区间之外。该判断是语义与采样区间核对，不宣称新旧运行的墙钟时间逐微秒相等。

独立纯检查在移除明确列出的诊断新增块和证据元数据后，对原文件逐字比较成功。30 次保存、30 次原组合筛选、12 次真实滑动、保存与查询 Stopwatch 的起止点、所有 `totalSpan` 原始样本、帧数和实际位移断言、五项响应性操作、全部导出与恢复，以及清理代码均保持原实现。没有缩短测量区间、过滤长帧、删除失败样本或调整验收阈值。

## 诊断字段与证据边界

启用诊断时，读取 hook 在 SQL 结果返回后调用，仅在 30 组保存/查询循环中记录。SQL 模板不包含绑定参数、账单数据或凭据。前台标签说明此时正在测量的操作，不声称标识后台刷新所属操作；回调之间的间隔明确不是孤立 SQL 耗时。

每个 `FrameTiming` 在保留原 `totalSpan` 样本的同一个同步 callback 中记录一行九列诊断，并检查两份数组长度相等。列顺序与值一致。本机 Flutter 实现确认 build 与 raster duration 分别为对应 finish/start 时间戳差，`totalSpan` 为 rasterFinish−vsyncStart。profile 回调按批次交付；`callbackFlingIndex` 明确表示回调到达时的前台滑动，不能用来精确归属批次内较早的帧。

`readTraceClockMeaning` 明确 `atUs` 为 connect 前启动的 Stopwatch 经过时间。`frameClockMeaning` 明确引擎时间戳采用自己的 epoch，未与该 Stopwatch 或 DateTime 校准，不能跨时钟直接相减。帧内阶段差值仍可比较。

三种 metric JSON 由同一 writer 写入 `diagnosticRun: tracePhases`，operations JSON 也写入该字段，附加诊断文件写入 true。开启 hook、帧细节收集及附加 I/O 会增加工作量，因此诊断运行只能独立归档，不作为正式性能验收运行。相关 JavaScript 门禁和负例测试另由独立审查负责，本文件不替代该审查。

## 失败与清理

诊断文件在原始三份 metric 后、导出前以 flush 写入独立 evidence 目录。之后的导出或恢复失败不会由 teardown 删除已写证据，也不会生成成功 operations 记录。若保存、查询或滑动断言在持久化前失败，则内存中的未完成诊断不会被伪造为成功文件；这保持了原 harness 对不完整运行的失败行为。

滚动 timing callback 的 finally 移除、响应性 callback 的 finally 移除、ticker 取消、挂载视图卸载和仓库关闭均保留。仅删除已解析并确认位于 benchmark parent 中的 `run-*` fixture；evidence 是 sibling 目录，不在删除目标中。本轮没有操作模拟器、运行 profile、构建客户端或变更生产代码。

## 证据

独立纯检查于 `2026-10-05T13:45:19.297Z` 执行，8/8 通过，执行前后受审源字节一致：

- `.qa/native-phase-diagnostics-independent-r15-5793440cf5f04edca4a178433d6ad26e/verify.mjs`
- `.qa/native-phase-diagnostics-independent-r15-5793440cf5f04edca4a178433d6ad26e/result.json`
- 较早元数据版本的七项通过结果和校验脚本保留为同目录 `result-initial-meta-bb1d565.json` 与 `verify-initial-meta-bb1d565.mjs`。

作者最初诊断版本的 analyze 日志为 `.qa/native-phase-diagnostics-analyze-r15.log`，结果无问题；最终两个时钟说明字段由本次逐字差异与字段核对覆盖，未把此前日志伪称为最终哈希的新一次 analyze。

字段语义核对使用本机 `.tools/flutter/bin/cache/pkg/sky_engine/lib/ui/platform_dispatcher.dart` 的 `FrameTiming`、`.tools/flutter/packages/flutter/lib/src/scheduler/binding.dart` 的 batching 说明，以及 `.tools/flutter/bin/cache/dart-sdk/lib/core/bool.dart` 的默认值实现。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: APPROVE — no CRITICAL or HIGH issues. No unresolved findings in the reviewed QA changes.
