# 原生迭代独立复审，第十二轮补审

结论：**APPROVE — 冷启动 QA 脚本的 readiness 拒绝条件阻断已解除。** 新增括号修复了原 Int32 分支问题；独立目标 fixture 10/10 组（含真实 AST 18/18 场景）及独立附加 5/5 组均通过。这个结论不包含实际 EXE 冷启动性能或完整安装验收。

原 `docs/native-iteration-review-round12.md` 和原红证据保持原样，记录当时的阻断。本报告仅批准下面的新冻结范围。

## 冻结与最小改动

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/measure-windows-startup.ps1` | `d037ed1fa9815df153bb73cfae4a2a401c937466fa8610bf1e9842e556b0de7f` |
| `tests/native-qa/windows-startup-isolation-fixtures.ps1` | `16b5e6c8e65f87dfd3c4b07cea4223be701238a9a2e933216637e0d47756ed4a` |
| `docs/native-startup-isolation.md` | `b714ca31b409acda722c1f692d9d2576bbee6c524ba397173961f4f14e0a2a90` |

输入清单为 `.qa/windows-startup-readiness-r12-freeze.json`。独立读取 staged/unstaged diff、完整脚本、新增真实 AST 测试和文档；测试前后与报告落盘前的 SHA 均匹配。原批准的四个生产 Dart 文件 SHA 也保持原值，没有新生产行为或新发布二进制改动，因此沿用 R12 的 10/10 独立 Dart 测试与 analyzer 结论，不重复无关测试。

独立将新脚本中的唯一类型子句

```powershell
($ready.readyMs -isnot [long] -and $ready.readyMs -isnot [int])
```

去除这两个括号后，按原 UTF-8 字节重新计算 SHA，恰好恢复 R12 旧脚本的 `65fb5cac12fc9ea0c0256452f77cc9a52cf5f9e1606d02f96fa75c7dbaea0483`。这证明 helper 的增量只有这两个括号；采样数量、阈值、渲染/SQL 路径、计时和 payload/source guard 没有变化。两份 PS 文件 Parser 均为 0 错误。

证据：`.qa/windows-startup-minimal-fix-parser-independent-r12b.json`。

## 拒绝条件独立复测

独立执行冻结的 `tests/native-qa/windows-startup-isolation-fixtures.ps1`，**10/10 组、exit 0**。保留原九组的真实自有 junction、独立空样本、重复拒绝、路径归属和实际只读 SQL 校验。负向 Python traceback 为预期拒绝，不是被忽略的测试失败。

新测试直接从 helper 的真实 `IfStatementAst` 取条件，构造带显式参数的 scriptblock 执行，未复制或替换拒绝表达式。新增 **18/18 场景、failedCases=0**：Int32/Int64 下缺选择、false/缺失 renderer、合法 12 与 0；缺 ready；负数、浮点与字符串时间；当前真实 JSON parser 的正反例。原报告中的两个 Int32 假接受以及作者补充的缺 renderer 场景均拒绝。

- 独立执行日志：`.qa/windows-startup-readiness-independent-r12b.log`
- 独立组级结果：`.qa/startup-isolation-pure-a917dc83f9104d4980eb15e6c26ef81d/evidence.json`
- 独立原条件与十八场景结果：`.qa/startup-isolation-pure-a917dc83f9104d4980eb15e6c26ef81d/readiness-cases.json`

作者的 before 日志及三失败原 AST 结果是先于修复的业务红证据，不是编译错误：`.qa/windows-startup-readiness-ast-before.log` / `.qa/startup-isolation-pure-f32cf14fe81d4b6eb6da50958fda3e50/readiness-cases.json`。作者 after 日志 10 组通过；批准以本轮独立运行作为证据。

## 独立附加检查：5/5 组

自有 `.qa/windows-startup-review-r12b.ps1` 复用原独立检查脚本，仅更新目标冻结 SHA。原脚本曾在真实 readiness 负例处停止；这次所有五组完整运行：

1. 实际数据库选择 IfStatement 条件，正确及大小写等价路径接受，八个错误/缺失身份字段拒绝，共 10 场景。
2. 实际 readiness 条件，Int32/Int64 接受，缺 selection/ready/frame、负数、非整数和缺失时间拒绝，共 10 场景。
3. 按实际源码/AST 顺序确认 fixture 建立、ArgumentList 组装先于 Stopwatch；Stopwatch 先于 Process.Start；elapsed 在渲染 ready 后、关闭和 SQL 前取值。Count 默认 20、范围 20..100，二十样本 p95 使用第十九个排序值。
4. 完整 payload 的实际 AST 调用在采样前后各一次；EXE、payload/build manifest 和客户端来源的后置 guard 保留。异常清理仍只操作当前建立的子进程并 Dispose。该组证明代码合同保留，没有运行真实 payload guard 或发布程序。
5. 通过实际 helper 创建二十个自有样本目录，含中文、空格、`#`、`%` 的假 EXE 路径。每个 DB 路径唯一且未创建，目录仅有绑定正确索引、EXE/DB 路径和零笔声明的 marker。假 EXE 只是文本 fixture，从未执行。

日志：`.qa/windows-startup-review-independent-extra-r12b.log`。结果：`.qa/startup-review-independent-bb618e751116499697f352b2bc925329/evidence.json`，记录 `productionExeLaunched=false`、`payloadRuntimeVerified=false`。

报告落盘前再次确认四个生产 SHA、三个新冻结 SHA，以及原 blocked 文档 SHA `1eba8fb1bf9f5b55b590ea65737e3fe77341e06970b9f985a3403c7acc177a7e` 和原红证据 SHA `8eb0b553380b09562fb30b127fa6b32f77afd74c8e4d049d2171bfbfb33b8c60` 均未变化。

## 验证边界

本轮未启动真实 EXE、运行 ADB、访问/修改注册表或系统 KnownFolders。实际二十样本 release 冷启动、完整安装验收及当前候选双端完整回归仍须有各自运行证据；本轮不能计作干净回归轮次。Windows 10、Android 真机和真实短信仍未验收。原 Win32 1175 包发布问题未由这个括号修复归因或解决。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **APPROVE — 本冻结范围没有未解决审查问题；R12 readiness 阻断解除。** 实际运行和性能验收保持独立、未通过状态，不能由 fixture 或 Parser 成功代替。
