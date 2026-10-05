# 最后测试工具与机械 Dart 修订独立审查

日期：2026-10-05（Asia/Shanghai）。基准为 `native-code-review-round5.md`。本轮只读源码、现有测试日志并执行 PowerShell AST/纯字符串解析检查；仅新增本报告。没有运行 Flutter SDK、ADB、安装器或注册表探测，避免与正在执行的 Android drive 争用。

## Findings

当前限定范围没有已知未解决审查问题。曾发现的临时文件问题已由拥有者修正并在本轮复核。

## 已解决的临时文件问题

[RESOLVED MEDIUM] 安装包核对临时文件没有独占所有权和路径校验

File: `scripts/native-toolchain/measure-android-startup.ps1:41`

Issue: `Assert-InstalledArtifact` 使用固定的 `outputPath + '.installed-apk'`。输出文件本身的 `Assert-WorkspacePath` 不覆盖这个 sibling。已有同名文件会被 `adb pull` 覆盖，随后 finally 删除；同名链接也没有先经过 no-reparse 检查。此外 pull 在 try 之外，失败后部分文件不会经过 finally 清理。这是工具自身的文件保护问题，不是 APK 或账本缺陷。

Fix: 为每次核对创建独占 UUID 子目录，校验该目录和新文件均在 `.qa` 下且无链接；将 pull、hash 和清理全部纳入 try/finally，清理仅处理本次创建的文件。不要删除既有未知路径。

复核：当前为 `android-startup-UUID` 独占目录，创建前后与 base.apk 检查均经过 `Assert-WorkspacePath`；pull 纳入 try/finally，删除前再次检查具体文件和目录，只使用非递归删除。固定 sibling 不再存在，失败的 pull 也进入清理。AST 再次为 0 errors；未实际执行 ADB pull。

## 已核对的行为

- 三处 `atomic_file.dart` 和一处 `file_service.dart` 多行 if 加 braces，以及备份警告测试对应机械格式修改，没有改变提交、异常或清理路径。真正的备份警告行为沿用第五轮已审查实现。
- 性能 harness 必须处于 release/profile，配置摘要须为 64 位小写十六进制，并写入每个原始指标与操作结果；Windows、Android 保存、筛选、滚动分开命名，不能只用一端结果填写两端指标。原始数组保留 30 次保存、30 次查询和实际 FrameTiming；真实可滚动列表、账本视图版本等待、分批导入恢复路径保留。
- fixture 生成将每笔两次 sink.write 改为 StringBuffer 每 400 笔一次写入并 flush。逗号仍依全局 index 判定，分块首笔正确保留前块所需逗号；400 整倍数没有多写空尾块，非整倍数的尾块在 `]}` 前写入。0/1/399/400/401/800/100000 七种计数用独立 Node 等价字符串模型核对旧新逐字符结果与 JSON 解析计数均相同，Unicode 与行顺序保留。生产 SDK 未被运行；这项优化只发生在测量前 fixture 生成，不改变保存/查询/滚动采样窗口或原始样本。
- Windows 冷启动新增配置摘要参数及 raw 字段，与已经通过打包专项审查的完整 payload/原生绘制信号合同一致。
- Android 计时首先验证 release SHA、schema-2 source provenance 和当前源码，再 pull 当前已安装 base APK 校验完整文件 SHA；后续再次核对已安装 APK 与输入 APK。没有把 `am start -W` 的 ThisTime 当作最终指标。
- Android 每次 force-stop 后确认没有存活 PID，使用独立 logcat 子进程和每次唯一 launch token；native-ready 行绑定新 PID，AMS Fully drawn 行绑定目标 Activity，两种信号均出现才计入样本。只终止本次创建的 log reader。采样不依赖可能被设备拒绝的 `logcat -c`。
- 冷启动 raw 的 metric/buildId/roundId 命名遗漏已经由拥有者在审查期间修正，当前输出与 gate 所需名字相符，不另列已解决 finding。
- PowerShell 两个 startup 脚本 AST 均为 0 errors。独立提取 duration 函数核对 `+0ms`、`+873ms`、`+1s203ms`、`+2m5s9ms`、`+1h2m3s4ms` 五个值，并核对合成 native PID 行和 Fully drawn 行；7 个纯解析样本通过。合成字符串不代表实际设备测量。
- 已读取 `.qa/flutter-full-analyze-round5.log`：No issues found；`.qa/flutter-ui-services-round5.log`：97/97 通过。没有将开发 profile 或单次启动值算作最终候选验收。
- QA root 创建的 Android files 目录缺少 SELinux categories 的环境问题已在 checkpoint 明确记录，处理范围为拥有者的模拟器 QA fixture；本次 startup/performance 新代码没有关闭 SELinux 或引入生产绕过。

## 身份与边界

| 文件 | 审查时 SHA-256 |
|---|---|
| integration_test/native_performance_test.dart | 5e86a103163d9c9cb19187b2fc29f57d47a7d26221e807f0c5ee1f784821e20f |
| lib/services/atomic_file.dart | 640adb5011f394150354dc191139a835585cdfbc10a4d5ff71bcdbb9e1cdc3c3 |
| lib/services/file_service.dart | 6e06b8fb9ed6b94e8bbce9e3d76c736189a66044d382e37dc23df8165668440e |
| test/ui/backup_warning_test.dart | 65e18b3527a95bf86c3df25ee59e4544edac0d09884a3da96850049be22b6dda |
| measure-windows-startup.ps1 | 5bed7142dc3e57851081c93d20a0dc5fd738f2d535df8c95b5298bbc5ff595c5 |
| measure-android-startup.ps1 | cd4ac7434b5d6cfab8454ec780d48fcea77dd9638a7e191251ece632f59c5125 |

配置摘要由调用者传入，格式校验不等于自动观察硬件；外层执行记录仍须对应实际固定设备配置。实际 20 次 release 冷启动、最终候选双端性能、故障提供器和完整回归尚不能由本报告宣告通过。完整干净轮次仍 0/3，Windows 10 实机、Android 真机和真实短信保持约定未验证边界。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: APPROVE — 当前限定修订没有已知未解决问题，生产机械格式修改、fixture 分块与 startup 工具可继续构建及实际测量。此结论仅为代码审查。
