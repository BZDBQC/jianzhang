# 验收门槛独立审查：第二轮

日期：2026-10-05。范围为重写后的 `scripts/check-native-acceptance.mjs`、`tests/native-acceptance.test.mjs`、Unicode 样本生成脚本；未重复审查已经批准的 native 后端，也未运行 Flutter 或修改产品代码。

结论：**Block，仅针对验收门槛的固定配置校验；Unicode 生成脚本未发现 CRITICAL/HIGH。** 真实软件验收仍为 **0/3**，此报告不改变候选版本状态，也不代表云接口已发布。

## 已确认的修复与验证

- 本地 staged/unstaged 范围与未跟踪新增文件已核对；没有 PR 元数据可核验合并 readiness。
- `tsc --noEmit -p tsconfig.json`、规定的 `eslint . --ext .ts,.tsx,.js,.jsx` 均通过。
- `node --test tests/native-acceptance.test.mjs`：2 项通过，0 失败。合成 APK、EXE、日志和截图仅测试验证器结构，不能计入软件交付证据。
- 先前的重复轮次、缺失/空证据、非整数样本数、摘要不一致、实际文件哈希不符、计划内未覆盖项等场景现在会拒绝。
- 轮次要求独立 roundId、非重叠时间、独立 JSON 执行日志；性能原始文件绑定 metric、roundId、buildId、mode，样本数至少 20，并重算 p95 或大于 50 ms 的帧比例。
- 路径通过 realpath 限制在工作区，要求真实非空文件；APK/EXE 的 SHA-256 与实际文件核对，并要求三轮包哈希相同。
- 当前 `docs/native-rounds.json` 被正确拒绝，报告 `accepted: false, cleanRounds: 0`。

## 必须修复：HIGH

### 固定配置字段类型和三轮一致性尚未验证

位置：`scripts/check-native-acceptance.mjs:53`、`:54`、`:60`。

两种复现均基于测试脚本的有效合成报告，在内存中插入变体，没有修改真实验收记录：

1. 将配置改成 `windows.os = 42`、`windows.cpu = []`、`windows.ramMB = "not-measured"`，以及 `android.avd = []`、`android.api = "unavailable"`、`android.ramMB = "not-measured"`，仍得到 `accepted: true`。
2. 第二轮换用不同 CPU、RAM 和 Android API 37 的配置文件，第一、第三轮仍使用 API 26 的原配置，同样得到 `accepted: true`。

当前字段仅以 truthy 检查，原始性能样本没有配置绑定，三轮也未比较配置。这不能保证计划所要求的固定环境实测，可能把不同硬件/模拟器结果视为同一条件下的三轮验收。

建议：校验明确的非空字符串、正安全整数 RAM/API 等类型；固定配置规范化后要求三轮相同；原始指标记录绑定该配置摘要，并补异常字段、不同配置及错误配置绑定的拒绝测试。固定环境校验完成前，门槛不可用于结束优化循环。

## 其他问题：MEDIUM

### 测试依赖忽略目录预先存在

位置：`tests/native-acceptance.test.mjs:13`。

`fs.mkdtempSync` 使用 `.qa` 下的前缀，却没有先创建 `.qa`。该目录没有版本管理，干净 checkout 上直接运行测试会因父目录不存在而 ENOENT。建议在 fixture 创建前用 `fs.mkdirSync(..., {recursive: true})` 初始化父目录。当前工作区已有 `.qa`，因此这次两项通过仍然有效。

## Unicode 生成脚本

- `process.versions.unicode === "17.0"` 的约束在任何输出前检查；用 16.0 的模拟运行被明确拒绝。
- 通过只读 VM 捕获写入，完整扫描两次 Unicode 码点，生成结果相同；未覆盖实际产品文件。
- JSON 样本与现有文件逐字节相同；Dart 输出的三段常量字符串与现有文件语义完全一致，文本差异仅为 Dart formatter 的缩进。
- 单码点全量小写映射、Cased/Case_Ignorable 属性范围按码点稳定排序，U+0130 扩展和 Final_Sigma 样本保留。Dart 上下文转换算法的功能回归由其他审查/测试负责。
- 脚本按工作区根目录作为 cwd 运行；生成后仍需执行常规 Dart 格式化。

## 边界

本轮只确认验证器和生成脚本的结构、拒绝路径与确定性；没有产生三轮真实验收结果，没有安装包性能测量，也没有改变 native 后端的既有批准状态。
