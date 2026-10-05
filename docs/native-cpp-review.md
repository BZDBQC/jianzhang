# Windows 原生 C++ 独立审查

审查日期：2026-10-05。范围为 `clients/flutter/windows/runner/**`、Windows 与 Flutter CMake 配置，以及本地官方 Flutter 3.47.6 C++ wrapper 的相关 API 合同。审查员未修改 C++ 源码；实现负责人收到反馈后修复，本文依据其第二次冻结的源码复审。

结论：**Warning（仅维护与验证提醒），没有尚未修复的 CRITICAL/HIGH 问题。** 本结论是源码审查结论。当前早期 release bundle 的编译与文件完整性不能证明这次修改已经编译或运行通过；最终源码仍须由主任务重建，并验证 Windows 11 启动、关闭、首帧日志及窗口行为。Windows 10 实际安装、运行、升级仍未验证。

已修复并复核的边界：

- `runner/main.cpp:9` 使用不可复制的 `ComApartment` 管理 COM。只对成功初始化（含 `S_FALSE`）调用 `CoUninitialize`；它先于 project/window 构造，因而在所有返回路径中都晚于其析构。初始化失败返回失败。符合 [Microsoft COM 初始化说明](https://learn.microsoft.com/en-us/windows/win32/learnwin32/initializing-the-com-library)。
- `runner/main.cpp:55` 仅对 `GetMessage > 0` 的有效消息分派；`0` 结束，`-1` 返回失败，避免错误时分派未定义或陈旧的 MSG。符合 [GetMessage 返回值合同](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage)。
- `runner/win32_window.cpp:182` 在销毁时清理窗口和子窗口观察句柄；`WM_NCDESTROY` 清除 `GWLP_USERDATA` 并把实际 `hwnd` 传给 `DefWindowProc`，默认消息分派也使用形参。这保证 `WM_DESTROY` 之后的尾消息不使用已清空的成员句柄。尾消息顺序依据 [WM_NCDESTROY 官方说明](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-ncdestroy)。
- `runner/flutter_window.cpp:37` 将 readiness 结果保存在 `unique_ptr` 中；未知方法返回 NotImplemented，重复 pending 请求返回错误，已完成请求复用首次结果。关闭时先回复 pending 错误、显式注销 channel handler，再销毁 channel 和 engine，避免 handler 留存悬空 `this`。
- 计时起点为 `wWinMain` 的第一条 `GetTickCount64`。Dart 仅在数据库视图可用、`endOfFrame` 完成后发送请求；native 首个回调只负责显示窗口。请求经窗口消息排队，在初始 callback 返回后重新注册绘制回调并 `ForceRedraw`，直到该回调才记录 `readyMs`、返回结果和输出一次 JSON，避免将加载页首帧计作数据就绪，也避免 wrapper 在回调返回时清空新注册 callback。所有新增状态在 platform 线程访问；官方本地 `flutter_windows.h:269` 明确 next-frame callback 也运行在该线程。该指标覆盖入口到原生绘制回调，不包含进程进入入口之前的 OS 加载耗时，也不是显示器实际呈现时间或已测得的冷启动 p95。相关实现可核对 [同版本 Flutter Windows engine](https://raw.githubusercontent.com/flutter/flutter/5fc346839b/engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc)。

路径与资源结论：

- `DartProject(L"data")` 安全地使用与 exe 同目录的资源。官方本地 `dart_project.h:84`、`flutter_windows.h:87` 明确相对路径以可执行文件目录为基准，故不能把从 System32 或其他 cwd 启动判为此代码的路径缺陷。带中文、空格的安装目录仍需要最终候选实测。
- CMake 使用 C++17、`/W4 /WX`，安装 engine DLL、ICU、插件库、native assets、完整 Flutter assets 和非 Debug AOT。`source-contract.ps1` 的 `Assert-WindowsPayload` 对早期 bundle 只读验证通过：exe、engine、SQLite、JNI、file_selector、secure_storage、ICU、app.so、assets/native-assets manifest 均存在，SQLite manifest 指向 bundle 内的 `sqlite3.dll`；早期根目录亦存在三项 app-local CRT DLL。最终候选必须再次通过该断言及源码/payload 合同校验。
- Manifest 为 PerMonitorV2，创建按 monitor DPI 缩放，`WM_DPICHANGED` 采用建议矩形，`WM_SIZE` 更新子窗口。没有 native 最小尺寸策略；当前依赖 Flutter 的响应式布局。跨 DPI monitor、最小化/恢复、极小窗口的实际表现属于 Windows 11 候选运行验收，不能由源码静态检查记为已通过。

维护项（非发布阻断）：`WindowClassRegistrar` 仍使用进程期固定裸 `new` 单例，可改为函数局部静态对象以表达生命周期；没有发现随操作增长的泄漏。`printf/fflush` 未检查输出失败，channel 结果不受 stdout 是否可用影响；性能验收应要求捕获到有效且唯一的 `JIANZHANG_READY`，缺日志不得记通过。`OnCreate` 稍长，且沿用模板的若干命名、初始化和默认分支风格；不应把这些风格警告等同于真实悬空访问或跨线程竞态。Win32 LPARAM/GWLP_USERDATA/动态 API 的转换均为相应 ABI 边界用途，没有发现不受信任字符串被当作格式串或 shell 命令执行。

验证证据：已执行要求的 `git diff -- '*.cpp' '*.hpp' '*.cc' '*.hh' '*.cxx' '*.h'`，当前父仓库没有这些文件的可用 tracked diff，故逐文件审查冻结源码。Visual Studio 自带 x64 `clang-tidy` 对四个 runner `.cpp` 使用 `--checks=*,-llvmlibc-*`、C++17、实际 Windows/Flutter 头文件和项目宏运行两次；最终 exit code 0，没有编译错误。最终日志为 `.qa/native-cpp-clang-tidy-final.log`；有效告警包括忽略 `fflush` 返回值、base destructor 虚拟调用以及模板风格项。base destructor 虚拟调用仅到 base 的空 `OnDestroy`，常规关闭已先完成 derived 清理，未据此认定为悬空访问。`cppcheck` 在 PATH 和标准安装路径均未找到，未运行。没有执行注册表诊断命令，也没有修改系统执行策略。

冻结文件 SHA-256：

| 文件（相对 `clients/flutter/windows`） | SHA-256 |
| --- | --- |
| `runner/main.cpp` | `083fce46b434d54f163eb06907e46b809907ba7afd82d0138041110f5336791a` |
| `runner/flutter_window.cpp` | `56ef9ea33f683a4f934db70a6dd8ac113160cb4a694a565faab211710426c95d` |
| `runner/flutter_window.h` | `09f331e67161ba9d99556156cbdf478c4b4aaa739f11595a1da000b474290222` |
| `runner/win32_window.cpp` | `7a2a99c36e6c8d47c64f9b561f0204cd378dbc2542cf9fc315014c4988ecf784` |
| `CMakeLists.txt` | `ee03d1cce5b35b2ecc461fc163b4c60cea8dd0ccc1cfda43e4fc5bc489a95a34` |
| `flutter/CMakeLists.txt` | `bd05e3268b2f246bcbafdb778165fe67a7bafdba04eb73599502563a67b8ae7e` |
