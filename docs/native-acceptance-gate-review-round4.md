# 验收门槛独立审查：第四轮

日期：2026-10-05。范围：`scripts/check-native-acceptance.mjs`、`tests/native-acceptance.test.mjs`、`docs/native-acceptance.json`。结论：**Block，静态证据仍未绑定当前候选。** 本轮未修改源码，真实产品验收仍为 **0/3**。

## 已修复与验证

- 先检查 staged/unstaged diff，目标仍为未跟踪的新文件，以 NUL 新增 diff 建立完整代码范围；没有 PR 元数据可核验合并 readiness。
- `tsc --noEmit -p tsconfig.json` 与 `eslint . --ext .ts,.tsx,.js,.jsx` 均通过；`node --test tests/native-acceptance.test.mjs` 为 2 项通过。
- 实际 `docs/native-rounds.json` 被正确拒绝，`accepted: false, cleanRounds: 0`。
- R3 的动态功能证据缺口已修复：每个动态 check 需要 executionEvidence，校验本轮 roundId/buildId、checkIds、非空 command、pass/exitCode 0、轮内执行时间、实际日志和 artifacts。摘要 check.evidence 必须含日志且每个文件都属于该执行记录。
- 跨轮同 check 的执行文件 realpath 或日志 SHA 重复会拒绝；同轮多个 check 共用一个执行记录被允许。相同截图像素不作为日志去重依据。
- roundLog 的完整 checks 清单必须与轮次摘要逐项一致。新增测试覆盖旧轮执行引用、错轮号、错构建、失败 exitCode、空 checkIds、空命令、无效结束时间，以及换文件名但相同日志内容。
- cleanRounds 现在按连续有效尾轮计算：三个带 defects 的轮次返回 0；第一轮失败而末尾两轮有效返回 2。R2 配置绑定、双平台分别测量、原始样本重算、安装包实际 SHA 等校验仍保持。

## HIGH：可复用的静态证据没有候选身份校验

位置：`scripts/check-native-acceptance.mjs:60`。

合同将三个独立审查和 APK 16 KB 检查列为 staticChecks，允许三轮复用是合理的。但实现只验证 evidence 文件非空，随后直接 continue；没有校验该审查/检查针对哪个候选、源码或安装包。这是 R3 建议中“静态检查必须绑定当前候选”仍缺失的部分。

实际复现：建立一份明确写着 `buildId: 'previous-candidate'`、旧 source/apk SHA 的静态证据 JSON；三个轮次都用当前 `buildId: 'current-candidate'` 和当前 APK/EXE 实际哈希，其余动态执行与性能证据正确绑定各轮。结果仍为 `accepted: true, cleanRounds: 3`。因此代码或 APK 更新后，旧独立审查和旧 16 KB 检查仍可被作为新候选的通过证据。

建议增加候选绑定的 staticEvidence manifest：校验当前 buildId、当前安装包哈希；代码审查还应绑定经核验的源码/构建来源摘要，证据列表和实际文件摘要一致。三轮可复用同一份已绑定当前候选的 manifest；这不要求重复进行静态审查。

补拒绝测试：旧 buildId、错误 APK/EXE 哈希、错误源码身份、缺失静态 manifest、证据文件内容变化；同时保留同一候选三轮复用有效静态 manifest 的正例。

## MEDIUM：空构建标识仍显示三轮干净

位置：`scripts/check-native-acceptance.mjs:119`。

连续尾轮计数的全局条件只要求 buildId 的 Set 大小为 1，没有重复验证非空字符串。把三轮及执行/性能元数据的 buildId 全设为空字符串后，主结论正确拒绝，失败原因是“三轮并非同一构建”，但 `cleanRounds` 仍返回 3。

建议让尾轮计数使用与候选身份主校验相同的有效 buildId 条件。补空字符串或其他无效构建标识返回 cleanRounds 0 的测试。

## 复现证据与边界

上述两种情况使用自建 synthetic fixture，临时文件已安全清理；结果保存在 `.qa/native-gate-r4-review-repro.json`，明确标注 `fixtureOnly: true`。没有产生可交付安装包，没有改动真实回归记录，没有运行注册表探测或安装器。这些结果只说明验收验证器尚有拒绝路径缺口。
