# 第 17 轮独立审查：安装日志发布重试与正式验收门禁

结论：**APPROVE**。指定四文件的本轮改动及已保存测试证据未发现 CRITICAL、HIGH 或 MEDIUM 问题。完整安装脚本仍由执行者验证；这些开发结果不计入正式三轮回归。

先检查本地 staged/unstaged diff，范围限定为两个 C# 文件和两个 `.mjs` 文件；未审查同时进行的 Flutter 修改。本次不是 PR 审查，没有远端合并 readiness 信息。

## 安装器

已读新增 publication helper、两个调用点、周边路径校验、测试注入边界和新增测试。当前两份 C# 源码的 SHA 与已有独立 C# specialist APPROVE 完全一致，原始备份身份与 checkpoint 一致。

- 在循环前固定 Replace/Move 选择；初次 Move 只尝试一次。替换最多五次，仅实际 Replace 操作、Win32 HRESULT facility `0x8007`、错误 32/33/1175、两个原路径仍存在时可以重试。四次等待为 40/80/160/320 ms，总计 600 ms。
- 每次尝试重新检查父目录以及文件的链接/目录属性。1176、1177、权限错误、磁盘不足和未知 HRESULT facility 立即失败；路径缺失也停止，不改用 Move，不删除旧日志，不更改权限。
- 已完整写入并 Flush(true) 的暂存日志在发布前完成。失败信息保留实际 operation/source/target、次数、原 HRESULT/native code，并以原异常作为 InnerException。QA 诊断写入失败停止重试，保留原异常及单独的诊断错误；日志追加逻辑仅在现有 INSTALLER_QA 条件中，生产 helper 不增加诊断写入。

允许重试 1175、拒绝 1176/1177 的区别与官方文件替换语义相符：1175 保留双方原文件名；后两者可能已有名称或文件状态变化。[Microsoft ReplaceFileW 文档](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew)。

核对的执行者实际证据均位于 `.qa/installer-journal-r17-b64fe53533234b21bf13fe08b2d043f5/`：原始 RED 记录 21 项失败；最终 focused 日志 23/23 通过，含真实共享锁释放/持久占用和只读日志；诊断日志 2/2 通过，含二次诊断失败保留原异常。`focused-final-evidence-r17.json` 的源码 SHA 与当前文件一致。完整 `.qa/installer-journal-r17-full-regression.log` 记录 179 项文件测试、13 项打包检查通过，并声明无注册表访问、无安装执行。以上执行结果由执行者生成，本次复审没有重新运行 C# 编译或这些二进制。

## 验收门禁

本轮改动仅新增 `diagnosticRun` 的严格判断及 17 行测试。原始指标基础校验通过后，字段存在且不严格等于 `false` 时记录失败并跳过后续计算；缺失字段兼容旧记录，显式 `false` 接受。不存在字符串、null 或数字的隐式真假值绕过。失败仍进入原有轮次判定，不能成为完整干净轮次。

门禁及测试 SHA 与 `docs/native-iteration-review-round15-gate.md` 的独立 APPROVE 一致，该审查已检查所有八个指标、各轮失败后的尾轮计数及额外的 0/空字符串/数组/对象拒绝场景。已核对当前 `.qa/native-gate-tests-r17.log` 为实际 2/2 通过；统计和包/源码证据绑定逻辑没有改变。本轮没有重复运行已通过且源码未变的纯 Node 回归。

本次重新执行 `node node_modules/eslint/bin/eslint.js . --ext .ts,.tsx,.js,.jsx`，exit 0，无诊断。项目没有 typecheck script，现有 tsconfig 不包含这两份 `.mjs`；未启动无关 TypeScript 编译。

## 冻结源身份与边界

- `installer-transaction.cs`：`609df9f385f09bcfb26e5b022896c50c117f7b72036e37dff2b3dcdc3495b7fb`
- `installer-transaction-file-tests.cs`：`7a25b3214f64bf728b83857ed76048c731b883a48275d622ceb760a92ecbc24d`
- `check-native-acceptance.mjs`：`eac807429386752ef24cfef57e0db6111657a0d73c62b36172ba7ef165d45ee9`
- `native-acceptance.test.mjs`：`adf227e2410dadc465ff1d24a04ce37e2f2a7b4dba34404b9b904c8cf715c366`

未修改业务源码、测试、原始证据或他人的文档，未启动编译、安装、注册表探测、ADB 或应用操作。此批准覆盖上述冻结源码；完整安装故障恢复、最终双端性能和正式连续三轮仍按实际验收记录推进。当前 `docs/native-rounds.json` 仍为 implementation，rounds 为空。
