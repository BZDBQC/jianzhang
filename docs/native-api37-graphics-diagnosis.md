# API 37 模拟器图形阻断：只读诊断

核对时间：2026-10-05 19:12（Asia/Shanghai）。本次仅读取已有日志、SDK 配置和官方资料，未启动模拟器、ADB 或 EXE，未下载新镜像，未修改 SDK、AVD、系统设置或生产源码。

## 已确认的范围

普通 API 37 Google APIs x86_64 r6 在当前 Windows 11 / WHPX / Emulator 37.2.12 环境中，配置 4 GB、4 核、`software`，实际选择 gfxstream、SwiftShader GLES 和 lavapipe Vulkan。客户端尚未安装时 SurfaceFlinger 已反复 SIGABRT；系统 screencap 返回 134，不能取得正常系统 PNG。因此 `sys.boot_completed=1` 不能作为可用界面或客户端兼容验收。

本机证据：`.qa/android-api37-normal-boot-r11-1a10bafee1a/evidence.json`、`renderer-startup-excerpt.txt`、`system-graphics-crash-excerpt.txt` 和 `system-first-screencap-result.json`。旧 ps16k 镜像也有同类故障；不能归因于简账 APK。

本机 SDK 的 `source.properties` 为 37.2.12、build 16428233。2026-10-05 读取的[官方仓库元数据](https://dl.google.com/android/repository/repository2-3.xml)明确将它列为 **channel-0 stable**：Windows x64 ZIP 455,342,868 字节、SHA-1 `488ed747e82de7e9bb5247becd1ac043c7e5e85d`。仓库还列有 37.3.2 channel-2 Canary。[官方已关闭问题清单](https://developer.android.com/studio/releases/fixed-bugs/emulator/37)同样将 37.2.12 标为 Stable，未列出本次 DMA 故障的明确修复。发布说明另一页仍写 37.2.11 Stable，不能仅凭这个滞后标题把当前 SDK 当作预览版，也不能将降到 37.2.11 当作已知修复。

API 37 至少 4 GB 的要求已满足；[官方发布说明](https://developer.android.com/studio/releases/emulator)从 36.6.11 起明确此要求，并在 37.1.11 中说明新增 API 37 所需 Vulkan 扩展。普通镜像 r6 已超过[官方排障页面](https://developer.android.com/studio/run/emulator-troubleshooting)针对 Google 服务认证问题要求的 r5；该认证问题与当前 mapper 崩溃没有已证实关联。

## 源码推断与边界

日志中的否定号表示缺少能力，而不是能力已存在：[goldfish mapper](https://android.googlesource.com/device/generic/goldfish/+/refs/heads/main/hals/gralloc/mapper.cpp)的 `readFromHost` 路径在 `hasReadColorBufferDma` 为 false 时终止进程。

[gfxstream RenderControl](https://android.googlesource.com/platform/hardware/google/gfxstream/+/refs/heads/main/host/RenderControl.cpp)第 496 行以 `GlDirectMem` 和 `HasSharedSlotsHostMemoryAllocator` 同时启用决定是否宣告读缓冲 DMA 能力。这是协议协商条件，并非直接检查宿主 GPU 型号或 GLES / Vulkan 后端名称。[QEMU opengles 初始化](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/android/android-emu/android/opengles.cpp)将 emulator feature controller 的值映射到 gfxstream FeatureSet。

本机 emulator 的默认配置为 `GLDirectMem=off`、shared slots=on；两种 API 37 镜像的配置均为 `GLDirectMem=on`。**这些静态文件不能证明运行时最终值。** [QEMU UI 渲染初始化](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/android/android-ui/modules/aemu-ui-window/src/android/main-common-ui.c)公开开发分支还包含 API >=29 自动启用 GLDirectMem 的逻辑，并尊重已有覆盖及 guest 禁用状态。此分支未与本机发布二进制逐字对应，不能据此认定一个后端必定成功，或认定当前运行时仅由默认 ini 决定。

此次未发现 `.tools/android-user-home` 顶层 `advancedFeatures.ini`，没有读取系统凭据。以上仅支持优先调查 host / guest DMA 协商，尚未证明确切失配发生在初始化哪一阶段。

## 可评估的下一步

[官方图形文档](https://developer.android.com/studio/run/emulator-acceleration)支持标准 `auto`、`host`、`software`、`lavapipe`、`swiftshader`、`swangle` 模式。标准渲染模式和已拒绝的内部特性覆盖是不同操作；本次没有执行任何一种模式。

1. 若继续做受控实验，优先在普通 r6、4 GB / 4 核的独立 QA AVD 上单独评估一次标准 `host`。旧 `.qa/android-api37-host-renderer-1/arguments.json` 使用 ps16k AVD、2 GB，不能覆盖这个组合。它能检验真实宿主 GPU 路径；不能预先称为修复。
2. 如需要另一项独立比较，可评估标准 `swiftshader`，核对实际是否从当前 SwiftShader GLES + lavapipe Vulkan 变为纯 SwiftShader 组合。`swangle` 则能比较 ANGLE 前端；均没有证据保证会改变 DMA 协商。避免遍历所有名称后将重复的同一底层配置算作新实验。
3. 本机已经是仓库当前 stable；无明确修复证据时不升级 Canary，不盲降旧版。若标准模式仍复现，应保留环境阻断，整理最小无 APK 复现与原始日志，等待官方修复或在另一个既有受支持宿主环境核对；不要降低客户端验收标准。

每项新实验必须先核对 emulator / image 版本、实际后端与内存；至少两次时间分离的 SurfaceFlinger / SystemUI 服务及 PID 检查、观察无重复 SIGABRT、正常系统页面交互、通过 PNG 完整解码的系统截图，再安装当前 APK 做功能检查。保留完整启动参数、进程所有权、logcat、开始结束时间和退出码。只有系统先可用，才有客户端测试资格；标准模式的结果也不能替代 ps16k 动态验证。

## 已拒绝操作

主任务的显式 GLDirectMem + shared-slots 特性覆盖启动被自动审批拒绝，未执行。本次不提供替换工具、拆命令、环境变量或修改 ini 达到相同效果的做法。既有 GLDMA 禁用、Qt、overlay、wipe-data 实验不能再次无依据重复；不禁用 SystemUI、SurfaceFlinger 或失败断言来获得表面通过。

当前结论：**API 37 客户端兼容验收仍未完成；现有证据是客户端安装前的模拟器图形环境故障，没有已实证的官方修复。**

## 20:03 追加：镜像修订与官方配套要求

前述标准 `host` 候选已经由主任务独立验证：`.qa/android-api37-normal-host-r12-1cdfd41f439a424f8ae7398692a7f1aa/evidence.json` 记录普通 r6、4 GB / 4 核、gfxstream、实际 4 KB 页，在客户端安装前仍出现 13 次 SurfaceFlinger SIGABRT，未取得正常系统 PNG，未尝试安装客户端。之后设备进程退出，原因未记录。此结果更新了上文的历史建议，**不再把重复同配置 host 启动作为新的排障步骤**。

20:00–20:03 重新读取[官方 Google APIs 系统镜像仓库](https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml)和[官方 SDK 仓库](https://dl.google.com/android/repository/repository2-3.xml)，并扩大镜像查询到全部 `android-37*` 包；未启动或停止模拟器。以下为独立 x86_64 包，修订号只在同一包路径内可比较：

| 官方包路径 | revision / channel | SDK major.minor / extension | 最小 emulator | 本机状态 |
|---|---|---|---|---|
| `system-images;android-37.0;google_apis;x86_64` | r6 / channel-0 | 37.0 / 22 | 36.5.11 | 已安装；software、host 均有系统图形阻断 |
| `system-images;android-37.0;google_apis_ps16k;x86_64` | r7 / channel-0 | 37.0 / 22 | 36.6.11 | 原有已安装 ps16k 包；此前有同断言 |
| `system-images;android-37.1;google_apis_ps16k;x86_64` | r9 / channel-0 | 37.1 / 23 | 36.5.11 | 不同包，可独立安装；未安装、未实测 |
| `system-images;android-37.2;google_apis_ps16k;x86_64` | r5 / channel-0 | 37.2 / 24 | 36.5.11 | 不同包，可独立安装；未安装、未实测 |

普通 37.0 包仍为 r6；原有 37.0 ps16k 包仍为 r7，**都没有同包的直接 revision 更新**。新增 37.1 / 37.2 都是 16 KB 小版本包，不能误写为普通 37.0 r6 的新修订。它们的仓库 channel 是 0；Android QPR 官方页面仍使用 Beta 发布标签，不能仅凭仓库 channel 把平台标签也写为正式版。

本机旧 ps16k 的 `source.properties` 与 `package.xml` 明确为 37.0、r7、extension 22、依赖 emulator 36.6.11。AVD 定义位于 `.tools/avd/Jianzhang_API37.avd/config.ini`，`image.sysdir.1` 指向这个 37.0 ps16k 目录；`.tools/android-avd/Jianzhang_API37.avd/config.ini` 不存在。定义文件当前 RAM 为 2048 MB，历史 4 GB 试验参数另有记录；静态定义不能冒充实际试验参数。本次仅读取这些小文件，未修改它们。SDK minor 0 来自元数据的 37.0，而不是一个已读取的独立运行时属性。

新增包下载信息（尚未下载）：

- 37.1 r9：`x86_64-ps16k-37.1_r09.zip`，2,178,012,675 字节，SHA-1 `35c0da1cd298f3426a5b48233f59515097446a28`。
- 37.2 r5：`x86_64-ps16k-37.2_r05.zip`，2,437,698,985 字节，SHA-1 `01ea96227f7c20db3a9c2d9c2ed6a2e878f81c5d`。

两者 ABI 均为 x86_64、包含 arm64-v8a translated ABI，archive 元数据没有限定 host OS；在当前 Windows x64 / WHPX 的同架构模拟器环境中没有新增宿主平台排除条件。[官方硬件加速要求](https://developer.android.com/studio/run/emulator-acceleration)支持这种 x86_64 宿主与 guest 组合。当前 emulator 37.2.12 大于两者声明的最小版本，满足仓库安装依赖；这只能确认可用官方 SDK Manager 独立安装不同路径的包，不能证明它们在本机可正常渲染。不同包路径可与原 37.0 镜像并存，新 QA AVD 无需替换或清除原 AVD。

[Android 17 获取页面](https://developer.android.com/about/versions/17/get)要求 Android Studio Meerkat 2024.3.1 和最新版 emulator；[SDK 配置页](https://developer.android.com/about/versions/17/setup-sdk)要求 Meerkat 2024.3.1 或更高。所核对页面没有要求必须使用 Canary。SDK 仓库当前最新 stable 仍为 37.2.12/build 16428233；37.3.2 是 Canary，不能作为已确认修复的配套版本。

[Build.VERSION 官方说明](https://developer.android.com/reference/android/os/Build.VERSION#SDK_INT_FULL)指出小版本发布保持 `SDK_INT` 主版本不变，完整主次版本由 `SDK_INT_FULL` 区分。因此官方 37.1 / 37.2 镜像是 **API 37 major 的独立兼容性测试候选**。它们未在本机启动，运行时 `ro.build.version.sdk=37` 目前只是依据官方规则的预期，必须在新 AVD 上实际核对；同时记录 minor、codename、实际页大小 16384、图形后端和内存。

约定的 API 37 验收没有限定 37.0 或 4 KB：满足实际 major 37、系统可用、当前 APK 的完整功能回归后，新小版本可提供 API 37 和 16 KB 实测证据。独立安装官方镜像并用标准受支持参数验证，属于另一镜像的兼容性核对；它不执行此前被拒绝的内部 feature 覆盖，也不证明该断言已修复。本次没有安装、启动、修改参数或提供特性覆盖方式。

在[emulator 37 已关闭问题](https://developer.android.com/studio/releases/fixed-bugs/emulator/37)、[Android 17 发布说明](https://developer.android.com/about/versions/17/release-notes)、[QPR1 发布说明](https://developer.android.com/about/versions/17/qpr1/release-notes)和[QPR2 发布说明](https://developer.android.com/about/versions/17/qpr2/release-notes)中未找到 `hasReadColorBufferDma` / mapper DMA 的明确修复。QPR 页面有一般设备重启及图形问题修复，尚无证据可将它们与当前无 APK 的模拟器断言等同。**可确认的是新增独立官方镜像候选；不可确认的是修复或验收通过。API 37 验收继续保持未完成。**
