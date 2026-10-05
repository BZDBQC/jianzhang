# 原生迭代独立复审，第十二轮总期限修复

结论：**APPROVE — R12c 的总 deadline 阻断解除。** 真实等待 helper 在 Stop 后检查最终 elapsed，迟到句柄被拒绝。旧 blocked 报告与红证据保留；实际二十次 release 冷启动仍需运行证据。

## 冻结范围

输入 `.qa/windows-startup-deadline-r12c-freeze.json`。

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/measure-windows-startup.ps1` | `d5857e44d94b4dc321e868734a4ba20bd2c3af88a6762ddafffe037cca425936` |
| `tests/native-qa/windows-startup-isolation-fixtures.ps1` | `624c3fad110ebddc51084f3a1f0042be2d63d8a43ac7b8d65d9d93e4f6121a2f` |
| `docs/native-startup-isolation.md` | `4d36bdfd65a6163378f6f41d0cd57e8cb6a3aa442ca5b74c5b325c5a5fda2e87` |

读取 staged/unstaged diff、实际修复和新负测。独立从新脚本删除唯一新增的三行最终期限判断后，UTF-8 字节 SHA 精确恢复旧 `4c006b3d49aa3c0fc98d32195a339cdd640440799dbcb55d62afdaa681d146a2`。因此只新增最终判断，原 Normal/控制台配置、采样阈值、渲染后可见窗口计时、关闭/SQL 后接受样本、清理/故障诊断与完整来源/payload/hash guard 均未变。原四个生产 Dart 文件 SHA 匹配原批准值，无生产代码或新二进制变动。

## 独立验证

独立执行目标 fixture **17/17 组、exit 0**，含保留的真实 readiness AST **18/18**。新增 delayed Refresh 测试实际调用 helper，确认已观察迟到的非零句柄，随后拒绝；正常窗口、NeverVisible、Exited、停止时钟、StartInfo.Normal 与原路径/SQL 等分支继续通过。

- `.qa/windows-startup-deadline-independent-r12d.log`
- `.qa/startup-isolation-pure-9d6d9508eb204af794b30a89756f834e/evidence.json`
- 同目录 `late-refresh-deadline.json` 与 `readiness-cases.json`

另独立重复 R12c 原负例：真实 AST 提取的 `Wait-StartupMainWindow`，fake Process.Refresh 延迟 60 ms、TimeoutMs 20。观察句柄 123、Refresh 一次，最终 elapsed **90.2344 ms**，**accepted=false**，抛出总 deadline 错误且 clock 已停止。原先同类负例 accepted=true 的问题消除。

证据 `.qa/windows-startup-visible-deadline-independent-r12d.json`，绑定当前 helper SHA。最小增量复原与两份 Parser **0 错误**记录于 `.qa/windows-startup-deadline-minimal-parser-independent-r12d.json`。脚本冻结 SHA 在目标测试前后保持一致；最终同时核对生产四文件、新两脚本和作者文档。

作者 RED/GREEN 资料 `.qa/windows-startup-deadline-before-r12c.log` / `.qa/windows-startup-deadline-after-r12c.log` 与真实 helper 负测相符；批准以本轮独立执行为准。此前 R12c cleanup 与 diagnostic 原异常保留的两项独立故障测试所对应 Try/Finally 代码未变，因此沿用该证据。

## 验证边界

本轮只运行轻量纯 fixture，没有启动实际客户端、ADB、安装器或访问注册表。批准允许执行正式采样，不意味着 Windows 冷启动 p95 或完整安装验收通过。Windows 10、Android 真机、真实短信及当前候选三轮完整回归边界保持不变。旧 `native-iteration-review-round12c.md` 和其红证据原样保留。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **APPROVE — 本冻结范围没有未解决审查问题，R12c 总 deadline 阻断解除。** 实际性能结论由独立完整运行决定。
