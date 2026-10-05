# 第 11 轮分范围独立审查

结论：**APPROVE（冻结 Escape 修复、SAF QA 调整和发布诊断增量）**。未发现置信度超过 80% 的未解决新增代码问题。审查者只读作者源，独立执行目标 Flutter 测试、纯脚本 fixture 和自有文件 fixture；没有运行原生 drive、ADB、安装器、注册表或完整构建。

## 冻结来源

| 文件 | SHA-256 |
| --- | --- |
| `clients/flutter/lib/ui/entry_form.dart` | `c33e6f0e2708aaab2a9284f7fa1da2de1170572c7527cc72e1ab86ff772c8edc` |
| `clients/flutter/test/ui/entry_keyboard_test.dart` | `6ec0fbe05f3f8d90fd2c8b11555e09e439f290b861be129fdef5f6c173623851` |
| `scripts/native-toolchain/test-android-saf.ps1` | `204fffef28340a6233672db9123531c52ba68fdbd57b33ca7550daf46b44b7e0` |
| `tests/native-qa/android-saf-script-fixtures.ps1` | `d4b9b818ae1bb75df308ee29c1e6454dad918f63d09fb62def17738d8102590d` |
| `scripts/package-windows-client.ps1` | `ba001f55bcc5af434914f1ba8a8e5fa235a600f4f7433beb4c68ff815e019cd0` |
| `scripts/native-toolchain/test-package-publication.ps1` | `440849df00afea15481ceeff04207b65df51f336b458916f3b801f8577404734` |
| `scripts/native-toolchain/verify-packaging.ps1` | `05a2ff079d0b2a036545ba96db56702efb53fa69d0ead4a1a62a717563c2cc31` |

## 1. 生产 Escape 修复

核对 Git diff、完整相关表单保存/取消/PopScope 逻辑及官方本地 Flutter SDK routes。SDK `_DismissModalAction.isEnabled` 受 `barrierDismissible` 控制；原记账对话框设置 false，默认 Escape 不会关闭。新 `CallbackShortcuts` 仅在记账 dialog 内处理 Escape，以该 dialogContext 调用 `Navigator.maybePop`，不会直接调用仓库或改变保存流程。原外部点击保护继续为 false；`EntryForm` 的 `PopScope(canPop: !_saving)`、保存防重、保存后关闭及失败保留输入保持。

独立执行 `flutter test --no-pub test/ui/entry_keyboard_test.dart --reporter expanded`：**3/3，退出 0**，生产/测试 SHA 开始与结束一致。565/1100 两种宽度验证填入草稿后外部点击不关闭、主动 Escape 关闭且笔数/sequence 不变；延迟数据库保存验证 Escape 不关闭、输入保持、零提前提交，释放后只保存一次且金额/备注正确。日志：`.qa/flutter-entry-keyboard-independent-r11.log`。

额外自有 ignored `.qa` fixture 验证保存点击后尚未刷新下一帧的 Escape 边界：**1/1**，没有复现保存中关闭。日志：`.qa/flutter-entry-keyboard-same-frame-independent-r11-after-fixture-fix.log`。该自有 fixture 首次存在 import 的 escape 名称歧义，早期日志只是编译失败，不作为业务 Red。

作者 `.qa/flutter-entry-keyboard-before.log` 同样是属性名编译失败；真正业务 Red 是 `.qa/flutter-entry-keyboard-before2.log` 两个闲时用例失败、保存中用例通过。后续去掉冗余默认账户点击后的 `.qa/flutter-entry-keyboard-after.log` 为 3/3 无命中警告。此生产修改需要重新构建两端并跑实际键盘回归，本地目标测试不能代替原生验收。

## 2. SAF QA 搜索与临时文件调整

增量把 XML、截图、SQLite/WAL/SHM 副本移至 UUID `/data/local/tmp/jianzhang-saf-*`；仅意图导入的合法 JSON 留在 Downloads，不再用测试碎片把文件挤出可视区域。chmod 0644 仅作用于刚创建的 `$remote` SQL 副本，不作用于私有 `$source` 数据库。清理仍只移除 remoteFiles 列表中的自有文件。

系统 Search 的输入仅接受指定 UUID basename，编辑框必须唯一；结果要求 exact case-sensitive text、文档 title resource-id、enabled，排除同名 EditText，重复匹配或空结果都在有限次数后失败。没有按列表顺序猜测或把搜索输入当文件。

独立执行纯 fixture：**8/8，退出 0**，helper/test SHA 前后一致。证据：`.qa/android-saf-pure-fixtures-4a3edbdea552457b9d2d28d99d698038/result.json`。覆盖临时目录、exact 查询/旧查询清空、同名 query 编辑框和 suffix 错文件拒绝、超时、歧义、非法 basename 先拒绝、实际 APK/fixture/manifest guard 变更失败及合法预览/取消断言保留。fixture 只加载提取函数并使用假的 Adb，未调用真实可执行文件。

只读全表 SQLite 摘要、共享 fixture 笔数预览、主动取消后 cache 清理与 9 表 SQL 不变、fault 拒绝、返回前实际 cache 存在、严格 5 秒且早于 provider 30 秒、release/provider/installed APK 及 source 前后守卫保持。纯 fixture 只验证这些检查的保留与匹配逻辑，不代表真实合法文件、可靠错误管道或停滞取消已经通过；真实 SAF 仍需独占设备实测。

## 3. 发布诊断增量

两个新函数只在原文件发布点采集 candidate/output/旧 manifest 的前后状态，实际发布仍为单次原子 Move/Replace。新增诊断在本次唯一 generated 目录写入 before/failure JSON；无法写入 before 时不尝试发布。文件锁导致 SHA 无法读取时记录真实 readError 和 null SHA，不补造 hash。

失败记录完整异常链、类型、HResult、仅 HRESULT_FROM_WIN32 的原生 code、原始 ToString、stack/position 及文件 attrs/bytes 信息，然后重抛原 ErrorRecord。诊断二次写入失败只提示该诊断失败并保持原发布异常；没有盲重试、删除旧 EXE fallback、C# 或安装事务改动。发布后的 SHA 与源/payload 守卫保持。

独立文件 fixture：**11/11，退出 0**，三个源 SHA 前后一致、三个 PowerShell parser 无错误。证据：`.qa/package-diagnostics-independent-r11-f558d607ebec424f81493988ca4e55b4/evidence.json`。覆盖首次/两次替换、输出锁/候选锁/只读/缺失的真实异常 code 32/32/5/2 和原异常/旧 EXE/旧 manifest 保留、三次解除限制后重试、诊断存储不可用时三份原文件保持。输出锁的 before SHA 实测 null 且有 IOException readError，全部失败记录 retryAttempted=false。

这项批准针对诊断和错误保持，**原实际 Win32 1175 发布失败仍未归因或解决**。采用新输出名称继续交付测试不证明旧目标覆盖问题消失，完整实际打包与安装验收仍未完成。PowerShell 5.1 的既有 AllSigned 阻断没有绕过，也没有新增通过结论。

## Review Summary

| Severity | Count | Status |
| --- | --- | --- |
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: **APPROVE — 冻结新增代码范围无已知未解决问题；双端重建、真实 SAF/键盘/完整安装回归、1175 归因与三轮完整验收仍待完成。Windows 10 实机、Android 真机、真实短信边界保持。**
