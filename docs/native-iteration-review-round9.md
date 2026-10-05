# 原生迭代第 9 轮窄范围独立审查

结论：**APPROVE（冻结配置与测试源的静态范围）**。未发现置信度超过 80% 的未解决缺陷。没有执行 Flutter/Gradle 构建、ADB、模拟器、安装器、注册表或真实窗口操作；本审查不计入完整干净回归。

## 冻结范围

| 文件 | SHA-256 |
| --- | --- |
| `clients/flutter/android/gradle.properties` | `fc45623fecbca661d792884d4bb204dc930b6cb33debbc1a847da68531f964e4` |
| `docs/native-android-build-memory.md` | `3fa1a1a026af331ee0898f4c8c7d03480aecfa130aeb396f62df05e69b7e525b` |
| `scripts/native-toolchain/start-emulator.ps1`（仅 API 37 RAM 选择增量） | `c472d24330ea8c36e9c7caf8df7e5e41f9aa0f83e3d7665e4d5946ffb0feae6f` |
| `clients/flutter/integration_test/native_windows_adaptation_test.dart` | `fd629423f8225dde8a813e19291bbc416bd111b123722b86f84d2caef91040ae` |

## 配置核对

直接读取 `.tools/android-build-client/android/hs_err_pid15368.log` 和第 8 次 Android 构建日志，核对到 G1 virtual space 的 `mmap 2600468480 bytes` 失败及原 `Xmx8G/MaxMetaspaceSize=4G/ReservedCodeCacheSize=512m` 参数。旧构建副本的另外 5 行 Android 设置/模板注释与新源一致。

属性解析校验通过：5 个唯一键，堆上限 2G、元空间 1G、代码缓存 256m、worker 上限 2，原 OOM 堆转储参数与 AndroidX/newDsl/builtInKotlin 设置保持。没有系统分页文件、全局 Java、代理、签名或业务源修改。故障文档明确只做静态核对、实际新 release 构建尚未验证，未把配置建议写成已解决结论。

模拟器脚本 AST 无错误；纯提取 RAM 表达式的 6 个用例通过，API 26/29/33/35/36 均为 2048 MB，只有 API 37 为 4096 MB。启动参数使用该变量、隐藏窗口，过程环境仍在 finally 恢复。API 35 的固定配置未改变。这只验证启动选择，不证明 API 37 系统健康、16 KB 运行或 APK 功能通过。

证据：`.qa/native-iteration-review-round9/config-fixture-evidence.json`。

## Windows 适配测试核对

- 读取完整冻结测试及窗口 runner、键盘调用点、PerMonitorV2 manifest。`FindWindowExW/GetWindowThreadProcessId/GetWindowRect/GetClientRect/SetWindowPos/GetDpiForWindow` 的 FFI HWND/指针、DWORD/UINT、BOOL 和 4 个 Int32 RECT 元素与本地官方 Windows SDK 头文件及 x64 ABI 匹配。UTF-16 类名在 finally 释放，arena 指针按调用释放；HWND 不作为拥有的内核句柄关闭。
- 按实际 `FLUTTER_RUNNER_WIN32_WINDOW` 类和本进程 PID 找窗口；读取和调整前重新核对 PID。`0x4016` 对应 ASYNCWINDOWPOS/NOMOVE/NOZORDER/NOACTIVATE，尺寸调用失败及 5 秒未收敛均失败。没有修改系统 DPI、显示设置、全局键盘或其他进程窗口。
- 官方本地 Flutter SDK 的 integration binding 默认读取实际 engine physicalSize/DPR；测试没有设置假的 view size/DPR。每次要求 GetClientRect 与 Flutter physicalSize 相等，并断言 DPR 与窗口 DPI/96 的误差不超过 0.02。覆盖请求外框 640×520、1024×720、1600×1000；记录原外框、实际 client、Flutter physical/logical 尺寸和 DPI。
- 只在新建的应用临时 `jianzhang-windows-qa/run-*` 目录创建 SQLite 与证据，ProviderScope 明确覆写为该测试仓库，未接触原本账本。截图使用实际 DPR、PNG 编码失败会失败、ByteData offset/length 正确，图像在 finally 释放；每个尺寸输出首页/记账/搜索截图。
- 检查“记一笔”至少 48×48 dp、在 viewport 内且可实际命中，然后点击验证表单。Ctrl+N/Ctrl+F 通过 Flutter 硬件键事件分发验证表单出现，Escape 验证关闭；Control 在 finally 释放。此覆盖不是物理键盘或系统输入注入，报告明确说明。
- 测试异常保留并重抛；finally 尝试恢复原尺寸、等待实际 engine 收敛，恢复失败记录 restoreError 并令 passed 为 false。关闭测试 repository 后才发布证据，原窗口不被销毁。缺少最终证据或非零 drive 退出不可算通过。
- 本次只检查当前 monitor DPI，并记录实际 MediaQuery 字体比例；没有 font 1.6 设置/断言、没有切换不同 OS 显示比例，不能报告原生字体 1.6 或多比例实测通过。已有 widget 大字体覆盖应单独引用。

9 个纯源断言通过，证据：`.qa/native-iteration-review-round9/windows-source-fixture-evidence.json`。作者 targeted analyze 的 No issues 日志已核对：`.qa/native-windows-adaptation-analyze.log`；初次 Size 名称歧义的失败日志保留，不将其替换成通过。审查者未独立执行 analyze 或原生 drive，实际窗口适配仍待调度者测试。

## Review Summary

| Severity | Count | Status |
| --- | --- | --- |
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | info |
| LOW | 0 | note |

Verdict: **APPROVE — 冻结静态审查范围无已知未解决问题。新 Android 构建、API 37 系统运行及实际 Windows drive 未由本审查验收；Windows 10 实机、Android 真机和真实短信边界继续保留。**
