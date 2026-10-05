# 验收门槛独立审查：第三轮

日期：2026-10-05。范围：`scripts/check-native-acceptance.mjs`、`tests/native-acceptance.test.mjs`、`docs/native-acceptance.json`。结论：**Block，仍有一项 HIGH。** 产品的真实验收仍为 **0/3**，本报告没有运行安装器、注册表探测或真实性能测试。

## 范围与验证

- 先检查 staged、unstaged diff；目标为未跟踪的新文件，再以 `git diff --no-index -- NUL <file>` 确认完整新增代码范围。没有 PR 元数据，无法核验 PR 合并 readiness；这次是指定本地文件复审。
- 仓库没有专用 typecheck script；`tsc --noEmit -p tsconfig.json` 通过。规定的 `eslint . --ext .ts,.tsx,.js,.jsx` 通过。
- `node --test tests/native-acceptance.test.mjs`：2 项通过。实际 `docs/native-rounds.json` 被正确拒绝，`accepted: false, cleanRounds: 0`。
- R2 的配置类型、正安全整数 RAM/API、规范化配置 SHA-256、原始样本配置绑定和三轮配置一致性均已修复；重排 JSON 对象键不改变摘要。
- Windows 与 Android 的十万笔保存、筛选、滚动分别为必填指标，不能用 Windows 指标代替 Android。每个指标绑定 roundId/buildId/configurationSha256，允许 release/profile，并要求同一指标三轮模式相同。
- 原始样本最少 20 个，样本数、数值类型、p95、长帧比例和阈值重新计算；摘要不一致、重复轮号、重叠时间、缺失证据、APK/EXE 实际文件 SHA 不符、计划内未覆盖项目等仍会拒绝。干净 checkout 的 `.qa` 父目录创建问题已修复。

## HIGH：功能回归证据没有绑定每个执行轮次

位置：`scripts/check-native-acceptance.mjs:55`、`:83`。

`requiredChecks` 仅要求 `status === 'pass'` 且 evidence 文件存在、非空。独立 roundLog 只核对轮号、构建标识和起止时间，没有执行清单，也不绑定各 check 的证据。这样三轮可以重复引用同一份第一轮功能日志和截图，另写三份只有标识的 JSON，再提供各轮性能样本，便被接受为三轮完整回归。

复现使用独立、立即清理的 synthetic unit fixture，没有修改真实验收记录或生成交付安装包。所有 requiredChecks 都引用同一个明确写着 `roundId: 'repro-0'` 的 JSON 功能日志；第二、第三轮的 roundLog 没有 checks 字段，截图也共用第一轮文件。结果仍为 `accepted: true, cleanRounds: 3`。摘要保存在 `.qa/native-gate-r3-review-repro.json`，其中 `fixtureOnly: true`；它只证明拒绝路径缺口。

这会把一次功能回归当作三次，违反同一候选连续三轮完整回归的结束条件。配置和性能样本绑定不能弥补功能检查的执行身份缺失。

建议：每个动态检查引用结构化 executionEvidence，至少绑定 roundId、buildId、checkIds、执行命令、成功 exitCode、轮内起止时间和 artifacts；轮执行日志逐项绑定这些引用、原始指标证据和安装包哈希。动态证据不得跨轮复用同一 realpath 或同一内容 SHA；同一轮内一条测试命令可以覆盖多个 check。可复用的独立审查和 APK 16 KB 静态检查应在合同中明确列为 staticChecks，并绑定当前候选。

必须补的负例：

1. 第一轮完整功能记录被第二、第三轮复用，即使性能样本独立也拒绝。
2. 把第一轮记录复制成新文件，内容和 roundId 不变，仍拒绝。
3. 缺失 executionEvidence、checkIds 不包含声明检查、exitCode 非零、时间在轮外或构建标识不符，均拒绝。
4. roundLog 的 check 引用、原始指标引用或安装包哈希与摘要不同，拒绝。
5. 正例保留同轮多 check 共用一个有效执行记录，以及合同明确许可的静态检查复用。

## MEDIUM：cleanRounds 返回的是末尾记录数量

位置：`scripts/check-native-acceptance.mjs:95`。

当前直接返回 `last.length`。在上述 fixture 中将三轮 defects 都设为已知回归后，结果正确拒绝，但仍显示 `cleanRounds: 3`。三个 null 轮次也存在同样语义问题。

建议返回经过全部该轮校验的连续有效尾轮数，失败轮次清零；补失败末轮为 0、只有最后一轮有效为 1、最后两轮有效为 2 的测试。该字段不应暗示失败记录已经满足干净轮次条件。

## 结论边界

R2 固定配置问题已解决，当前真实性不足的报告仍不得用于结束循环。修复本轮 HIGH 后需要再次独立复审。这里的合成正例只验证验证器行为，不能替代实际双端安装、功能、视觉或性能验收。
