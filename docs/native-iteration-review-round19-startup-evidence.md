# 第 19 轮独立审查：Android 冷启动失败证据

最终结论：**APPROVE**。本轮发现的问题已修复，最终源码未发现 CRITICAL、HIGH 或 MEDIUM 问题。下面保留首轮 BLOCK 的发现与复现，再记录修复确认。范围仅为 `scripts/native-toolchain/measure-android-startup.ps1` 的本地 diff 和必要周边控制流，没有审查保存提交修复或其它客户端修改。

审查源码 SHA-256：`d6545e0dc2920c512a266f5b2c99b1de1e952e4bab402df1758bf4b9ddc55bcd`。先检查 staged/unstaged diff；本次没有 PR 元数据可核验 merge readiness。PowerShell AST 解析为零错误。未启动 ADB、模拟器、编译或重型任务，未修改业务源码。

## HIGH：派生失败文件未经工作区与链接检查

位置：`scripts/native-toolchain/measure-android-startup.ps1:135`。

基础 `$outputPath` 已经过 `Assert-WorkspacePath` 校验，但新写入目标 `$outputPath + '.failure.json'` 是另一个文件，没有经过该校验。基础文件不存在或为正常文件，不代表后缀文件也安全。后缀位置若已是文件链接，`Set-Content` 可跟随它覆盖 `.qa` 之外的内容；若是目录或其它不合规对象，也只能在写入失败后才发现。

建议对完整后缀路径独立调用现有 `Assert-WorkspacePath -PathType File -AllowMissing`，并在实际写入前保持父目录/链接检查。拒绝非法目标时保留启动主异常，诊断失败作为次要信息；不要删除链接目标或改变权限。若允许同一 Output 重跑，应明确处理已有失败证据的覆盖策略。

## MEDIUM：清理错误覆盖启动主异常

位置：新增 catch 的 `throw $startupError` 与紧邻 finally 的 `Invoke-Adb ... force-stop`。

新 catch 保存了原始错误，但 finally 中的 log reader 清理或 force-stop 仍可抛错。宿主退出、设备离线时，force-stop 失败会覆盖刚重抛的启动错误，调用者失去原始异常链。该 finally 虽是既有代码，却直接影响这次失败证据分支的异常保留目的。

已用真实 AST 提取新增 catch 和原 finally，构造纯内存探针：Set-Content 只捕获 JSON，Invoke-Adb 是抛出设备离线错误的本地 mock，stream.Dispose 是空方法，没有调用真实 ADB、没有写文件。结果：

```text
原始错误：PRIMARY_READINESS_FAILURE
失败 JSON error：PRIMARY_READINESS_FAILURE
调用者最终错误：CLEANUP_DEVICE_OFFLINE
调用者 InnerException：null
```

建议分别捕获清理失败，已有启动主异常时优先保留/重抛它，并将清理错误附加为诊断；成功路径的清理失败仍应明确失败，不能被吞掉。诊断写入失败的告警也不应成为新的主异常。

## 已确认的正确行为

- 每样本新增 `$launch`、`$launchToken`、`$seenLaunchMarker` 初始化，结合已有 PID/native/fullyDrawn 初始化，避免失败记录携带上一样本的标识。
- 失败文件明确为 `status: incomplete`，使用 `completedSamples`，并不写入完整达标原始指标文件；catch 仍终止采样，完整输出和 p95 达标信息仍位于全样本完成之后。
- 新记录使用已采集的日志和标记，不增加 ADB 查询范围，也未新增账号/账单读取。失败 JSON 本身不符合正式指标的 samples/metric/构建配置等完整合同，不能被当成合格性能样本。
- 此次纯 PS diff 不包含 TypeScript/JavaScript 变更，没有运行无关 TypeScript 或 ESLint 检查。

## 验收边界

本报告只审查失败证据和异常路径。没有产生冷启动性能样本，没有把部分采样或诊断结果计入正式三轮。正在执行的第三次真实采样结果，由主任务按实际日志继续判断；报告中的纯 mock 探针不替代设备验证。

## 修复复查与最终批准

最终源码 SHA-256：`6736852e517d0afe8a6dc06e0b870890311c88ab40d308b12fa06a97d1e95edb`，PowerShell AST 解析仍为零错误。

- Output、failure、partial 三个目标在开始时拒绝已有路径，保留旧证据；两个派生路径分别使用现有 `Assert-WorkspacePath -PathType File -AllowMissing` 校验。首轮 HIGH 已解决。
- 每样本初始化 startupError。finally 分别捕获 log reader 与 ADB 清理错误；已有主异常时保留原重抛，无主异常时仍抛出清理错误。首轮的主异常覆盖问题已解决。
- 首次修复复查又确认 `$WarningPreference='Stop'` 会让诊断告警成为新主错误，已反馈作者；三处诊断 Write-Warning 现在均显式 `-WarningAction Continue`。这次中间发现也已修复，没有遗留。
- 每个成功样本追加后的 partial JSON 明确标记 `status: incomplete`、`formalAcceptance: false`。它保存累计数值和日志，但没有正式原始指标所需的 metric/buildId/roundId/mode/configurationSha256 身份；即使累计 20 个样本，也不能作为完整达标证据。完整输出仍要经过全部采样、已装 APK、源码/manifest 和设备运行信息的最终检查才生成。

再次从最终真实 AST 提取 catch/finally 做六个纯内存探针，全部符合预期：

1. 默认告警策略：启动失败与 ADB 清理失败并存，调用者和失败 JSON 均保留原启动错误。
2. WarningPreference Stop：同样保留原启动错误。
3. 诊断写入与 ADB 清理同时失败、WarningPreference Stop：调用者仍为原启动错误。
4. stream 与 ADB 清理同时失败、WarningPreference Stop：已有主异常时仍为原启动错误。
5. 无启动主异常、ADB 清理失败：明确抛出 ADB 清理错误。
6. 无启动主异常、stream/ADB 清理都失败：保留第一个清理错误，没有静默成功。

全部探针的真实 ADB 调用和真实文件写入均为零。仅修改本报告，没有启动设备或重型任务。主任务报告的 R19d 实际 20 样本结果属于设备测量证据；此次批准限于已修复的采样失败记录、输出边界和异常控制流，不把纯探针计入正式三轮，也不重新运行同一已通过的设备度量。
