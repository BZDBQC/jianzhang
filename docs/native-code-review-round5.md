# 简账 R4-1 精准复核

日期：2026-10-05。本轮只读复核备份警告与读取错误耦合的修复，不重新扫描此前已确认的代码，也未运行 Flutter tester。

**R4-1 已解决。本次限定范围没有已知未解决审查问题。** 最终候选三轮完整回归仍为0/3；本报告不代表 Android、Windows 安装或整套软件验收完成。

## 修复与测试核对

- `LedgerView.fromSnapshot` 将健康读取中的警告传入独立 `storageWarning`，不设置 error；copyWith 保留持续警告。真正的读取/写入错误继续走 error，原有草稿 scope 与读取失败校验保留。
- 已提交且 ledgerChanged 的备份清理异常重载最新视图，把提示放入 storageWarning，保持 error 为 null 并返回 true。仅备份失败仍返回 false、显示操作失败，不假报后续云端流程成功。
- shell 独立显示警告和错误；警告具备 `storage-warning` key 和 liveRegion。用户可以看到持续提示，而草稿重核对不因警告被拒绝。
- `backup_warning_test.dart` 两个真实 Windows 场景创建受管 UUID 孤儿、设置 attrib +R、重开真实仓库：分别打开 AccountEditor 和 EntryForm，确认初始 error 为 null、不假报账本变化；制造外部 CAS 变化，旧保存被拒绝；重新核对后 error 为 null、警告仍在；再保存成功，核对改名、9988分及备注草稿，孤儿仍存在，未以清理文件掩盖原故障。
- 另两个回归保留 committed/ledgerChanged 两种结果，核对正确返回值、计数、busy、警告/错误可见。`.qa/flutter-ui-warning-recheck.log` 为4/4通过，测试断言覆盖本轮提出的原故障时序。

未发现本次修复的新实质缺陷。根代理正在双端构建；本轮没有把此前开发 profile 的结果算作修复后或最终候选证据。

## 读取版本

| 文件 | SHA-256 |
|---|---|
| app/controller.dart | `b06ea589fa64d38df2271fae2ee5b47ff5643493eb4da4faeeb52429481482e6` |
| ui/shell.dart | `7791f5a05c5191ffbf2fd421884127597017a53e6458907d180250ba07e604f1` |
| test/ui/backup_warning_test.dart | `78c2482deaf78b98fe5288a418417a5d7006ff951474671ab4329066d3681a74` |

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | note |

Verdict: APPROVE — R4-1 closed within the targeted review scope. 仅为代码复核，完整候选验收仍0/3。
