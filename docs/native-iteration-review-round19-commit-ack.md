# R19 提交确认独立审查

日期：2026-10-06。只读审查 `_mutate` 与两项提交确认回归；未改生产文件、未启动测试/构建。测试与日志另由只读 explorer 独立核对。

未发现高置信未解决问题。

- `sqlite_ledger_repository.dart:343–354` 在同一事务内完成 scope/CAS 校验、业务写入、预算状态、自增 sequence 和 commit hook，再读取 revision 并返回 `(result, revision)`。读取失败仍处于可回滚区间，不会留下已提交账单却返回读取错误。
- `:356–360` 仅在事务 Future 成功后用捕获的 revision 发 changes/预算事件，并返回原业务结果；不会再为确认成功发起事务外 SELECT。独占队列、CAS 条件、dirty 更新与预算事件顺序保持。已读取本机 Drift 2.35.1 的 `connection_user.dart:519–537`：事务 action 结果返回前会 await complete，action/commit 异常走回滚；因此这里的事件没有提前到提交之前。
- `repository_sql_cost_test.dart:60–85` 用独立 audit 连接看到 sequence 已增加才注入 `afterRead` 失败，准确针对提交后的读取完成路径。它模拟的是 SELECT 执行后、读取结果返回前的错误，不是底层 SQL 执行错误。RED 确实以 `Injected read failure after committed save` 失败。
- `:88–118` 对事务内 revision 读取注入失败，并断言无账单、sequence 不变、下一个事件轮没有 changes；测试能区分回滚与已提交后误报。原 CAS 测试也保留成功 revision 与两次 sequence SELECT 的断言。

已核对日志：RED 目标用例失败；`.qa/postcommit-ack-green.log` 19/19 通过（含 100k 回归）；追加回滚测试后的 `.qa/postcommit-ack-final.log` 明确包含两项新用例、10/10 通过；`.qa/flutter-tests-r19.log` 全量 181/181 通过；`.qa/flutter-analyze-r19.log` 无问题。19 项旧日志不用于证明后加的回滚用例覆盖。上述是根任务已有执行证据，本审查没有重跑；日志里的性能样本不属于正式验收。

最终源码 SHA-256：

| 文件 | SHA-256 |
|------|---------|
| `clients/flutter/lib/data/sqlite_ledger_repository.dart` | `458ed70f2b00d01d3f2388c0b7f27a80ab53f118569ef1f8aef83652e4ca7164` |
| `clients/flutter/test/data/repository_sql_cost_test.dart` | `125f081747cd989335f0e9961b0226ec45c2c263348792b47eca2ab129e1dbc9` |

编译产物/平台性能绑定和发布候选验收不在本次提交确认审查范围，不能据此更新为通过。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 0     | pass   |
| MEDIUM   | 0     | info   |
| LOW      | 0     | note   |

Verdict: APPROVE — 提交确认修复及两项回归有效；正式产物与平台验收仍单独核对。
