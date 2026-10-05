# Android Kotlin 原生审查

审查日期：2026-10-05。范围：Flutter Android 的 `MainActivity.kt`、Manifest、Gradle、主题资源，及 Dart 文件通道调用端的相关上下文。Android 文件属于未跟踪的新客户端，因此 staged/unstaged diff 无内容，按当前文件审查。本轮只写审查报告，没有修改 Kotlin/Gradle，没有运行并行构建，没有读取签名密码。

## Findings

[HIGH] Activity 销毁时未结束文件请求，已提交的 IO 仍回调旧 Activity

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:175`

Issue: `onDestroy()` 仅执行 `fileWorker.shutdown()` 后将 `pending` 设为 null，没有向旧请求返回取消。等待系统选择器时被销毁，原请求不会得到终结；已开始或排队的任务也会继续。IO 成功/失败回调（142、147、150 行）不检查 Activity 是否销毁或请求是否仍有效。因此销毁期间的成功导入缓存可能交给已断开的 Dart 引擎，无法触发调用端 `finally` 的 `releaseFile`，大文件还会继续持有旧 Activity 并占用空间。`releaseImportedFile()` 的回调同样没有生命周期检查。这是代码路径审查结论，未声称已在设备复现。Java 文档明确说明 [`shutdown()` 允许已提交任务继续执行](https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/concurrent/ExecutorService.html#shutdown())。

Fix: 在 `super.onDestroy()` 前将待处理请求恰好完成一次为取消/生命周期错误；保存并取消 IO 任务，关闭正在使用的流，使用可协作取消的拷贝循环；所有回调用请求身份和销毁状态保护。未成功交给 Dart 的导入缓存由 native 负责删除；不要只加 `shutdownNow()`，流未响应 interrupt 时仍可继续运行。Manifest 已声明 orientation/screenSize 等 `configChanges`，普通旋转通常不会触发此销毁路径，应另测 Activity 显式重建、系统后台销毁和开发者“不保留活动”。

[MEDIUM] 导出失败后保留此次创建的空文件或部分文件

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:145`

Issue: `ACTION_CREATE_DOCUMENT` 已创建目标 document，写入或关闭流发生磁盘满、权限/提供器 IO 异常时，catch（149–154 行）只返回 `FILE_IO`。目标 URI 未被清理，文件管理器中会留下名称正常却不可恢复的部分备份。原账本和应用内导出源文件不会因这段代码被覆盖；问题在失败的导出产物。Android 官方说明 [`ACTION_CREATE_DOCUMENT` 创建新文件而不覆盖已有文件](https://developer.android.com/training/data-storage/shared/documents-files#create-file)。

Fix: 在失败/生命周期取消路径尝试删除本请求刚创建的 document（如 `DocumentsContract.deleteDocument`），记录并向用户说明提供器拒绝清理的情况；仅针对本请求新建目标，不能清理任意返回 URI 或原导出源文件。

[MEDIUM] 原生用户错误消息没有使用 Android 字符串资源

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:33`

Issue: 文件操作错误提示在 Kotlin 中直接写中文字符串（另见 55、63、91、95、112、132、153 行），没有 `strings.xml`。Android 原生消息无法随 locale 切换，也无法通过资源提供一致翻译。

Fix: 将用户提示放入 Android `strings.xml`，通过 `getString(...)` 使用。保留稳定的通道 error code。

## 已核对的代码边界

- 主 Activity 仅有标准 MAIN/LAUNCHER intent-filter；没有新增外部深链、WebView 或明文网络配置。`allowBackup=false`、`usesCleartextTraffic=false`。本轮没有发现需立即移交的 CRITICAL 安全问题。
- `releaseFile` 先 canonicalize，再限定 cacheDir 的直接父目录与 `jianzhang-import-*.json` 文件名，避免越界清理。Dart 导入端成功取得路径后在 `finally` 清理缓存，包括预览失败、确认取消和恢复失败路径。其覆盖范围不包括上述路径交付前的 Activity 销毁。
- 导出源限定在 canonical 应用 dataDir 下，路径前缀包含目录分隔符，并要求可读常规文件。SAF 使用 temporary URI grant，本次操作不需要持久化 URI 权限或广泛存储权限。
- Native 采用 64 KiB 固定缓冲区，没有在主线程读取文件；大文件复制没有内存整文件加载。Dart 预览逐项解析、每条 JSON 最大 4,000,000 字符、分批 staging，并在数据库事务中验证。恢复先备份再事务替换。此审查无法替代磁盘满/进程杀死的真实故障测试。
- `minSdk=26`，版本来自 `pubspec.yaml` 的 `2.0.0+3`，release 未配置签名时会拒绝构建。脚本还定义证书指纹、包/版本/minSDK、16 KB ZIP alignment、全部 64 位 `.so` 的 PT_LOAD alignment 校验。当前没有成功产出的 APK，因此这些产物校验尚未通过。
- `reportFullyDrawn` 由 Dart 在账本可用且首帧结束后调用；native 使用单调时钟和一次报告保护。`readyMs` 起点为 Activity 对象构造，不包含完整进程启动前段；最终验收应同时留存系统冷启动数据，不能将这里的数字视为已经完成冷启动 p95 测量。
- 系统栏没有旧版 edge-to-edge opt-out 属性；AppBar 与底部 SafeArea 提供了基本 inset 处理。Flutter 官方说明 [API 35+ 的默认 edge-to-edge 行为](https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge)。这里只确认代码配置，不确认 API 26/29/33/35/36/37 上键盘、手势/三键导航、横竖屏及系统栏图标均正常。

## 待运行的验收

签名 APK 构建与 minSDK/version 验证；已有版本升级安装且保留账本；16 KB 页模拟器加载全部 native 库；API 26/29/33/35/36/37 系统栏和键盘/返回操作；SAF 取消、缺失 DISPLAY_NAME、损坏 JSON、大文件、磁盘满、故障提供器；选择器等待或复制期间 Activity 重建/销毁后的请求终结、缓存清理及旧回调抑制；force-stop 冷启动 20 次记录 API、页大小和 p95。以上均为 pending，本审查未运行 Android build 或设备测试。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 1     | block  |
| MEDIUM   | 2     | info   |
| LOW      | 0     | note   |

Verdict: BLOCK — HIGH 生命周期问题需在合入前修复；APK、API 26–37 与 16 KB 设备验证仍未完成。
