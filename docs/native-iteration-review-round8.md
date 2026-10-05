# 原生迭代第 8 轮独立审查

结论：**APPROVE（下列冻结改动范围）**。未发现仍未解决且置信度超过 80% 的缺陷。本结论是代码审查与本地测试结果，不是双端完整验收，不计作一次干净回归。

审查者没有修改生产源、作者测试或 golden，没有执行 ADB、安装器、注册表操作或真实短信。开始查看了暂存/未暂存 Git diff；本轮原生目录仍为未跟踪文件，因此结合完整相关文件、调用点、冻结 SHA、作者基线日志及独立 fixture 核对。

## 冻结范围

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/test-android-saf.ps1` | `005e163933fa1d752c9dab857aaa633d66c358e7ca9e34cf4d526780a41f9a4b` |
| `scripts/native-toolchain/measure-android-startup.ps1` | `67fc226c22d686451c18430ecedd9dec71d6efbffbe82f9f5a3afa0c9d0b5401` |
| `scripts/native-toolchain/test-android-ui.ps1`（仅 Capture 的 PNG 守卫增量） | `bd9af3cb3d707241c024ebdc227cce6e90059c55824c90038f0df93aa4a91e67` |
| `clients/flutter/lib/data/sqlite_snapshots.dart` | `dc10cf9d6a228abbace824ceab826e25d9ec343fab8796310b6d6e516aaa9e6a` |
| `clients/flutter/lib/data/ledger_exports.dart` | `c0f3f59770ef8caf5139c74eff9f40e2a65aaef44d3c3c27082a56aed1940ce4` |
| `clients/flutter/test/data/export_batch_test.dart` | `675bcca13ab4d5c477ba65642b52c60d660fe55059bc4d53369e9b9e3428347b` |
| `clients/flutter/integration_test/native_performance_test.dart` | `7336a2e8eb5613d1991be3b50955c76959e8db5c43de49a165f5dce9d8983245` |

导出 21 份完整 byte gzip golden 及 README 的 22 个文件逐一按 `.qa/export-batch-freeze.json` 校验，独立测试开始与结束均核对这 22 个文件及 3 个导出源/测试 SHA。

## 审查中发现并关闭的问题

**[HIGH，已修复] SAF 清理时间可能假通过。** 最初冻结 `fee08afd…` 的最终判断仅检查缓存为空和早于 provider 30 秒，5 秒 deadline 只约束循环；一次 ADB 轮询超过 5 秒后返回空集合仍可通过。作者改为从发出返回操作前的时间建立 deadline，最终显式拒绝 `afterBackCleanupMs > 5000`，并在返回前要求观察到非空的实际导入缓存。修复冻结 `20c0dd55…` 及后续仅增加 PNG 守卫的 `005e1639…` 均经提取条件 fixture 确认 5001 ms 的空集合结果失败。

## 证据与控制流核对

- SAF PowerShell AST 无解析错误；7 个纯参数/条件 fixture 通过：无效 RoundId、BuildId、实体设备 Serial 被拒绝，4999 ms 成功、5001 ms 空缓存失败、残留缓存失败、达到 provider 30 秒失败。最终 SHA 的重新执行记录：`.qa/native-iteration-review-round8-r2/saf-static-fixture-evidence.json`。
- 内嵌 Python 使用正确转义的文件 URI 和 `mode=ro`；只执行完整性、schema/columns 和排序读取。当前真实 9 张表全部进入摘要，包括 `app_meta`、预览 staging 与备份表；表/列名双引号正确转义。5 个本地 fixture 通过：中文/空格/`#`/`%` 路径、Unicode/NULL/重复行/quoted 标识符及相反插入顺序、`app_meta` 变更检测、schema 变更检测、DB/WAL/SHM 副本读取、损坏数据库非零退出。摘要过程中主 DB bytes 未改变。正常路径显式 `close()`；异常产生非零 Python 子进程退出，进程资源由退出关闭。最终 SHA 的重新执行记录：`.qa/native-iteration-review-round8-r2/saf-digest-fixture-evidence.json`。
- SAF 只允许固定 QA API 35 AVD 和包名；唯一输出目录与 UUID 临时设备文件受控，非递归清理仅列出的自有文件。release/provider 实际 APK、本地两种 source/发布 sidecar、当前客户端/provider 源及共享 Ledger fixture 在开始/结束均绑定 SHA；installed APK 同样核对。正常 JSON 预览后取消、可靠管道错误、损坏 JSON 和停滞取消均要求 SQL 全表状态不变。脚本只在主过程与清理均成功时记录 passed；本审查没有实际跑这些设备用例。
- SAF 和 Android UI 的新增 Capture 检查要求至少 33 bytes 且符合 8-byte PNG signature；长度检查使后续读取尺寸字段不会越界。两个脚本共 6 个纯提取条件 fixture 通过：实际 PNG 接受，系统 assertion 文本和仅 8 字节的截断 signature 拒绝。文件：`.qa/native-iteration-review-round8-r2/png-guard-fixture-evidence.json`。这项检查是文件头与长度验证，不是完整 PNG 解码或视觉验收；Android UI 此次只复审该增量。
- 冷启动新增 observer 为只读系统字段采集，3 个纯 mock fixture 通过：模拟实际 MemTotal 3584000 KB、4096 字节页、4 CPU、AVD 名、两条 size、density、GLES 均原样报告；内存或 renderer 不可观察会失败。before/after 都调用 observer，原 APK/installed/manifest/source 前后 guard 保持。报告实际观测值，不能据此把初始 canonical MemTotal 冒充本轮精确值。文件：`.qa/native-iteration-review-round8/startup-runtime-fixture-evidence.json`。
- JSON/CSV/XLSX 仅将原逐行文本写入合为 `StringBuffer`。原 flush 检查点保持；JSON `first` 不跨批次重置，尾批在后缀前排空；CSV BOM、CRLF、公式防护及引号转义保持；XLSX 原 `rowIndex % 500` 条件包含首批 498 数据行及 header，数字 cell/Unicode/XML 控制字符过滤及 ZIP 路径保持。分页顺序、数据库事务、备份写入调用、原子发布和异常清理位置未改变。
- 独立执行 `flutter test --no-pub test/data/export_batch_test.dart --reporter expanded`，**11/11，退出 0**。覆盖 0/1/499/500/501/1000 的三种格式完整 bytes、筛选日期稳定顺序、三种导出第二页故障保持已有文件/账本/备份且重试完整，以及恢复前备份第二页故障的原异常身份、完整性与重试。文件：`.qa/native-iteration-review-round8/export-batch-independent-tests.log`。另核对作者旧实现 baseline 11/11、改后包含现有 atomic/backup/scope 的 29/29 日志和 targeted analyze；不把作者执行写成独立执行。
- 性能 harness 的 3 份原始指标写入位于 30 组保存/查询样本和真实滚动/帧数断言完成之后、导出之前，写入不进入保存/查询采样与滚动帧窗口。阶段日志未改变阈值、采样或 JSON schema。导出、恢复、UI 响应断言仍必须全部成功，才写最终 operations 并使测试成功；仅已有 raw metrics 不代表完整通过。验收 gate 仍独立要求 `export-restore-ui-responsive` 本轮成功执行及日志证据。此项核对冻结新文件实际控制流，未取得旧 reviewed harness 文件副本做逐字 diff，也未独立运行 native profile。

## 验证边界

本次导出独立测试使用 Windows 主机 Flutter 测试环境，不是 release/profile 性能结论。Android SAF、启动真实采样、Android 100k 导出/恢复及三轮完整回归仍由实际设备测试提供证据；不能用本地 fixture 代替。Windows 10 实机、Android 真机、真实短信发送均未验收。完整交付状态由当前候选包、冻结来源和验收报告决定。

## Review Summary

| Severity | Count | Status |
| --- | --- | --- |
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: **APPROVE — 审查范围内无已知未解决问题；完整原生验收仍未完成。**
