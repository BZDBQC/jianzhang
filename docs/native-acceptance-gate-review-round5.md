# 验收门槛独立审查：第五轮

日期：2026-10-05。范围：`scripts/check-native-acceptance.mjs`、`tests/native-acceptance.test.mjs`、`docs/native-acceptance.json`，重点为 R4 的 staticEvidence 与 cleanRounds 修复。结论：**Approve；本次范围内没有发现 CRITICAL/HIGH 或未解决的既有问题。** 产品的实际完整回归仍为 **0/3**，不因验证器获批而变化。

## 范围与检查

- 先检查 staged/unstaged diff；目标仍为未跟踪的新文件，以 NUL 新增 diff 建立范围。没有 PR 元数据，无法核验 PR 合并 readiness；本次为指定本地文件复审。
- `tsc --noEmit -p tsconfig.json`、`eslint . --ext .ts,.tsx,.js,.jsx` 通过。
- `node --test tests/native-acceptance.test.mjs`：2 项通过；其中包含四个静态 check 各自的旧候选、错误包 SHA、错误 sourceManifest SHA、错误证据 SHA 等 16 个拒绝变体。
- 实际 `docs/native-rounds.json` 继续被正确拒绝，`accepted: false, cleanRounds: 0`。

## R4 修复确认

静态检查现在必须引用 staticEvidence JSON：checkId、pass 状态、buildId 与当前轮次匹配；APK、EXE 的候选 SHA 与本轮摘要一致。两个 sourceManifest 的实际 realpath 必须与轮次记录相同，manifest 实际 SHA 必须匹配，manifest 的包 SHA 必须对应当前候选。每个摘要证据文件都需要被 artifacts 的实际路径和内容 SHA 覆盖。三轮可复用同一份已绑定候选的静态证据。

独立 fixture 复现确认：当前候选的完整绑定证据能通过；第一轮替换为 `previous-candidate` 静态证据后，四个静态 check 全部被拒绝，连续有效尾轮计数为 2。

cleanRounds 的全局条件新增 `textValue(last[0]?.buildId)`。独立 fixture 将轮次、静态审批、动态执行和性能样本的 buildId 全部设为空，排除其它元数据不一致的影响后，结果为 `accepted: false, cleanRounds: 0`，只有候选身份主校验失败。这确认 R4 的空标识问题已修复。

## 已保留的拒绝路径

固定配置类型、规范化配置 SHA 和三轮一致性；Windows/Android 分别必填的性能指标；原始 p95/长帧比例重算；动态 executionEvidence 的轮次、构建、时间、命令、退出码、checkIds 和实际 artifacts；跨轮同 check 的执行文件/日志内容复用；roundLog checks 与摘要一致；实际 APK/EXE SHA、独立非重叠轮次、计划内未覆盖项等校验仍保持。release/profile 混合指标的正例以及同指标跨轮改变模式的拒绝测试继续通过。

## 审查版本

- `scripts/check-native-acceptance.mjs` SHA-256：`66a4288ac41592ff3f9897f4ee14b82e3ce5c207d15e911ed51398cde5078097`
- `tests/native-acceptance.test.mjs` SHA-256：`385239c0b0d35c2f1ae08f2d6335909bb1d983a25f640bd9769a0c2cb3592a09`
- `docs/native-acceptance.json` SHA-256：`6275d35d3104245f4eda4d8f9e1c414f0f93a833f7ee8d00ed02f191471ed976`

## 边界

独立 fixture 摘要保存于 `.qa/native-gate-r5-review-repro.json`，明确标注 `fixtureOnly: true`，临时文件已安全清理；未修改源码、真实回归记录或交付安装包，未运行安装器、注册表探测或真实性能测试。本报告批准的是证据绑定和验收拒绝逻辑；实际构建来源由构建流程及其独立审查核验，真实三轮验收仍须使用双端实际测试证据。
