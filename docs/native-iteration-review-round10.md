# 第 10 轮独立增量审查

结论：**APPROVE（以下冻结发布修复及 Windows QA 键盘增量）**。没有发现置信度超过 80% 的未解决代码问题。审查者未改生产或作者测试；只独立运行文件 fixture，没有执行构建、安装器、注册表、ADB 或真实窗口。

## 冻结来源

| 文件 | SHA-256 |
| --- | --- |
| `scripts/package-windows-client.ps1` | `94689d0a6a04a89feaaa2e613519b6cce80fdbcfba7309651c994a25103db7f7` |
| `scripts/native-toolchain/test-package-publication.ps1` | `59e77070241ba899e85d88246c0fffc48fd01351b4652d1ac54045ab9a3cfd19` |
| `scripts/native-toolchain/verify-packaging.ps1` | `05a2ff079d0b2a036545ba96db56702efb53fa69d0ead4a1a62a717563c2cc31` |
| `clients/flutter/integration_test/native_windows_adaptation_test.dart` | `7fc7d7d4ea025ffe596f09f2345251571d97fb58f8485421a04d86231b9cdcc1` |

## 发布修复与独立证据

原 `[IO.File]::Replace($candidate,$Output,$null)` 在本机 PowerShell 7.6.5/.NET 10.0.11 将普通 null 绑定为空字符串，导致 path is empty。最小复现保留在 `.qa/replace-null-repro-6d738644c8c44f529ff5f93a589df0ff/evidence.json`：普通 null 失败，旧输出与候选保留；`[NullString]::Value` 成功。原完整打包失败只有工具输出 chunk `8364f9` / session `29688`，没有可引用的本地日志；这里不引用不存在的构建文件。

生产变化仅将该 backup 参数改为真正的 null 哨兵，保留原子 Replace；首次发布仍使用 Move。发布前后 candidate/output SHA、全部源与 payload guard、manifest 生成顺序、过程环境恢复均保持。未修改 C# 安装事务。

新测试从生产脚本 AST 提取实际发布 statement，限制全新 `.qa` 目录、拒绝已有目录与祖先 reparse，全部生成文件属于该 fixture。锁句柄及只读属性在 finally 恢复；没有执行 NSIS 或安装。集成的 verify-packaging 调用该测试，失败会传播，未跳过既有检查。

独立执行 **10/10，退出 0**：首次发布、两次覆盖、输出锁、候选锁、只读输出、候选缺失，以及解除三种限制后重试。拒绝时旧 EXE 与已有 sidecar bytes 保持；除明确删除的 missing-candidate 场景外候选也保持。成功时 staged candidate 消耗、没有多余 backup 文件。三个发布源 SHA 在独立执行开始/结束一致。

独立证据：`.qa/package-publication-independent-r10-0cac3f0452a146248be12695fd27fb3e/evidence.json`。这是实际 statement 的文件级验证，sidecar 不变是验证其尚未被发布 statement 改写；不把它当作完整 EXE+manifest 打包或安装验收。另核对作者最终两轮 10/10 日志、三份 PowerShell AST 无错误。

Windows PowerShell 5.1 的 AllSigned 策略拒绝未签名测试，见 `.qa/package-publication-windows-powershell51.log`；未绕过策略、不计作该 shell 通过。

## Windows 键盘增量

原真实 profile drive 的失败保留在 `.qa/native-windows-adaptation-drive-r9.log` 和 `.tools/temp/jianzhang-windows-qa/run-6677864d/evidence.json`。其中首个 640×520 外框对应 native client/Flutter physical 624×479，DPI 106 与 DPR 一致，原尺寸恢复成功；键盘模拟在 SDK `_findPhysicalKey` 空值失败，报告 `passed:false`，不是一轮成功回归。

新源的全部 5 个 sendKeyDown/Event/Up 调用显式传入 PhysicalKeyboardKey 和 `platform:'windows'`；Escape、ControlLeft、N、F 的映射正确，ControlUp 的 finally 保持。官方本地 SDK 的 keyData 和 raw-key 路径在 physicalKey 非空时跳过依赖 debugName 的推断，后续 Windows scan/key code 使用数值 HID/keyId。仍通过 Flutter 硬件键事件、实际点击与可见表单断言验证，未用直接调用页面函数代替。

纯源校验记录：`.qa/package-publication-independent-r10-0cac3f0452a146248be12695fd27fb3e/keyboard-source-evidence.json`。作者 targeted analyze No issues 日志：`.qa/native-windows-adaptation-key-fix-analyze.log`。原 x64 FFI ABI、当前 DPI/尺寸收敛、独有仓库/PNG 证据、失败传播和 finally 恢复控制流保持；本轮未运行修复后的原生 drive。font 1.6 与多种系统 DPI 仍不属于该测试已验证内容。

## Review Summary

| Severity | Count | Status |
| --- | --- | --- |
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: **APPROVE — 冻结增量范围无已知未解决问题。完整打包/安装及新 Windows 原生 drive 仍待实际复测；Windows 10 实机、Android 真机、真实短信与三轮完整验收边界保持。**
