# 简账 2.0 独立代码审查

审查日期：2026-10-05（Asia/Shanghai）。状态：首轮审查，有待修问题，未验收。代码由多名代理同时形成；以下行号对应本轮读取时的工作区，复审须以修复后的文件和回归证据为准。

范围：新增原生 TypeScript 接口、Flutter 领域与 Drift 仓库、云客户端、文件适配、Riverpod 状态及界面调用、验收脚本；Android 文件桥接作首轮静态检查。Windows 安装器、完整平台构建和系统矩阵需专项复审。

已按要求检查 staged diff、工作区 diff、未跟踪新增文件及相关旧版调用。采用 coding-standards、dart-flutter-patterns 技能。未运行 Flutter 测试，避免与实施代理的测试占用冲突；未更改生产代码。

## HIGH

### H1 — 写操作的 CAS 未绑定工作区身份

File: `clients/flutter/lib/data/sqlite_ledger_repository.dart:555`、`:629`、`:660`、`:1312`；`clients/flutter/lib/ui/entry_form.dart:65`、`:108`。

Issue: `_mutate` 只比较序列号，实际写入使用当前动态 `_workspace`。`replaceSnapshot` 也只有 `expectedSequence`，没有预期来源工作区。不同工作区可以有相同序列号和相同默认账户、分类 ID。用户在 guest 打开表单后，异步云同步切到同序列的账号副本，旧表单仍可能成功写入新工作区。删除、账户、分类及预算等写命令同样未携带捕获的工作区身份。界面先读取 `meta.key` 再调用仓库不能替代事务内校验。

Fix: 将捕获的工作区 key 和 sequence 作为写操作 scope，在同一 `_exclusive`/事务内核对。同步替换同时核对来源身份、来源版本、目标版本。表单和确认框固定其来源工作区，发生变化时保留输入并提示用户重新核对。覆盖相同序列的跨工作区创建、编辑、删除、管理与同步回归。

### H2 — 导出替换存在丢失旧文件的窗口

File: `clients/flutter/lib/data/sqlite_ledger_repository.dart:1291`；`clients/flutter/lib/services/file_service.dart:64`。

Issue: `exportFile` 在 `temp.rename` 前删除现有目标；rename 失败后 catch 还会删除新临时文件，旧导出无法恢复。`copyExportAtomic` 虽然提供异常回滚，但先将旧目标改名，再改名新文件；若此时进程中断，原目标路径缺失，应用没有启动恢复机制。后者因此不能作为故障恢复要求中的原子替换实现。

Fix: 两处统一使用平台同卷替换原语，Windows 可经受限 native/FFI 封装使用 `ReplaceFileW` 并处理其失败恢复约定；没有旧目标时使用安全移动。旧文件必须在新文件提交成功前保持可恢复。测试目标锁定、只读、替换失败及替换阶段进程中断。Dart 的 [File.rename 文档](https://api.dart.dev/dart-io/File/rename.html) 没有承诺失败时保留已有目标，不应仅凭 Future 成功路径推定原子性。

### H3 — 核心仓库超过文件大小上限并混合多个责任

File: `clients/flutter/lib/data/sqlite_ledger_repository.dart:58`。

Issue: 本轮文件有 1,439 行，超过审查约定的 800 行上限；schema、锁与连接、查询统计、写命令、流式导入、备份裁剪、导出及云工作区都集中于同一文件。事务和可变工作区的关键不变量难以在后续修改中持续核对。

Fix: 安全拆分查询统计、导入备份、导出与工作区模块；可以用受约束的 library part 保持同一私有锁/事务上下文。不得通过拆分新增独立锁或提前发布工作区指针。保留全部现有回归并检查每个文件大小。

## MEDIUM

### M1 — 筛选结果的 JSON 导出实际包含整个账本

File: `clients/flutter/lib/ui/ledger_pages.dart:401`；`clients/flutter/lib/data/sqlite_ledger_repository.dart:1267`。

Issue: 菜单写“导出结果为 JSON”并传递当前 filter，但 JSON 分支直接 `_writeJson`，没有应用筛选。用户选择特定金额、备注或时间后会得到未选择账单，可能在分享导出时泄露额外财务信息。

Fix: 明确提供“完整 JSON 备份”，或者实现所选结果的有效裸 Ledger 导出并验证引用完整性。用含匹配和非匹配账单的样本核对实际导出内容及菜单提示。

### M2 — 账单、报表刷新忽略工作区 key

File: `clients/flutter/lib/ui/ledger_pages.dart:335`、`:517`。

Issue: `didUpdateWidget` 比较 sequence、筛选或月份，没有比较 `meta.key`。同序列切换工作区时，已有页面状态仍可能展示上一工作区账单或报表，并配合新工作区账户、分类信息渲染。

Fix: 工作区身份改变时重新查询；账单分页和不适用的旧筛选须重置。回归使用相同序列、不同账单内容的两个工作区。

### M3 — Android 选中文件的私有缓存没有消费后清理

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:111`、`:119`；`clients/flutter/lib/ui/file_actions.dart:95`。

Issue: Android `openFile` 将原文档复制到 cache 后返回临时路径；Flutter finally 只丢弃数据库 staging，未删除该私有副本。成功导入、取消确认及损坏文件拒绝都会累计文件。反复导入十万笔账本会持续占用磁盘，备份保留十份的裁剪并不处理这些文件。

Fix: 文件服务返回明确的 owned-temp 句柄，在所有消费退出路径清理；只允许清理 Android 桥接创建的私有缓存，不能删除 Windows 用户选择的原文件。加入导入成功、失败、取消三种清理回归。

### M4 — 验收门槛接受不存在的证据和重复轮次

File: `scripts/check-native-acceptance.mjs:15`、`:26`、`:31`、`:38`。

Issue: 脚本只检查 evidence 的 truthiness/length、人工填写的数值和 SHA 格式，不核对证据文件、包的实际 SHA 或轮次独立性。本轮使用只读内存 VM，输入三个完全相同的轮次，全部 evidence 为不存在的路径，虚构相同安装包 SHA，脚本输出 `accepted: true`、`cleanRounds: 3`、`failures: []`。因此当前门槛不能证明同一候选完成三轮实际回归。

Fix: 使用独立 roundId、开始/结束时间和每轮日志；证据必须为可读取的文件，安装包实际 SHA 必须匹配；性能从原始样本重新计算，不直接相信汇总 value。拒绝重复轮次、缺失证据、包变化和伪造指标。不要把本轮 VM 结果当成应用验收证据。

### M5 — 删除最后一页最后一笔后无法返回前页

File: `clients/flutter/lib/ui/ledger_pages.dart:432`。

Issue: 共 51 笔时用户位于第二页，删除第 51 笔后 `_offset` 仍为 50。重新查询返回 total=50、items=[]，页面直接进入“没有匹配账单”，上一页按钮也位于被跳过的分支，其他 50 笔无法从当前分页回到。

Fix: 数据变化后将 offset 调整到有效最后一页并重新查询，或者在空页仍提供上一页操作。覆盖末页删除和工作区切换后总数变少。

## 已核对但不能代替验收的部分

- 新原生接口只接受显式 Bearer，拒绝 Origin 和非安全传输；旧网页 Cookie/Origin 检查仍在。会话随机 token 的服务端哈希存储、失效与注销复用既有鉴权核心，本轮未找到明确鉴权绕过、SQL 注入或生产伪验证码。
- 请求体上限在读取时按字节累计；客户端上传编码包含 ledger、revision、expectedUserId 完整 UTF-8 envelope。云端用户绑定及 chunk 写入 CAS 使用参数化 D1 批事务。
- 金额整数分、转账单记录、手续费参与支出/预算/分类统计、旧本地日期及父子组合过滤的关键规则已核对。
- 预算去重写入位于保存事务内，通知在提交后发送。工作区活动指针目前在替换事务提交后更新；这些正向检查不覆盖 H1 的身份校验缺口。
- 读到现有 Flutter 数据测试日志 15 项通过、UI 日志 60 项通过，十万笔 debug 基准 save P95 27 ms/query P95 86 ms。该日志不属于 release/profile 双端最终验收，新增修复还须复测。
- EntryForm 已出现“重新读取并核对后再保存”按钮，先前无冲突重试入口的问题已有代码处理；仍须结合 H1 验证重新读取不会将旧草稿保存到另一工作区。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 3 | warn |
| MEDIUM | 5 | info |
| LOW | 0 | note |

Verdict: WARNING — 3 HIGH 问题应在最终候选发布前解决。当前不满足独立审查通过或三轮完整验收条件。
