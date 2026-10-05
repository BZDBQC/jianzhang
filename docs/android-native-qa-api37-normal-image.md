# API 37 常规镜像准备检查点

本记录仅为环境准备。官方常规镜像已下载、校验、安装，独立 `Jianzhang_API37_Normal` AVD 已定义，尚未启动或运行 ADB，不表示 APK 的 API 37 功能或适配验收通过。准备在根代理明确释放下载与 IO 窗口后进行；实际启动仍等待设备交接。

官方 [Google APIs 镜像元数据](https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml) 的本机副本为 `.tools/downloads/google-apis-sys-img2-v4-r9.xml`，所选独立 package node 保存于 `.qa/api37-normal-image-official-metadata.xml`。解析完整副本确认该 package 唯一，不能仅根据文件名猜 revision 或 SHA。

| 属性 | 已安装的常规镜像 | 已安装的 16 KB 镜像 |
| --- | --- | --- |
| Package | `system-images;android-37.0;google_apis;x86_64` | `system-images;android-37.0;google_apis_ps16k;x86_64` |
| Revision | 6 | 7 |
| 发布频道 | `channel-0`（稳定） | 当前安装 properties 不记录频道，不推断 |
| API / Extension | 37.0 / 22 | 37.0 / 22 |
| ABI | x86_64（元数据声明可翻译 arm64-v8a） | x86_64 |
| 标签 | Google APIs、AI Glasses Compatible | Google APIs、16 KB Page Size |
| 最低 Emulator | 36.5.11 | 36.6.11 |

当前已安装 Emulator 为 37.2.12，满足两者声明的最低依赖。常规镜像预期为普通页大小；仍须启动后以 `getconf PAGE_SIZE` 实测，不把镜像名称当实际页大小证据。旧 16 KB 模拟器的系统图形崩溃仍属未解决的环境问题；常规镜像成功也不替代 16 KB 的动态验证。

已校验的官方 archive：

- URL：`https://dl.google.com/android/repository/sys-img/google_apis/x86_64-37.0_r06.zip`
- 大小：2,234,615,040 字节。
- 官方 SHA-1：`629e507fd5b737c2c836b12b52c81cd0e3b12399`。
- 独立下载目录 `.tools/downloads/api37-google-apis-normal-r6-629e507f/` 的 `verified-archive.json` 记录实际大小及官方 SHA-1 一致；额外 SHA-256 为 `43f1d4eadf9117a505bbd815704ac5d9aaf4c7ce61c9d99f66305245ce00a191`。
- 官方 sdkmanager 安装退出码 0，证据 `.qa/android-api37-normal-install-629e507f/result.json` 与 `sdkmanager.log`。安装目录 `.tools/android-sdk/system-images/android-37.0/google_apis/x86_64` 与原 `google_apis_ps16k/x86_64` 分离。
- 新 AVD 路径 `.tools/avd/Jianzhang_API37_Normal.avd`，RAM 4096 MB、vCPU 4，`hw.gpu.enabled=no`，启动时选择软件渲染。准备结果 `.qa/android-api37-normal-avd-preparation-629e507f/result.json` 明确 `bootVerified=false`、`pageSizeVerified=false`、`adbUsed=false`。旧镜像目录及旧崩溃日志未覆盖。
- 两个 archive 的 `advancedFeatures.ini` 比较相同，包括 GLDMA/GLDirectMem 设置。因此普通镜像是否解除先前 SurfaceFlinger 崩溃，仍须本机启动实测，不能从 archive 名称推断恢复成功。

当前公共 `prepare-emulators.ps1` 仍把 API 37 指向 `google_apis_ps16k`；本任务不修改此脚本。实际使用普通镜像需显式选择新 AVD 名称。禁止把 `-data` 与 `-wipe-data/-initdata` 组合当作保留旧 AVD 的保证；此前 QA 实验已经证实模拟器可能先清理默认 userdata。后续使用独立新 AVD，不 wipe 旧 userdata。

## 2026-10-05：常规 API 37 真实启动仍被系统图形崩溃阻断

已启动独立 `Jianzhang_API37_Normal`（官方 normal revision 6），software、4096 MB、4 vCPU、无窗口、无快照，未使用 wipe-data，也未修改原 `google_apis_ps16k` AVD。实际 `PAGE_SIZE=4096`、MemTotal=4008504 kB、在线 vCPU=4。首次 `sys.boot_completed` 为空，后续为 1；activity 和 SurfaceFlinger 服务存在，但无法据此判断图形系统稳定。

启动日志的实际后端为 gfxstream，GLES 选用 SwiftShader（OpenGL ES 3.0 SwiftShader 4.0.0.1），Vulkan 选用 lavapipe。预安装完整 logcat 记录至少五次 SurfaceFlinger SIGABRT，均由 `mapper.ranchu: Assertion failed: !rcEnc->featureInfo()->hasReadColorBufferDma` 引起；SurfaceFlinger PID 在观察期间持续变化。`screencap -p` 本身退出码 134，并打印同一断言；没有取得可信系统 PNG。

应用安装前两次 `pm path com.jianzhang.ledger` 都为空，未安装客户端，因此没有执行三种记账、重启或横竖屏脚本，不将系统阻断计为客户端缺陷或客户端通过。当前 R9 APK 的本地 SHA-256、签名、包名和版本已经核对；该包早于 Esc 修复，只作为开发参考，也没有跳过现有 UI 脚本的源码守卫。

当前普通 4 KB 镜像与此前特殊 16 KB 镜像均已在安装客户端前复现相同系统断言。仍未完成 API 37 动态验收，静态 APK 16 KB 对齐检查不能替代它。没有重复禁用图形特性、切换系统 overlay 或修改/禁用 SystemUI，也没有全局环境修改。

本轮证据目录：`.qa/android-api37-normal-boot-r11-1a10bafee1a`。`evidence.json` 为 blocked-environment，附完整 preinstall logcat、两次系统事实、实际 renderer 摘录和 screencap 退出结果。已仅停止本轮 owned 进程 21676、3312、10856、21764、5748，结束后 `adb devices` 为空，`device-release.json` 确认无 owned PID 残留；ADB/模拟器交接回根代理。

## 2026-10-05：一次标准 host 后端实验仍复现安装前崩溃

在独立 Normal37 普通 r6 AVD 上执行一次标准 `-gpu host`，RAM 4096 MB、4 核、no-window/no-snapshot/no-audio；没有 -feature 参数、特性 ini/env 覆盖、wipe-data、SystemUI/overlay 修改或全局驱动变更。该组合与此前 ps16k、2 GB 的 host 实验不同，但并未成功修复环境。

实际启动日志为 gfxstream，GLES 和 Vulkan 都选择 host。OpenGL 适配器为 NVIDIA GeForce RTX 3050 Laptop GPU，版本 `OpenGL ES 3.0 (4.5.0 NVIDIA 596.49)`；实际页大小 4096、MemTotal 4008504 kB、在线核数 4。

首次完整预安装日志已记录 13 次 SurfaceFlinger SIGABRT，仍由 `!rcEnc->featureInfo()->hasReadColorBufferDma` 引起，原始日志保留了这些不同 PID 的时间序列。首次系统事实显示 boot_complete 为空、SurfaceFlinger/SystemUI PID 不可用，activity 服务存在；包管理调用当时返回 broken pipe，不能将它写成成功的空包查询。截图退出 134，无 PNG，因此没有进行完整 PNG 解码、系统交互资格检查或客户端安装/UI 测试。

第二次 logcat 客户端在 15 秒内未完成，被停止；其输出文件为 0 字节。复合采集在持久化第二次系统事实之前中止，`second-capture-failure.json` 明确保存此缺口，未补造 PID、崩溃计数或完整日志。准备停止 owned PID20992 时，该 PID 和 emulator/qemu 进程已经退出，身份守卫拒绝针对不存在 PID 的停止操作。根代理确认没有关闭模拟器；宿主退出原因未明，不能声称成功执行 Stop。19:21:33 的复核和最终 `device-release.json` 都确认 adb devices 空、无模拟器进程，资源已经交回根代理。

证据目录：`
.qa/android-api37-normal-host-r12-1cdfd41f439a424f8ae7398692a7f1aa
`，`evidence.json` 状态为 blocked-environment。未再次启动本组合，未执行已被拒绝的内部特性覆盖。API37 客户端动态验收仍未完成，本次结果是安装客户端前的图形环境阻断。
