# Flutter 领域与仓库公共接口

最后更新：2026-10-05。实现入口：`clients/flutter/lib/data/ledger_repository.dart`，模型：`clients/flutter/lib/domain/ledger_models.dart`。

## 状态与工作区

- `LedgerRepository.open(path:, workspace:)`：省略 workspace 时恢复数据库持久化的 active 工作区；新库 guest，仅默认账户和两级分类，没有示例账单。
- `meta()` / `workspaceMeta(key)` / `listWorkspaces()` 返回 key、sequence、transactionCount、cloudRevision、dirty。不存在目标工作区的 CAS 序号为 0。
- `switchWorkspace(key)` 仅切换本机视图。工作区为 guest 或 user:用户ID，原 guest 数据保留。
- `changes` 在真实提交之后发送当前 sequence。`budgetNotifications` 在提交之后发送预算提醒文字；提醒去重标志与账单同事务持久化，UI 不应再写同一标志。键为 month:categoryId:amount:threshold，关闭 notifications 时不产生提醒。
- 所有仓库 Future 均必须 await；失败保留表单输入，由 UI 展示 LedgerException / LedgerConflict。
- 当前工作区写操作及预览、导出、cloudSnapshot、switchWorkspace 接受 expectedWorkspace + expectedSequence；在同一串行锁和数据库事务内核对键与序号，同序号的另一工作区也会拒绝。调用方须在开启表单或延迟操作时捕获元数据。
- `readViewData(month:,filter:,recentLimit:12,expectedWorkspace:,expectedSequence:)` 一次返回 LedgerReadViewData：meta/accounts/categories/budgets/balances/settings/summary/recent，以及可选 storageWarning。首页初次 build 和后续刷新必须从这个入口构造界面视图，不再拼接独立查询；storageWarning 应可见呈现。
- 复合读取 search、summary、balances、statistics、budgetStatuses、listWorkspaces 使用同一读快照边界：固定工作区 Zone、实例串行锁、Drift executor 独占和 SQLite BEGIN DEFERRED。WAL 允许其他连接提交，当前读取仍保持旧数据库快照；同实例写入和工作区切换排队。写事务内预算读取复用 transaction Zone，不创建嵌套事务。
- `transactionById(id,expectedWorkspace:,expectedSequence:)` 也是一致快照读取；返回 null 表示账单已删除，供不在最近 12 笔中的编辑草稿重新核对。复制新草稿不要求原账单仍存在。
- 独立账单/报表页面调用 search、statistics 时也须传 expectedWorkspace + expectedSequence，将查询绑定到页面起点 scope；排队过程中切换账本或更新版本时会拒绝旧查询，由最新视图重新查询。

## 金额、日期和查询

- 每筆金额与手续费、期初余额都用整数分。单笔上限 99,999,999,999 分；聚合用 SQLite/Dart 64 位整数，可超过 JavaScript 安全整数。
- 期初余额允许负数；交易金额必须正数，手续费可以为 0。`parseMoney` 只解析普通十进制，拒绝科学记数与多余小数，`decimalMoney` 用于精确导出。
- 日期保存本地字面 `YYYY-MM-DDTHH:mm`；不转换时区。日期筛选包含两端整天。
- `search(filter, offset:, limit:)` 默认 50 条，上限 500 条，返回 items/total/offset/limit。组合筛选采用 AND；备注支持全部/任意关键词，Unicode 小写匹配且 %、_ 为字面字符。
- 金额支持等于/大于/小于/区间。大类和小类遵循旧领域合同；`includeFees` 用于支出报表、预算明细的手续费筛选，金额比较针对手续费，账户匹配只算转出端。普通账单搜索保留转账本金行为。
- `summary(filter:)` 返回 income/expense/count/balance，支出包含转账手续费，转账本金不进入收入与支出。
- `statistics(start:, end:, type:, monthly:false)` 返回 summary/categories/subcategories/trend；默认最多约 60 个连续时间桶，最后一桶截至 end。monthly:true 返回日历月桶，适用于年度报表。

## 变更

- `saveTransaction(entry, create:, expectedWorkspace:, expectedSequence:)`：新增必须 create:true 且新 UUID；编辑必须 ID 仍存在，工作区键或序号失配拒绝整个事务。成功才增加序号和通知。
- `deleteTransaction`、`upsertAccount`、`archiveAccount`、`upsertCategory`、`upsertBudget`、`deleteBudget` 与 `updateSettings` 都是后台 SQL 原子事务。
- 账户可以归档/恢复；至少保留一个未归档账户，归档默认账户会换到可用账户。历史账单继续引用归档账户。
- 分类严格两级，子类与大类同收支类型。转账有正手续费时必须使用支出子类。`deleteCategory(id,reassignTo:)` 的迁移目标始终为其他同类型小类；删除大类同时移除其子类和对应预算，历史账单与手续费统一迁移。

## 导入、备份与同步

- `previewImport(path)` 或 `previewJson(string)` 流式验证裸 Ledger v1 JSON；前者本机最多十万笔。预览返回 token、workspace、expectedSequence 及四种数量，原账本不变。
- `importAtomic(preview)` 校验预览工作区与序号，先保存当前账本，再原子替换；失败原账本、工作区指针与序号保持原值。无效/重复 ID、缺失 parentId、错误引用/手续费/日期均拒绝。
- `discardImport(preview)` 释放暂存。`listBackups()` 返回最近 10 份；`restoreBackup` 同样先预览、保存当前账本再恢复。
- `backupSnapshot(map,label:)` 保存有效云端快照为可恢复备份，不改当前账本或序号。
- `replaceSnapshot(map,workspace:,cloudRevision:,expectedSourceWorkspace:,expectedSequence:,expectedTargetSequence:)`：源键和源序号一起检查；expectedTargetSequence 独立检查目标工作区。一个 SQL 事务备份源与目标、替换目标、持久化 active；仅提交成功后更新内存工作区指针。不存在目标允许 expectedTargetSequence:0。
- `setCloudRevision(rev,workspace:,expectedSequence:)`：迟到上传响应可以更新服务器版本，但只有序号仍等于上传快照序号时才清除 dirty，避免吞掉上传期间新增账单。
- `cloudSnapshot()` 限制两万笔和裸 JSON 8,000,000 字节；HTTP 服务仍须独立校验实际 UTF-8 请求信封大小。
- 多 MB 云快照的 JSON 编码和解码运行于 compute 后台 isolate；仓库串行锁仍覆盖整个快照操作。
- 备份文件在同一 SQLite 写事务内独占创建并记录路径。导入、工作区替换或外部快照备份失败后，只删除该操作创建的文件；清理二次失败由 FlutterError 报告，原始异常对象与堆栈继续抛出。
- 启动清理在 BEGIN IMMEDIATE 写锁内读取备份元数据，仅删除本机 backups 普通目录中未被引用的 UUID-v4 普通 JSON 文件。其他连接尚未提交的备份受同一写锁保护；名称不受管理的文件、目录与链接不删除。每个数据库使用独立本机账本目录。
- 旧备份元数据在事务内裁剪，提交后删除旧文件；正常完成时物理文件与最近 10 份元数据一致。锁定或只读文件导致清理失败时保留账本及被引用备份，通过 storageWarning 提示，启动仍可读取和记账，下次启动重试清理。
- `LedgerBackupCleanupFailure` 由 `lib/data/ledger_repository.dart` 导出，包含 cause、committed、ledgerChanged。committed && ledgerChanged 表示导入或替换已提交，UI 应重载新视图、关闭已保存草稿并显示提示；backupSnapshot 的 committed 清理异常有 ledgerChanged:false，整个云端工作流仍应报告失败，不能假报同步成功。

## 导出

- `writeExport(path,format,filter:)` / `exportFile` 提供 JSON/CSV/XLSX。JSON 导出匹配筛选的账单，并保留全部有效、有界的分类/账户/预算/设置，仍是可恢复裸 Ledger；不指定筛选则完整导出。CSV/XLSX 是按筛选导出的账单报表。
- JSON、CSV、工作表 XML 和 ZIP 写入均分批异步处理；不会一次读取十万笔整账本。CSV 为 UTF-8 BOM、CRLF、双引号转义，并保护公式开头；XLSX 金额/手续费为真实数值单元格。
- SQLite 使用后台连接、WAL、synchronous=FULL、外键和参数化 SQL。
- 导出关闭同目录临时文件后调用 atomicReplaceFile；Windows 用 MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)，Android 用同目录 rename。替换失败保留原目标字节，清理临时文件，不再先删除原文件。
- 仓库由 core、queries、mutations、snapshots、backups 五个模块组成，同一实例共用串行锁、SQLite 事务和工作区指针；各文件少于 800 行。

## Unicode 搜索合同

`unicodeLower` 使用旧 JavaScript 运行时的 Unicode 17.0 全量小写映射，含 U+0130 的 i+组合点及 Final_Sigma 上下文；Dart 原生简单小写在这两种情况不同。原始备注与关键词使用同一函数。生成器 `scripts/native-domain-fixtures-unicode.mjs` 拒绝 Unicode 版本不符的 Node；规范依据：[Unicode 17 SpecialCasing](https://www.unicode.org/Public/17.0.0/ucd/SpecialCasing.txt)。

重复生成校验顺序为 Node 生成器、Dart format unicode_case_data.dart，然后比较 unicode_case_data.dart 和 native-unicode-v1.json 的 SHA-256；本轮校验相等。两份输出均随代码保存，应用运行时无需 Node 或联网。

## 当前证据与待复核

本轮完整真实 Flutter 回归 24/24 通过，日志 `.qa/flutter-domain-data-final.log`：旧 TypeScript golden、空账本、Unicode 字面关键词、手续费/预算/分类迁移、所有写操作与延迟读取跨工作区 CAS、筛选 JSON 恢复、月度时间桶、提醒去重与提交失败回滚、真实 SQLITE_FULL、重启工作区、10 份备份裁剪事务、Windows 只读与独占锁导出保留旧字节、CSV/XLSX、十万笔精确聚合及往返导入。

随后发现并修复全 Unicode casing 差异；领域全部 4 项与新增 SQL Unicode 用例 1 项通过，日志 `.qa/flutter-domain-unicode.log`。当前 owned analyze 无问题，日志 `.qa/flutter-domain-data-analyze.log`。debug 基线：保存 P95 12 ms，查询 P95 51 ms，事件循环最大间隔 45 ms，100k 全流程 129,223 ms。

这些领域测试不证明最终候选的双平台性能、整机断电、安装升级与三轮完整验收；整合 QA 证据记录于 native-checkpoint.md。源码仍须独立专项评审，单元数据测试通过不等于最终双平台验收。

第二轮独立评审指出 R2-1 复合读一致性问题后，增加 6 项确定性屏障回归：同序号切换中的完整视图、统计概览/分类/时间桶、独立 SQLite 连接中途提交时 COUNT/items、视图/meta、预算的快照一致性，以及 scope 拒绝与写事务中嵌套预算读无死锁。全部 domain/data 非十万笔用例 31/31 通过，日志 `.qa/flutter-domain-data-snapshot.log`；十万笔旧证据未在本轮重复执行，性能由整合 native profile 验证。测试使用两个独立 NativeDatabase executor，Drift 的 debug 多实例提示不代表共享同一 executor。

随后补齐独立页面查询起点 scope 参数，第 7 个屏障验证旧查询在同 sequence 切换后被拒绝、新查询成功。最新 7/7 targeted 回归通过，日志 `.qa/flutter-domain-read-snapshot-targeted.log`；最新 owned analyze 无问题，日志 `.qa/flutter-domain-data-snapshot-analyze.log`。domain/data 源码与接口已冻结，等待独立复审。

第三轮备份物理清理修复新增 9/9 targeted 回归，日志 `.qa/flutter-domain-backup-files.log`：重复导入/双工作区替换失败时文件集合不变，外部备份回滚，原始错误与二次清理报告，已提交操作状态和可见提示，跨连接未提交备份保护，真实强杀 Python SQLite writer 后的启动清理，以及 Windows attrib +R 孤儿文件仍可打开和新增。正常恢复后物理文件集合与元数据一致且最多 10 份，非托管文件和同名目录保留。

本轮全部非十万笔 domain/data 回归 41/41 通过，日志 `.qa/flutter-domain-backup-regression.log`；owned analyze 无问题，日志 `.qa/flutter-domain-backup-files-analyze.log`。未重复运行已有十万笔用例。数据源码再次冻结，等待独立复核；UI 已提交提示行为由根代理单独验证。
