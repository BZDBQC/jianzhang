# 简账独立客户端：第三轮 Flutter 独立代码复审

日期：2026-10-05。生产代码只读，本任务仅新增报告。复审第二轮四项 HIGH 的修复，并检查原子替换 FFI、性能集成测试和桌面提示条修复；PowerShell、NSIS、新启动测量脚本不在本轮范围。

第二轮四项 HIGH 已有实质修复。本轮未发现剩余 CRITICAL/HIGH，发现两项 MEDIUM，修复后仍需回归及复审。这里的“第三轮”是第三次代码审查，不能当作同一候选版本的第三轮完整验收。

## 原问题复核

| 原问题 | 状态与证据 |
|---|---|
| R2-1 复合读跨工作区/版本拼接 | 已解决。`_readSnapshot` 固定 workspace zone，并持有同一 executor 的 `BEGIN DEFERRED` 读快照；WAL 允许其他连接提交。嵌套读复用当前快照/写事务，不重复 BEGIN。`readViewData` 包含 meta、账户、分类、预算、余额、设置、概览和最近账单；`statistics/budgetStatuses/search` 也在同一边界内。页面查询捕获 key/sequence、filter、offset，入队后再校验。初始 controller build 发现期间变更时重新读取，避免旧初始化覆盖新状态。 |
| R2-2 草稿重核对只更新 CAS | 已解决。账户重核对更新当前账户，保存保留最新 archived；分类刷新 icon/color、层级和候选列表；迁移目标和预算范围刷新后重新校验。已删除账户、分类、预算和账单禁继续保存；账单通过带 scope 的 `transactionById` 查询，覆盖不在最近 12 条内的对象。输入控制器保留草稿。 |
| R2-3 滚动/IO响应测试缺少实质判据 | 原判据已补。测试采用 profile/release、30 次保存和查询，检查账单 ScrollPosition 有 extent 且至少 6 次 fling 真正移动；IO期间加入渲染 heartbeat、导航点击和最大事件循环间隔 ≤150ms。审查发现 `ancestor(BillsPage,Scrollable)` 方向错误，已反馈并修正为 descendant。异步就绪仍有 R3-2。 |
| R2-4 超过 800 行文件 | 已解决。账户 290、分类 380、预算 285、设置 132、云面板 501、数据管理 230 行，管理聚合文件仅导出。剩余最大 UI 文件 ledger_pages 为 756 行；生成的 Unicode 表不需要人工模块化。 |

`repository_read_snapshot_test.dart` 七个屏障测试实际暂停第一条读取，分别排队切换工作区或让另一连接提交，核对所有视图字段、COUNT/items、分类/趋势、预算和 spending 的一致性；另验证延迟入队 scope 拒绝及嵌套预算读不死锁。测试内容与修复的故障时序相符。

## 新发现

### [MEDIUM] R3-1 外围事务回滚后，新备份文件变成未登记孤儿

File: `clients/flutter/lib/data/sqlite_snapshots.dart:243`；调用处 `:192`、`:502`。

Issue: `_backup` 先将完整账本写到 `backups/UUID.json`，然后把 metadata 插入外围 import/replace 事务。若后面的 staged 应用、目标 CAS 检查、提交 hook 或 COMMIT 失败，SQLite 回滚 metadata，物理文件仍存在。`_trimBackupMetadata` 只找数据库中的备份，启动也不清理这类孤儿。重复失败会累积十万笔大小的完整文件，既不显示于备份列表，也不受最近十份上限约束，并加重磁盘不足。

现有 `repository_scope_test.dart:374` 故障回归只检查 metadata、保留文件存在和旧文件被删除，未检查目录总集合。按当前故障时序，原有10份 + 失败孤儿1份 + 重试新备份1份 - 淘汰旧备份1份 = 11份物理文件；这是静态时序推导，本审查未重复运行 tester。

Fix: 外围事务追踪本次创建的受管备份路径，回滚后只清理本次文件；成功前不能删除原保留文件。启动时受控清理不被 metadata 引用的 UUID 备份，以覆盖进程中断与先前删除失败，校验路径位于应用备份目录。补失败/重试/重开测试，比较实际文件路径集合与 metadata，而不只检查条数。Root 已交领域实施者修复，本报告版本仍未完成。

### [MEDIUM] R3-2 性能测试没有显式等待 provider 与账单数据就绪

File: `clients/flutter/integration_test/native_performance_test.dart:221`、`:251`、`:315`。

Issue: 恢复后仅断言仓库 count 为十万笔；随后依赖 `pumpAndSettle`，没有核对 ledgerProvider 的 key/sequence/count 与仓库一致，也没有显式等到账单成功结果及 Scrollable 出现。异步 SQLite Future 尚未返回而当前无新帧时，pumpAndSettle 可提前结束。符合 ≤500ms 的查询仍可能晚于其一次 pump，导致 Scrollable finder 为空、性能假失败；截图也没有证明 provider 已更新到恢复后的版本。

Fix: 用有 deadline 的轮询等待 ledgerProvider 的 key/sequence/count 与仓库匹配，再等待账单真实 Scrollable 有有效 extent；确认成功结果后再取 position 和截图。超时保留实际错误，不能降级成空页面或仍继续记录指标。Root 将追加此修复，随后需复审和原生实测。

## 原子替换与桌面提示条

没有发现本次 FFI 的高置信新增缺陷。staging 必须存在、非空、为普通文件，与目标同目录；Windows 以 `CreateFileW(OPEN_EXISTING)` 打开并 FlushFileBuffers，随后单次 MoveFileExW 替换；Android 以无 O_CREAT 的 open、fsync、rename 提交，并处理 fsync 的 EINTR。丢失 staging 不会重新创建空文件覆盖旧备份，资源在 finally 释放。Windows 测试覆盖缺失/空 staging、目标只读/独占、目录、中文空格及重试。Android FFI 分支仍需模拟器系统执行证据；未将本地 Windows 测试扩展为 Android 通过结论。

桌面 Snackbar 在宽度 ≥1000 时限制为 520，与侧栏“记一笔”错开，手机仍采用默认浮动布局。`notice_regression_test.dart` 在1000、1440宽度检查两矩形不重叠，并在提示出现期间实际点击打开 EntryForm；`.qa/flutter-notice-regression.log` 为2/2通过。没有发现该改动的新问题。

## 验证边界与版本记录

- Root 提供领域/数据31个、屏障7个、UI/服务91个通过；本审查静态核对测试断言，不争用 Flutter tester。
- `.qa/native-windows-ledger-drive.log` 显示 Windows profile 离线三种记账、重开集成通过；`.qa/native-windows-performance-drive.log` 显示开发 profile 十万笔测试03:08通过。开发 buildId 和单次通过不作为最终三轮完整验收证据，本审查没有独立重算其 raw records 的 p95。
- 本轮没有运行 Android native 分支、Windows 10、安卓真机或真实短信，也没有审查安装包、注册回滚、启动测量脚本。结论只限本轮代码与已明确日志。
- 其他实施者仍在修 R3-1/R3-2，以下指纹限定报告读取版本；报告落盘不代表后续变更已经审查。

| 文件 | SHA-256 |
|---|---|
| data/sqlite_ledger_repository.dart | `73f4f6bde490045e0a4c7369d6bbfe28afff40b884d8274938639d2dbec82e37` |
| data/sqlite_queries.dart | `d585c06f816b094640b89a6cf69f69e1dd5d02704ec84e797a602ef2fbda2285` |
| data/sqlite_snapshots.dart | `9acb13560e9d8baccfafda7961eb094567dac1c843873a80becfab5e395f20c0` |
| app/controller.dart | `77f61d3423703943450c1d80142c41f7972387325a3811079cc5770873473735` |
| ui/common.dart | `de22825d5e56ac2a5cf61fb19dfa2cc923fa6bc4f177cbc95bf528d889d9bb63` |
| services/atomic_file.dart | `3106a431caf94556d16f39004b510163177be09d76f045fe4b86dc10ef687558` |
| integration_test/native_performance_test.dart | `36bdc61bdc4cead883097da37630b5ae14cc60d8ce5cce0e1cd131ecee432d9a` |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 2 | info |
| LOW | 0 | note |

Verdict: APPROVE at the CRITICAL/HIGH code-review threshold; 2 MEDIUM issues remain and must be resolved for the agreed acceptance goal. 此代码复审不计完整验收轮次。
