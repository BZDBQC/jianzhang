# 文件操作错误文案独立审查

日期：2026-10-05。结论：**本次局部错误展示修复 CLEAR**。审查者未编写或修改实现/测试，未运行 Flutter SDK、ADB、短信服务或真实账本。

| 文件 | 审查 SHA-256 |
|---|---|
| `clients/flutter/lib/ui/file_actions.dart` | `b950561a1d88d90608b7bc14fb6b26cb5c08c44414a5249673814e04f68fff5a` |
| `clients/flutter/lib/ui/data_management.dart` | `6764c374ab6a7242cd31d07205ad852e3bde3fa15ae9809badf1be37bd2cfca9` |
| `clients/flutter/test/ui/file_failure_test.dart` | `367480d27848bad0709e6533b9be3622d994980e0cf586edf105992fe5816c83` |

## 行为与错误原因

- Android reliable pipe 在平台读取阶段正确拒绝失败文件，但原 UI 直接展示原始 PlatformException；本次改变错误展示，不把读取拒绝修改成成功，也不改变导入事务。
- `showFileFailure` 将 LedgerException 的已有用户 message 保留；FILE_BUSY 提示稍候再试；FILE_CANCELLED 提示文件操作已取消并重新打开应用。其他平台、文件系统和格式异常按具体动作使用中文 fallback。原 error 和最多 8 层 stack 只进入诊断日志，不传入 SnackBar 文案。
- 主导入、主导出、历史备份导出和三种临时清理分支均使用同一映射。主动作与清理采用不同 action 前缀，清理失败不会伪称此前账本未改变；FILE_CANCELLED 文案为“文件操作已取消，请重新打开应用后再试。”，没有无依据的数据未变承诺。已成功恢复后的清理错误仍能单独报告。
- 所有展示检查 context.mounted；Owner 最后为调用方补充 mounted guard，已按上表最终 SHA 重新复核。上下文销毁后不向失效 UI 展示异常，存活界面的原异常只进入诊断日志。LedgerException 文案保留属于领域输入校验，不把所有失败都隐藏为一种原因。

## 有意义的回归证据

- 六项回归覆盖 reliable FILE_IO、取消、忙碌、文件读取、JSON 格式及领域校验错误。页面用真实隔离 SQLite repository，等待 ledgerProvider 就绪及按钮 enabled 后实际点击恢复；失败 picker 被调用后检查具体中文消息、没有原始 PlatformException/QA_RELIABLE_PIPE_FAILED/私有路径、没有恢复确认对话框或 Flutter 异常。
- 每项比较真实 repository 的修改 sequence、账单数和账户余额，确认导入前失败没有改变本机账本；此数据不变结论只适用于这些导入前失败测试，不延伸到成功导入后 cleanup 失败。
- 只读核对 `.qa/flutter-file-failure-after2.log`：六项具体回归实际执行，`+6: All tests passed!`。前一 `.qa/flutter-file-failure-after.log` 曾因测试未等待账本打开而未调用 picker；Owner 已修正等待条件。该前次失败不计为产品错误或通过证据。
- `.qa/flutter-file-failure-before.log` 为五项文案回归失败、领域文案一项通过；与 insets 测试的 theme import 编译失败不同，不能混用两者的先红证据。

未发现这三个冻结文件本次改动的确定 HIGH/MEDIUM。整体 UI/services 回归、analyzer、两端重建，以及原生 SAF reliable error/取消/缓存回收仍由 Root 和 Android Owner 执行。本报告不证明真实短信、Win10、Android 真机或全部软件验收通过。
