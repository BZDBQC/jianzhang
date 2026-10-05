# 简账独立客户端：第四轮收口代码复核

日期：2026-10-05。生产源码只读；本任务仅写报告。范围限定第三轮两项 MEDIUM 的修复、备份清理异常的 UI 状态传递、性能脚本就绪等待。安装脚本、最终包兼容与三轮完整回归不在本次验收结论内。

第三轮两项 MEDIUM 已解决。另发现一项 UI 状态耦合问题，Root 已接受并开始修复；本报告先保存检查点，警告字段分离及对应真实 UI 回归需要后续精准复核。最终候选完整回归仍为 **0/3**。

## 已解决事项

| 项目 | 复核结果 |
|---|---|
| R3-1 回滚遗留未登记备份 | 已解决。`_backup` 独占创建 UUID 文件并加入本次 created 列表；外围 import/replace/backup 事务失败只清理本次文件，不删原保留备份。原始异常与堆栈保持，二次清理失败报告并留下 storageWarning。成功裁剪提交后才删旧文件。 |
| 进程中断留下孤儿 | 已覆盖。启动清理持有 SQLite `BEGIN IMMEDIATE` 写锁，读取所有引用路径，仅清理 owned backups 普通目录中的未引用 UUID-v4 普通 JSON 文件；不跟随链接，也不删其他名称、目录。其他连接尚未提交的备份受相同写锁保护。清理拒绝/占用不阻止健康账本读取，留下提示并下次启动重试。 |
| 提交后清理失败被误当未保存 | 已解决领域合同。`LedgerBackupCleanupFailure` 区分 committed 与 ledgerChanged。导入/替换已提交时 controller 重载并返回 true；仅备份清理失败时 ledgerChanged:false，controller 返回 false，不假报账本或后续云端工作流完成。新备份及被引用文件保留。 |
| R3-2 性能脚本异步就绪 | 已解决。`waitForCurrentView` 有10秒 deadline，每次先 pump，再比对 provider 与仓库的 key/sequence/count；滚动前还要求 BillsPage 后代 Scrollable 存在，随后检查 extent 和实际位移。首次启动、初次十万笔恢复、滚动前、最终恢复后都有调用，超时抛 TestFailure，不继续登记指标。 |

备份文件9项回归检查物理文件集合与 metadata 相等、反复失败只删本次文件、源/目标双备份回滚、目标 CAS 拒绝、二次异常保留原始错误、提交后异常语义、跨连接未提交备份保护、强杀 Python SQLite writer 后清理，以及 Windows attrib +R 孤儿仍可打开和新增。与第三轮提出的故障时序相符。

## 本轮发现并交回修复

### [MEDIUM] R4-1 非致命备份警告被当作读取错误，阻止草稿重核对

File: 本轮首次读取的 `clients/flutter/lib/app/controller.dart:55`；`clients/flutter/lib/ui/common.dart:213`、`:238`；`clients/flutter/lib/ui/entry_form.dart:169`。

Issue: 首次读取时 `LedgerView.fromSnapshot` 把 storageWarning 赋给 error。管理草稿 `DraftScopeNotice` 和账单 `_recheck` 以 `latest.error == null` 判断成功读取。只读/占用孤儿持续存在时，每次健康的 readViewData 都带 warning，所以管理表单不调用 onRechecked，账单直接报读取未完成；即使 scope 未变，管理表单也错误显示“账本已变化”。

触发：留下只读孤儿 → 打开健康账本和表单 → 同账本提交另一笔使草稿 CAS 过期 → 首次保存被拒绝 → “重新读取并核对”。读取确实成功但 warning 非空，草稿无法更新 scope 并继续保存。仓库“仍可新增”的测试不覆盖该 UI 组合；用户虽可重新打开表单，保留的草稿恢复流程已被阻断。

Fix: 非致命 storageWarning 与实际读取/写入 error 分字段呈现；重核对只拒绝真实读取失败、跨工作区或未就绪。补真实 Windows 只读孤儿下，账单和账户表单经历 CAS 冲突→重核对→保留输入→成功保存的行为回归，同时检查持续提示和未变 scope 不假报变化。

Root 已接受，报告收尾时 controller 已开始使用独立 storageWarning 字段，shell 与真实 UI 回归正在修改。本报告不把进行中的修改视为完成验证；只对此项后续精准复核，无须重新扩大本轮范围。

## 已检查的状态边界

- 备份删除路径须位于解析后的 owned backups 普通目录、名称受管理、实体为普通文件；不存在文件允许重试清理。没有发现误删已登记备份、尚未提交备份或用户其他文件的高置信缺陷。
- 导入/替换先提交并更新活动指针，再发变更事件、处理旧文件。清理失败能识别已提交状态，避免 UI 误报整个账本未保存。
- backup-only 失败保持当前 sequence 与账单；清理异常继续抛给原工作流，未继续执行后续 action。新 `backup_warning_test.dart` 验证 committed/ledgerChanged 返回值、视图 count、busy 和可见消息，但其原有两个测试未覆盖持续 storageWarning 的草稿重核对，故需要 R4-1 新回归。
- Windows FFI 原子替换与此前审查相同，本轮没有新改动或新发现；Android 原生执行仍留待最终平台验收。

## 证据与界限

本次读取 `.qa/flutter-domain-backup-files.log` 为9/9通过，`.qa/flutter-domain-backup-regression.log` 为非十万笔41/41通过，`.qa/flutter-domain-backup-files-analyze.log` 无问题；`.qa/flutter-ui-services-round4.log` 为95/95通过。没有竞争运行 Flutter tester，也没有重跑十万笔 native profile。本轮新增性能等待代码尚不以此前开发 profile 通过日志代替执行证据。

以下为稳定领域代码及性能脚本的本轮读取指纹；UI 警告修复进行中，不在此表中声明冻结。任何行为或交付修改仍清零最终候选干净轮次。

| 文件 | SHA-256 |
|---|---|
| data/sqlite_backups.dart | `69f0cadb44da3fde91df47dc262dcdc90a1f7df5b0065b06368ed8c274e285cc` |
| data/sqlite_snapshots.dart | `545415b73ae69a187f0e6951ce6260213e14df66a17d0ceac3ae098b1924c4a0` |
| data/sqlite_ledger_repository.dart | `53bc550c3d9dfb3749aecb24643e0861d533fb177dba5b4b404b949f1690495e` |
| domain/ledger_models.dart | `dc9dc8cfaac3b9c2b4c44b26b898e23a726d678ca07cc2661562e2feeb3c49d9` |
| integration_test/native_performance_test.dart | `4fa999ab1bd3a1ada06f9639ee1be62f67fbfe9b0a87f48a211e549c1280d9b1` |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 1 | pending targeted re-review |
| LOW | 0 | note |

Verdict: APPROVE at the CRITICAL/HIGH review threshold; R4-1 remains pending its in-progress fix and targeted verification. 仅为代码审查，完整候选验收仍0/3。
