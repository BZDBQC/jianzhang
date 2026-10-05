# API 37 常规镜像准备检查点

本记录仅为环境准备，尚未下载、安装或启动该镜像，也不表示 APK 的 API 37 功能或适配验收通过。API 35 的固定配置性能测量由根代理独占；在其明确释放性能与 IO 窗口前，不运行网络下载、大文件校验、解包、AVD 操作或 ADB。

官方 [Google APIs 镜像元数据](https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml) 的本机副本为 `.tools/downloads/google-apis-sys-img2-v4-r9.xml`，所选独立 package node 保存于 `.qa/api37-normal-image-official-metadata.xml`。解析完整副本确认该 package 唯一，不能仅根据文件名猜 revision 或 SHA。

| 属性 | 常规镜像（待下载） | 已安装的 16 KB 镜像 |
| --- | --- | --- |
| Package | `system-images;android-37.0;google_apis;x86_64` | `system-images;android-37.0;google_apis_ps16k;x86_64` |
| Revision | 6 | 7 |
| 发布频道 | `channel-0`（稳定） | 当前安装 properties 不记录频道，不推断 |
| API / Extension | 37.0 / 22 | 37.0 / 22 |
| ABI | x86_64（元数据声明可翻译 arm64-v8a） | x86_64 |
| 标签 | Google APIs、AI Glasses Compatible | Google APIs、16 KB Page Size |
| 最低 Emulator | 36.5.11 | 36.6.11 |

当前已安装 Emulator 为 37.2.12，满足两者声明的最低依赖。常规镜像预期为普通页大小；仍须启动后以 `getconf PAGE_SIZE` 实测，不把镜像名称当实际页大小证据。旧 16 KB 模拟器的系统图形崩溃仍属未解决的环境问题；常规镜像成功也不替代 16 KB 的动态验证。

待下载的官方 archive：

- URL：`https://dl.google.com/android/repository/sys-img/google_apis/x86_64-37.0_r06.zip`
- 大小：2,234,615,040 字节。
- 官方 SHA-1：`629e507fd5b737c2c836b12b52c81cd0e3b12399`。
- 独立下载目录拟为 `.tools/downloads/api37-google-apis-normal-r6-629e507f/`；使用全新 `.partial` 文件，成功下载后先核大小、官方 SHA-1，并额外记录 SHA-256。任一不符都不作为可安装包。
- 镜像后续安装目录必须与 `google_apis_ps16k/x86_64` 分离，不能覆盖旧目录。新 AVD 也采用独立名称与新路径，保留所有旧崩溃日志。

当前公共 `prepare-emulators.ps1` 仍把 API 37 指向 `google_apis_ps16k`；本任务不修改此脚本。未来普通镜像准备需在明确释放窗口后另行处理。禁止把 `-data` 与 `-wipe-data/-initdata` 组合当作保留旧 AVD 的保证；此前 QA 实验已经证实模拟器可能先清理默认 userdata。后续使用独立新 AVD，不 wipe 旧 userdata。
