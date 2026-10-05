# 第 15 轮独立审查：正式验收拒绝诊断指标

结论：**APPROVE**。本次两文件变更未发现 CRITICAL、HIGH 或 MEDIUM 问题。

审查范围为本地未暂存改动，已先检查 staged/unstaged diff，并以 `d3a3665` 对照确认仅新增 1 行门禁、17 行测试。本任务不涉及 PR，未核验远端合并状态。

- `scripts/check-native-acceptance.mjs` SHA-256：`eac807429386752ef24cfef57e0db6111657a0d73c62b36172ba7ef165d45ee9`
- `tests/native-acceptance.test.mjs` SHA-256：`adf227e2410dadc465ff1d24a04ce37e2f2a7b4dba34404b9b904c8cf715c366`

已阅读两文件的周边实现、原始样本验证、统计计算和轮次计数逻辑。门禁在原始数据基础校验后，对 `diagnosticRun` 存在且不严格等于 `false` 的情况记录失败，并跳过该项指标后续计算。未提供字段的旧 JSON 继续兼容；显式 `false` 继续接受；`true`、字符串 `'false'`、`null`、`1` 拒绝。独立探针进一步确认 `0`、空字符串、数组及对象也拒绝，没有真假值隐式转换带来的绕过。

代码未写入、删除或重命名证据。独立探针对所有 8 个指标逐项设置诊断标记，核对中文失败原因和文件 SHA-256 前后一致；在第 1、2、3 轮分别触发失败时，末尾干净轮次分别为 2、1、0。完整验收均拒绝，没有把失败轮算作三个干净轮。

p95 和长帧比例计算未变更。除原有重算和阈值回归外，独立探针用 20 个不同样本 `0..19` 验证 p95 为 `18`，同一构建三轮仍接受。原有不含诊断字段的正例及所有轮、所有指标显式 `false` 的正例均通过。

## 独立验证

变更仅为 `.mjs`，项目未提供 typecheck 命令，现有 `tsconfig.json` 不包含这两文件，因此不运行无关 TypeScript 编译。已先执行可用的全仓 ESLint，再执行纯 Node 测试。

- `node node_modules/eslint/bin/eslint.js . --ext .ts,.tsx,.js,.jsx`：exit 0，无诊断。
- `node --test tests/native-acceptance.test.mjs`：2/2 通过。
- 自有 QA 副本中运行附加诊断、证据保留、轮次计数及非恒定 p95 探针：2/2 通过，附加断言全部通过。
- 已核对作者保存的 RED/GREEN：旧门禁接受诊断 `true`，修复后拒绝。原始日志未改写。

独立日志及纯测试副本位于 `.qa/native-phase-gate-review-r15-3abea2680a31468d9aa1ed33456788a9`，原测试文件与门禁在审查结束时 SHA-256 与开审值相同。

本审查不涵盖 Flutter 性能 harness、安装登记、ADB、应用构建或设备性能，也不构成三轮完整客户端回归通过的证据。未修改源代码或他人文档。
