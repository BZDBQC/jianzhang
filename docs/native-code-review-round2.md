# 简账独立客户端：第二轮 Flutter 独立代码复审

审查日期：2026-10-05。范围为 Flutter 领域规则、Unicode 17 表、Drift 仓库拆分与 scope、界面刷新和草稿、文件服务、性能集成测试及 driver。生产代码只读；本次只新增本报告。安装工具链和验收门槛 TypeScript 由其他审查任务处理。

结论：第一轮问题已有实质修复，但发现下面四项 HIGH 问题，需修复并补回归。本轮是代码复审，未执行原生性能脚本，也未执行双平台完整验收，不能计作三轮中的任一完整轮次。

## 第一轮问题复核

| 原问题 | 复核状态与依据 |
|---|---|
| 工作区切换后旧表单可写入另一账本 | 已修复写入边界。UI 写操作携带打开时的 `expectedWorkspace/expectedSequence`，`perform(expectedScope:)` 与仓库事务再次校验。`replaceSnapshot` 校验来源及目标版本，提交后才切换活动工作区；上传回执显式更新原工作区，保留并发本机更改。读取一致性另见 R2-1。 |
| 导出先删除既有文件，失败可能丢旧备份 | 已修复。仓库和 `FileService` 都写同目录 staging，再调用 `atomicReplaceFile` 单次 OS 替换，无显式先删目标。Windows 使用 `MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`，Android 使用 libc `rename`；Windows 文件测试覆盖只读目标、目录目标、中文空格路径和失败保留旧内容。Android 原生分支仍需模拟器验证。 |
| 仓库 1439 行单文件 | 已修复。拆为 core、queries、mutations、snapshots；本次读取分别为 448、279、304、596 行。UI 新增的超长文件另见 R2-4。 |
| JSON 查询结果导出忽略筛选 | 已修复。JSON 使用相同 `_where`，分页导出全部匹配记录；保留账户、分类、预算、设置，保证引用完整。`repository_scope_test.dart:223` 核对导出 ID 与查询结果，并重新预览/恢复，验证手续费 234 分。该测试只覆盖一页，不能代替十万笔恢复验收。 |
| 同 sequence 切换账本时账单/报表不刷新 | 已修复。两页面同时比较 `meta.key` 和 sequence。UI 回归覆盖同 ID、同 sequence 的两账本，核对旧内容消失、新内容出现。 |
| Android 选择 JSON 缓存未清理 | 已修复 Dart 生命周期。`PickedJson.ownedTemporary` 区分用户文件与私有缓存；导入 finally 释放缓存，包括预览取消和损坏 JSON；UI 测试验证释放一次且原账本不变。原生 releaseFile 限定 cacheDir 和受管文件名；实际系统 picker 仍需原生验收。 |
| 删除最后一页最后一笔后无法回上一页 | 已修复。查询在有效总数变小时重定位上一有效页，零条时归零；UI 测试覆盖 51→50 笔并核对页码和非空状态。 |
| 验收门槛把缺失/重复证据当成功 | 本轮不复审，由独立 TypeScript 审查处理。 |

预算通知与备份裁剪的新测试分别核对：事务失败不通知、不持久化去重标志；提交后通知，重启不重复；失败导入回滚备份 metadata，成功后保留十份可恢复文件。没有发现新的提交前通知缺陷。

## 剩余问题

### [HIGH] R2-1 复合读取没有固定工作区和数据库快照

File: `clients/flutter/lib/data/sqlite_queries.dart:186`，`clients/flutter/lib/app/controller.dart:173`。

Issue: 写入已串行和 CAS，但复合读仍在每次 await 后读取活动 `_workspace`。`statistics` 先读 summary，再分别读大类、小类和多个趋势 bucket；`budgetStatuses:253` 先读预算，再读支出与分类；controller `_load` 顺序读账户、分类、预算、余额、设置、概览、最近账单，最后才读 meta。`_exclusive` 只保护写入/导出，没有保护这些读取。`search:112` 的 COUNT 和 items 也不是同一读快照。

触发时序：A 账本的 statistics summary 完成 → `switchWorkspace(B)` 提交 → `_totals` 和趋势读取 B。返回对象会包含 A 总额和 B 分类/趋势。`_load` 同理可能把 A 账户/分类与 B meta/余额拼接，随后 UI 用 B 的 scope 操作 A 的展示内容。generation 能丢弃部分旧刷新，但不能把单次 `_load` 或 `statistics` 变成一致快照；初始 build 直接返回 `_load`，也没有 generation 校验。

Fix: 在仓库提供统一的工作区读取快照/组合视图 API，固定 workspace，并使用同一事务或开始/结束 key+sequence 校验后丢弃重试。`statistics/budgetStatuses/search` 和 `_load` 必须使用这一边界；不能仅给每个独立查询加锁后又释放。补确定性屏障回归，在第一条读完成后切换工作区/提交写入，验证整个结果始终来自一个 key、一个版本，包括 summary、分类、趋势和 meta。

### [HIGH] R2-2 草稿重新核对只更新 CAS，仍会写回隐藏旧状态

File: `clients/flutter/lib/ui/manage_pages.dart:208`、`:235`；相关 `common.dart:196`。

Issue: `DraftScopeNotice` 重新读取成功后，管理表单回调只更新 `_scope`，仍引用原 `widget.account` / `widget.view`。AccountEditor 保存时把不可编辑的 `archived` 从打开时账户拷贝。分类、删除迁移目标、预算范围的 options 也仍来自旧 `widget.view.categories`（manage_pages:519、551、823）。编辑对象已在新版本被删除时，分类 upsert 可把旧对象重新创建。

触发时序：打开未归档账户的改名表单 → 同账本并发更新把该账户归档 → 首次保存正确遭 CAS 拒绝 → 点击“重新读取并核对”更新 sequence → 再保存。归档状态仍为原来的 false，账户会被意外恢复；用户无法在表单中看到或核对这个隐藏字段。

Fix: 保留用户输入，同时保存最新读取的完整 view / 最新实体，刷新隐藏字段及所有候选列表；已删除对象需要明确拒绝继续编辑，或显式选择另存为新对象。表单重校验不能只提升 CAS 版本。补归档后重核对改名、分类删除/新增后 options 刷新、编辑对象被删除后不复活的回归。

### [HIGH] R2-3 性能脚本尚不能证明实际滚动和连续 UI 响应

File: `clients/flutter/integration_test/native_performance_test.dart:162`、`:186`。

Issue: fling 作用于整个 `BillsPage` 的中心，没有定位实际 Scrollable，也没有验证 scroll position 或可见账单发生变化；只检查采到至少 20 帧。导航、加载或其他动画帧也可能满足该断言，脚本能把未实际滚动的帧当作长列表滚动指标。导出/恢复仅要求 Timer tick 增加超过 10；长时间阻塞后再恢复也能满足。记录的全程 `maxEventLoopGapMs` 没有断言，计时器响应不能证明渲染或用户操作响应。另只用 `pumpAndSettle`，未显式等到 provider 的十万笔 meta/sequence 与数据库一致后再进行滚动截图。

Fix: 定位账单 Scrollable，检查有效 scroll extent 与每轮 position 位移/可见记录变化，按实际滚动区间收集帧。导出/恢复期间同时运行渲染 heartbeat，并实际点击导航/交互，验证完成响应延迟及每次操作的最大事件循环间隔；显式等待 ledgerProvider 达到目标 key/sequence/count，再查询和截图。Root 已计划加入真实位置断言、帧 heartbeat、导航响应以及最大事件循环间隔 ≤150ms；修改后须分析并实际在 native profile/release 跑。未运行脚本前不构成性能通过证据。

### [HIGH] R2-4 管理和设置页面重新超过审查大小阈值

File: `clients/flutter/lib/ui/manage_pages.dart:1`（855 行），`clients/flutter/lib/ui/settings_page.dart:1`（839 行）。

Issue: 两文件均超过审查清单的 800 行阈值，分别集中账户/分类/迁移/预算表单，以及备份/恢复/工作区/登录/双向同步/冲突流程。R2-2 中 scope 提升与实体刷新分散在同一大文件内，当前结构增加遗漏共享状态边界的风险。

Fix: 按责任拆分账户、分类与预算页面/编辑器，设置页拆出云同步和备份管理；共用草稿重核对逻辑保留单一实现。拆分保持行为不变，复用既有 UI 回归；任何交付行为变化仍需重新计算干净轮次。

## 本轮证据与边界

- Root 提供的执行结果：领域/数据 24/24，领域 5/5，UI/服务 82/82；本审查检查相关测试的断言与调用，不重复执行 Flutter tests，也不把这些结果称为双平台完整回归。
- 独立只读 Node 验证：Unicode runtime 17.0，生成表 1488 条映射；遍历全部 Unicode 标量，lowercase mapping 与 Cased/Case_Ignorable ranges 零差异；10,000 条 Sigma/忽略字符/非 BMP/未配对 surrogate 上下文随机案例在同逻辑校验器中零差异。这是生成表与算法结构检查，不能替代实际 Dart 和原生性能执行。Dart [String.runes 官方语义](https://api.dart.dev/dart-core/String/runes.html) 明确保留未配对 surrogate 半部，未将其误报为字符替换缺陷。
- 新 native 性能 harness 当前仅 analyze 通过；Windows 10、安卓真机、真实短信仍未验证。本次不评审安装包，也不声称系统兼容或指标已达标。
- 本报告落盘时相关文件仍有其他实施者修改；以下指纹限定本次读取版本。后续修复需要复审。

| 文件 | SHA-256 |
|---|---|
| sqlite_queries.dart | `8702b205351988489b010848573f8f923914dd0971df7c07ecca7c21c19a07b0` |
| app/controller.dart | `db709a24636b3b8cfb8f735ad32bfebc8a16ba92458d4850778407c303ddc9f8` |
| ui/manage_pages.dart | `a7ae865cec5c5923fb6afb780550a80a82e6f87888244ec675d41c89140fb34e` |
| ui/settings_page.dart | `d973d9d3d183c5fb65f0ae1a9d232d7010b740d55770ca19e021bfe86ac72692` |
| integration_test/native_performance_test.dart | `2c12b15728c5eea04f880ce256447f404d5f7e6f7963941970ecbfd1568fa057` |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 4 | warn |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: WARNING — 4 HIGH issues should be resolved before release. 此代码复审不计为完整验收轮次。
