# Android Kotlin 第二轮独立审查

日期：2026-10-05。审查对象：冻结的 `MainActivity.kt`，SHA-256 `DF14761C3F9F3C65CCBD950B271B35CB6CAA009B366B53E1D34B6926FBC67B00`，及 `strings.xml`、Manifest、Dart 文件通道调用端。只读 Kotlin/Gradle；本轮仅新增此报告。未执行 Kotlin 编译、Gradle 构建、APK 安装或设备测试。

## Findings

[HIGH] 取消标志不能解除已经阻塞的提供器 IO，销毁时未关闭活动流

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:201`

Issue: `copyCancellable()` 在两次 IO 之间检查 `destroyed`/线程中断，但 `input.read(buffer)`、`output.write(...)` 和流打开/query 本身可能阻塞。`onDestroy()`（236–246 行）只调用 `shutdownNow()`，没有保存并关闭正在使用的流/文件描述符，也没有对 query/open 使用 `CancellationSignal`。可用故障 DocumentsProvider 返回一个 pipe 并保持写端打开、不写数据：工作线程会停在 read，无法执行下一轮取消检查和 `use` 的 close。请求已正确返回取消，旧 Activity、线程及打开的 fd 却仍可持续保留；若销毁发生在临时文件加入集合之前，245 行的清理快照还会漏掉新建文件。前一轮要求的“销毁时停止资源使用”因此尚未完整实现。

Fix: 为每次操作注册取消信号与正在使用的 closeable/fd；销毁时取消 query/open 并异步关闭活动 IO。注册与销毁需要同步，确保销毁后返回的句柄会立即关闭，不能只对已有集合取一次快照。文件创建/open 前后都检查取消；最终清理不能依赖 read 返回。使用 applicationContext 的 resolver 做后台提供器操作，避免持有旧 Activity。保留现在的主线程结果一次完成保护。提供器可以不响应取消，应如实保留故障提供器设备验收。

Evidence: Java [`shutdownNow()` 仅尽力中断任务，不能保证不响应中断的任务终止](https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/concurrent/ExecutorService.html#shutdownNow())。Android [ContentResolver 提供带 CancellationSignal 的 query/open 方法](https://developer.android.com/reference/android/content/ContentResolver)，Android 的 [FileInputStream.close 实现会关闭 fd 并通知阻塞线程](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/+/refs/heads/androidx-constraintlayout-release/android-35/java/io/FileInputStream.java)。这是静态调用路径和平台 API 结论，本轮未运行故障提供器复现。

[MEDIUM] 导入异常路径在删除失败时仍放弃缓存所有权

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:174`

Issue: `file.delete(); unclaimedImports.remove(file)` 不检查删除结果。删除返回 false 时仍从唯一待清理集合中移除，后续 `cleanupImportsAsync()` 无法重试，也不会向用户说明残留缓存。229–233 行的异步清理正确保留删除失败的项，但异常路径绕过了这个行为。

Fix: 只有文件不存在或 delete 成功时才移除所有权；失败项保留以便再清理，并在当前 Activity 有效时用资源错误消息说明清理失败。跨进程重启的残留清理应仅处理确认由应用拥有且不再被活动请求使用的导入缓存。

## 已修正且未发现新增阻塞问题的路径

- `activeResults` 只在 MethodChannel 默认主线程处理器、Activity 回调和 `runOnUiThread` 中使用。`finish()` 先移除成员；`onDestroy()` 在 `super` 拆除引擎前取消所有尚未完成结果，再清空集合。后台晚到 finish 因 destroyed/成员校验被抑制，正常路径不会二次完成结果。
- 导入复制完成后仍由 native 持有，主线程确认 Activity 与请求有效才移交 Dart；销毁后的已排队交付会触发 native 清理。这个交付竞态已修正，阻塞 IO 及失败删除的例外见上述 findings。
- `submit()` 捕获线程池拒绝；release 操作也注册生命周期结果。canonical cacheDir 直接父目录与 owned 文件名前后缀限制保留。
- 导出失败会尝试 `DocumentsContract.deleteDocument`；非 document URI、提供器拒绝删除或抛错时返回明确“可能留有不完整文件”的资源提示。本轮未发现删源文件的路径。完整写入与 Activity 销毁同时发生时可能留下有效但未确认成功的导出文件；该文件不会破坏本机账本，应包含在取消测试中。
- 用户原生提示已迁移至 `strings.xml`，Manifest 标签已使用 `@string/app_name`。PowerShell XML 解析与 `R.string` 引用核对发现：16 个 Kotlin 字符串引用、17 个资源（含 app_name），0 个缺失资源；这只是资源静态一致性验证。
- Manifest 的网络/备份/导出组件边界与首轮一致，本轮未发现 CRITICAL 安全问题。

## 验收状态

源码审查不代表 Kotlin 可编译或平台验收通过。APK 构建、签名身份/版本/minSDK、升级保留账本、16 KB ZIP/ELF 与设备加载、API 26/29/33/35/36/37 系统栏/键盘/返回、故障提供器/磁盘满/销毁竞态和冷启动 p95 仍 pending。Gradle 下载状态由主任务维护，本轮没有并行运行构建。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 1     | block  |
| MEDIUM   | 1     | info   |
| LOW      | 0     | note   |

Verdict: BLOCK — 阻塞提供器 IO 的资源取消仍需修复；平台验收仍 pending。
