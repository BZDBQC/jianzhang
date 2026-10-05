Windows 原生适配测试交接，尚未执行原生运行验收。

测试源码：`clients/flutter/integration_test/native_windows_adaptation_test.dart`，
254 行，冻结 SHA-256：
`7fc7d7d4ea025ffe596f09f2345251571d97fb58f8485421a04d86231b9cdcc1`。
本次只新增此夹具，没有修改生产界面、驱动或打包代码。

最新静态分析成功，日志为 `.qa/native-windows-adaptation-key-fix-analyze.log`。
首次分析发现 `dart:ffi.Size` 与 Flutter `Size` 名称冲突，现用 `hide Size`
解决；原错误日志保留在 `.qa/native-windows-adaptation-analyze-before.log`。
独立源码审查由 `native_iteration_review` 负责，本文件不作为独立批准记录。

运行必须使用 Windows 的 profile/release 模式，并给出非缺省的
`JIANZHANG_QA_BUILD` 和 `JIANZHANG_QA_ROUND`。标识只接受字母、数字、点、
下划线和连字符，不会用于构造输出目录。每次在本机临时目录下的
`jianzhang-windows-qa/run-*` 新建唯一目录，SQLite 只由本次
`repositoryProvider` 覆写使用，不访问真实账本。目录保留供归档。

夹具覆盖：

- 按 `FLUTTER_RUNNER_WIN32_WINDOW` 枚举窗口，再验证所属进程 PID；读取和
  缩放前再次确认身份。[FindWindowExW 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-findwindowexw)。
- 保存原始外框尺寸，请求 640×520、1024×720、1600×1000 三个真实窗口尺寸。
  使用 `ASYNCWINDOWPOS | NOMOVE | NOZORDER | NOACTIVATE`，最后恢复原尺寸。
  [SetWindowPos 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)。
- 最多等待 5 秒，要求真实外框达到请求尺寸，`GetClientRect` 与 Flutter
  physicalSize 相等。记录当前 DPI、DPR、逻辑视口和实际字体缩放；
  PerMonitorV2 清单下另断言 DPI/96 与 DPR 差值不超过 0.02。
  [GetDpiForWindow 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow)。
- 验证“记一笔”按钮至少 48×48 dp、处于完整视口且可命中，点击打开表单。
  Ctrl+N 打开记账表单，Ctrl+F 打开搜索，Escape 关闭相应弹窗。
- 每种尺寸保存首页、记账、搜索三张原生 Flutter 渲染内容 PNG，共 9 张。
  `evidence.json` 与 `JIANZHANG_WINDOWS_ADAPTATION` 日志包含候选标识、
  尺寸样本、恢复结果和最终状态；SQLite 也保留在同一新目录。

快捷键通过 Flutter hardware-key dispatch 注入，并非物理系统键盘输入。
没有更改系统 DPI、注册表或其他进程窗口；只覆盖运行时所在显示器的 DPI，
不能将其描述为多种系统 DPI 已通过。可选的 1.6 字体注入没有加入本夹具，
实际记录的 textScale 也不能替代该覆盖项。原生 profile 运行、PNG 视觉检查
及候选构建前后指纹核验仍由根代理完成。

首轮真实 profile 运行未通过：640×520 外框、624×479 client、DPI 106、
Flutter DPR 1.1041666 与恢复原始尺寸均有证据，但 Escape 派发在 SDK
`KeyEventSimulator._findPhysicalKey` 抛出空值错误，后续尺寸尚未运行。
日志 `.qa/native-windows-adaptation-drive-r9.log`，原始结果与已保存 PNG 在
`.tools/temp/jianzhang-windows-qa/run-6677864d/evidence.json` 同目录。
本地 SDK 的回退映射依赖 profile 中缺失的 debugName；现在每个 Escape、
Ctrl 左键及 N/F 事件均显式传入匹配 PhysicalKeyboardKey 和 windows 平台，
保留真实快捷键派发与模态断言，没有改为直接调用页面。该窄修新增 4 行；
静态分析不等于修复后原生运行通过，仍需独审与根代理重跑。
