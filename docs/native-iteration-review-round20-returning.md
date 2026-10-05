# R20 revision RETURNING 独立审查

结论：未发现需要修复的阻断问题。范围仅为 `_mutate` 与 SQL 成本回归的最小差异；未修改生产源码，未运行测试、构建或 ADB。此为源码审查结论，不是双端候选或性能验收。

`clients/flutter/lib/data/sqlite_ledger_repository.dart:343–364` 保留同一事务内的 CAS、业务写入、预算处理和 revision 更新。`UPDATE … RETURNING sequence` 一次更新并返回新值，仍以绑定参数设置 guest dirty=0、其他工作区 dirty=1。工作区主键保证至多一行，`.single.read<int>`、`afterRead` 或 `beforeCommit` 失败均在提交前传播并回滚；账单、预算设置及 sequence 不会部分提交。`_checkScope:320–335` 保留独立 revision SELECT，未移到事务外；`_exclusive` 继续保护工作区和操作顺序。预算去重、阈值集合、2000 条裁剪均未改动。

Drift 2.35.1 的 `connection_user.dart:338–350、363–380` 将 `customWriteReturning` 路由到当前事务 executor 的一次 `runSelect`；原有 UPDATE 和随后 SELECT 合并为一条语句。未传 `updates` 不影响本仓库自己的事件流（`allTables/allSchemaEntities` 为空）。`transaction:518–537` 等待真实 commit 完成后才返回；核心 `:360–363` 随后发送新 revision 与预算通知，失败不会发事件，也没有提交后的确认查询。

`test/data/repository_sql_cost_test.dart:60–76` 检查一次 RETURNING、无额外 sequence SELECT，并确认最终 revision=1；CAS 用例 `:138–164` 保留一次独立校验 SELECT 并核对事件值。测试观测 SQL 边界，结合上述 Drift 实现确认少一次 executor 调用；不用于声称已测得 RPC 耗时收益。提交确认用例 `:79–103` 的新 matcher 匹配返回行 hook，独立 audit 连接只在已提交新 revision 可见时注入失败，能识别 RETURNING 被移出事务的回归。回滚用例 `:106–135` 无 CAS 参数，保证在业务写入及 revision UPDATE 后注入失败，检查无账单、revision 不变、无事件；两项 matcher 有效。

本地依赖与产物核对：`pubspec.lock:99、595` 锁定 Drift 2.35.1、sqlite3 3.7.0。缓存包 `sqlite3-3.7.0/lib/src/hook/compile/description.dart:65–67` 默认下载预编译 sqlite3，`hook/build.dart:19–34` 注册 `DynamicLoadingBundled`，`CHANGELOG.md:27` 记录 SQLite 3.53.4；应用 `sqlite_ledger_repository.dart:514` 使用 `NativeDatabase.createInBackground`，未发现 system source 或加载器覆盖。项目平台为 Android、Windows；包 `lib/src/hook/assets.dart:193–205` 覆盖两平台配置中的 ABI。现有 Android x64 与 Windows x64 hook manifest 的 `user_defines` 均为空、加载方式均为 bundled，缓存二进制版本字符串均为 3.53.4，SHA 与包内 `asset_hashes.dart:36、60` 匹配。SQLite 自 3.35.0 支持本次顶层 UPDATE RETURNING，锁定的 bundled 版本满足要求；不能用 Android 系统 SQLite 版本判断本项目兼容性。[SQLite RETURNING 文档](https://www.sqlite.org/lang_returning.html)

已读取根任务执行日志：`.qa/revision-returning-red-r20.log` 新增用例因未观察到 RETURNING 而失败；GREEN 11/11；`.qa/flutter-tests-r20.log` 全量 182/182；`.qa/flutter-analyze-r20.log` 无问题。未独立重跑。R19 的 save 307.423ms 未达 300ms、query 226.227ms 与 scroll 6/668 达标属于前一候选证据；这些结果不能归因于 R20。本次正式构建、实际打包库和候选性能绑定仍需根任务验证。

审查时源码 SHA-256：

| 文件 | SHA-256 |
|------|---------|
| `clients/flutter/lib/data/sqlite_ledger_repository.dart` | `2196fa386d4b93d9e7570b830bd57971235821c260039faca14bf1981da53531` |
| `clients/flutter/test/data/repository_sql_cost_test.dart` | `36a16c691c7efc88696ca650a4f25b85ec1a52d24e2d591cfec33576147c0c8c` |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 0     | pass   |
| MEDIUM   | 0     | info   |
| LOW      | 0     | note   |

Verdict: APPROVE — 仅限本次最小源码修改；双端正式候选与性能验收仍待核对。本轮审查结束，不开展额外优化。
