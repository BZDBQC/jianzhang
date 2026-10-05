# R16 Flutter SQLite 快路径独立审查

审查日期：2026-10-06。范围：`sqlite_ledger_repository.dart`、`sqlite_queries.dart`、`repository_sql_cost_test.dart`；对照 `.qa/sql-fastpaths-r16/before-core.dart` 和 `before-queries.dart`。只读源码，未编译、未启动测试或修改他人代码。本报告核对已有执行证据，不将开发性能样本计入正式验收。查询筛选语义另由只读 explorer 独立核对。

## Findings

未发现置信度超过 80% 的未解决问题。R16 修改可通过本轮代码审查。

## 语义核对

- **CAS、提交与事件 sequence 保留。** `sqlite_ledger_repository.dart:320` 的工作区比较未变；expectedSequence 查询从包含账单 COUNT 的 meta 改为 `:332` 的工作区 sequence 单列读取，读取的是同一行同一值。`:337` 的独占队列、事务内 scope 校验、业务写入、预算通知状态、sequence 自增及 commit hook 顺序未变。`:354` 仍在事务成功返回之后发 changes；事务失败不会到达事件发送。此优化保持原来的“提交后查询当前 sequence”机制，没有新增外部连接写入之间的强保证。`sqlite_mutations.dart:25` 新增账单的十万条 COUNT 限制仍存在，没有因 sequence-only 快路径而删除。
- **父/子分类混合筛选与分页保留。** `sqlite_queries.dart:161` 仅在 categoryIds 为空时省略分类 LEFT JOIN；`:87`、`:102` 的 c.parent_id 条件只出现在父分类非空分支，因此需要 c 别名时仍使用原 join。分类表 `PRIMARY KEY(ws,id)` 保证旧 join 每笔账单最多一行，移除它不会改变无父分类查询的重复行/缺失分类行为。`:175` 和 `:200` 的 search/summary 继续共用 `_where`；排序、limit、offset 与参数未变。独立 explorer 对照原始查询文件确认 `_where`、`_totals`、`budgetStatuses` 未变。
- **转账本金/手续费口径保留。** 查询 `:62` 的 includeFees/feeOnly，金额条件 `:135` 的 CASE，以及 summary `:203` 将转账 fee 计入 expense 的表达式均未改。子分类单独筛选直接使用 t.category_id；父子混合仍保留分类 join。新测试 `:124` 使用共享 domain fixture，包含手续费金额筛选、转入/转出账户、混合父/子分类、Unicode 备注、日期边界，并额外覆盖手续费子分类；期待值由 fixture 的显式 ids 及所选账单计算，未直接从待测 SQL 反推。
- **预算去重与裁剪保留。** `sqlite_ledger_repository.dart:360` 先读 preferences，notifications=false 的早返回未变。没有当前预算时仅跳过类别名称查询，仍执行 notified 的集合去重与 `:381` 超出 2000 项时删除最早项；没有加入“无预算直接返回”的语义捷径。`{b.threshold,100}`、通知 key、触发条件与 notice 文案未变。`:382` 仅在结果列表完全等于原 notified 时跳过 settings UPDATE；重复旧 key、新 key 或裁剪造成变化时仍写入。

## 回归测试与证据

新测试用 `afterRead` 观察 SELECT，同时在测试独占的临时 SQLite 数据库中用 AFTER UPDATE OF settings trigger 统计写入（`repository_sql_cost_test.dart:28`）。该计数随事务回滚，能辨别相同 settings 的冗余 UPDATE；测试数据库与清理范围限于 `jianzhang-sql-cost-` scratch。测试验证行为及 SQL 成本边界，包括提交 revision、100001 条拒绝、混合筛选/费用、无预算规范化、threshold=100 仅通知一次、两种新阈值追加后保留最近 2000 项、禁用通知保留旧 key。

已核对的记录：

| 证据 | 结果与范围 |
|------|------------|
| `.qa/sql-fastpaths-r16/red.log` | 原始源码下 2 passed / 6 failed，与 evidence.json 记录一致；失败针对新增快路径断言 |
| `.qa/sql-fastpaths-r16/green.log` | R16 快路径 8/8 passed |
| `.qa/sql-fastpaths-r16/existing-regression.log` | 已有数据/回归集 26/26 passed，包含 CAS/回滚及大账本导入导出 |
| `.qa/flutter-tests-r17c.log` | 全量 179/179 passed |
| `.qa/flutter-analyze-r17b.log` | No issues found |
| `.qa/sql-fastpaths-r16/final-import-regression.log` | 删除冗余测试导入后的最终 8/8 passed |

R16 evidence.json 里的两个 production source、两个 before source 和 RED/GREEN/existing 三个日志哈希均与现有文件一致。测试文件当前哈希与该早期 evidence 记录不同；审查在内存中补回唯一首行 `import 'dart:async';`，SHA-256 精确还原早期记录 `0d1509cb43ec107a857ff319ec7a16696a0142b2c7238e29ac7987c3a39504c2`。因此差异已明确归因于移除该冗余导入，未发现测试体漂移。最终测试文件另有 8 项通过记录。

## 最终源码 SHA-256

| 文件 | SHA-256 |
|------|---------|
| `clients/flutter/lib/data/sqlite_ledger_repository.dart` | `a6ca3fb957e2cd62ff92d86a9d93cc1cc254857eb102fbdeb7469594c1365b8d` |
| `clients/flutter/lib/data/sqlite_queries.dart` | `3183fde2142b17299588ff2e5554b17972b6e562c9e4f43e72938fa66be26fe4` |
| `clients/flutter/test/data/repository_sql_cost_test.dart` | `6084ccceddcd098f959db3058ba12a27b614d994ae99bbc398a68c1569b289c8` |

补充日志 SHA-256：全量 `2a23e2f7027f2760a4e9892d77ae5137067a9e332d77396c2b06d574d5067b30`；analyzer `b3ab47014d9661ee0de3c876d87b33568d3194157744c1563ff7da1a841d0f7e`；最终 8 项 `bb3ad18a4dde4eaea762cae14d1630d2a4f6b3132999d3340be13e56b0548b60`。

## 正式验收边界

`phase-read-analysis.json` 明确为 derived read-callback diagnostics 且 formalAcceptance=false。回调间隔包含 Dart、排队、事务及 SQL，不能等同单条 SQL 执行时间；旧 trace 中可移除的 callback 次数也不能推算 R16 节省的毫秒数。上述单元测试日志中的 Shell/100k 性能输出仅为开发验证。R16 的实际 profile/release 性能、固定环境与最终打包候选绑定仍需新测，本报告没有认定任何平台 p95 或正式发布验收已通过。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 0     | pass   |
| MEDIUM   | 0     | info   |
| LOW      | 0     | note   |

Verdict: APPROVE — 仅限 R16 SQL 修改及其开发回归证据；正式候选性能与平台验收仍 pending。
