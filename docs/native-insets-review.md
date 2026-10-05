# 系统侧栏避让独立审查

日期：2026-10-05。结论：**本次局部修复审查通过**。审查者未编写或修改实现与测试，未运行 Flutter SDK、ADB 或真实账本。

| 文件 | 审查 SHA-256 |
|---|---|
| `clients/flutter/lib/ui/shell.dart` | `0b195fb2174a9fd6f16fe90a0e41453785b7a922e6c3cd59fee96db1beebacc3` |
| `clients/flutter/test/ui/system_insets_test.dart` | `c78cdb9c07b1e787dc7abd558942d6d9dcc51c0473f53d90030fd6508c497a02` |

本次范围是 Scaffold body 的 Row 外新增 `SafeArea(top: false, bottom: false)`，以及对应左右系统侧栏的两项回归。原 app bar 与底部导航的避让保持各自负责，body 不重复添加垂直留白。

- 默认 left/right 为 true，body 与 desktop side rail 都按系统左右 padding 缩进，能处理 Android 横屏导航栏及侧边安全区域。系统侧栏无需依赖平台名称或固定设备尺寸。`SafeArea` 会调整后代 MediaQuery，已经避让的侧边不会再次应用同一 padding。[Flutter SafeArea 官方说明](https://api.flutter.dev/flutter/widgets/SafeArea-class.html)。
- 新测试载入实际 `LedgerShell`、真实隔离 repository fixture 和应用主题，在 800×400 逻辑尺寸下分别注入右/左 48dp 的 `padding` 与 `viewPadding`，等待账本页面就绪后检查 HomePage 和显眼“记一笔”按钮均位于可用横向边界内，并要求没有 Flutter 布局异常。测试验证可见几何行为，不以是否存在 SafeArea widget 作为通过标准。
- 两项测试共享 fixture 的异步 SQLite 生命周期，teardown 先卸载 widget，再关闭 fixture，并重置 viewport/DPR；不会触碰真实账本。测试对新增左右约束有直接意义；所有路由和宽屏布局完整回归仍属于 Root 后续验证范围。
- 已只读核对 `.qa/flutter-system-insets-after.log`：两个具体测试均执行，`+2: All tests passed!`。该日志是 Root 的真实执行证据，审查者未重新运行 SDK。
- `.qa/flutter-system-insets-before.log` 是错误 theme import 导致的编译失败，**不是行为失败证据**，不能称为两个先红后绿测试。修复前生产 API36 横屏截图及 bounds XML 由 Root 持有，证明实际问题；当前报告只核对新增源码、测试与成功日志，不冒称独立设备复现。

未发现本次左右 SafeArea 与两项回归的确定 HIGH/MEDIUM。Root 仍须完成完整 UI/services 回归与 analyzer，重建两端并在 Android 横屏/系统导航模式实际确认修复。当前日志和静态批准不代表 Windows 10、安卓真机或完整软件均已验收。
