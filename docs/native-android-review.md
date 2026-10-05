# Android 原生独立复审（第三轮）

日期：2026-10-05。范围：`MainActivity.kt`、Manifest、字符串资源、Gradle 的 minSDK/版本/签名配置，及 Dart 文件通道清理上下文。最终复核 Kotlin SHA-256：`E27B307743EA9DD4DB3EF0FE2229D45F39243B985CD74941CBF131D332189FDB`。Android 新文件未跟踪，staged/unstaged diff 无内容，按冻结文件审查。未修改 Kotlin/Gradle，未并行构建、启动模拟器或读取签名密码。

## Findings

当前未发现置信度超过 80% 的未解决 CRITICAL/HIGH/MEDIUM/LOW 问题。

本轮曾发现的 MEDIUM：原始 fd 复制未检查 reliable provider pipe 的旁通错误，已由根任务修复并复核。

File: `clients/flutter/android/app/src/main/kotlin/com/jianzhang/ledger/MainActivity.kt:170`

原场景：DocumentsProvider 使用 reliable pipe 并 `closeWithError(...)` 时，数据 fd EOF 本身不能表示成功。当前导入（170 行）和导出（188 行）均在 copy 返回后、PFD tracked 关闭前调用 `canDetectErrors()/checkError()`，异常进入现有 FILE_IO/owned-cache 或新建 document 清理路径，修复位置正确。官方 [ParcelFileDescriptor 文档](https://developer.android.com/reference/android/os/ParcelFileDescriptor#checkError()) 和 [AOSP AutoCloseInputStream 实现](https://android.googlesource.com/platform/frameworks/base.git/+/master/core/java/android/os/ParcelFileDescriptor.java) 均说明这种 EOF 后错误检查。它不能同步确认提供器稍后才发生的云端持久化失败；这类提供器行为仍需真实测试。

## 前两轮 findings 的闭合情况

| 之前的问题 | 第三轮静态结果 | 证据 |
|------------|----------------|------|
| Activity 销毁丢弃 pending、后台结果二次/晚到回调 | 已修正 | 288–291 行 finish 只移除并完成活动结果一次；307–320 行在引擎拆除前取消所有结果并清空集合；晚回调检查 destroyed |
| 阻塞 provider pipe 无法停止、活动 fd 未关闭 | 对已取得 fd 的 pipe 路径已修正 | 218–228 行先注册资源/信号再检查取消；248–272 行 O_NONBLOCK + poll 100 ms；294–304 行后台关闭描述符并取消信号，不在 UI 线程做这些 IO |
| 销毁清理快照之后才注册的 fd 泄漏 | 未发现此竞态仍成立 | 晚注册资源会在 tracked 的取消检查中抛错并进入 finally.close；信号在注册后的检查阻止销毁后新开 query/open |
| 导入复制异常时删除失败仍移除所有权 | 已修正 | 195 行仅在不存在或删除成功时移除；303 行同样保留失败项 |
| 已交付 Dart 的导入缓存在 Activity 销毁时失去所有权 | 已修正 | 177–178 行交付后仍留在集合，直至 release 或销毁清理；Dart importBook.finally 调用 releasePickedJson |
| 导出失败留下空/部分 document 且没有说明 | 已修正 | 198–199 行尝试删除新建目标，失败时返回 export_partial_error；没有删应用内源文件的路径 |
| 原生用户消息未使用资源 | 已修正 | 所有原生自定义用户消息使用 R.string，Manifest label 使用 app_name |

注册与销毁路径没有共用阻塞锁。集合为 ConcurrentHashMap key set；`activeResults` 的访问限于默认主线程通道处理、Activity 回调及 runOnUiThread。`onDestroy` 完成通道结果后立即安排后台资源清理，因此未发现将 provider 取消/close 阻塞转移到 UI 线程的代码路径。关闭同一 fd 的晚到异常会进入现有失败处理；取消后的结果不会再完成第二次。

query/open 虽已使用 CancellationSignal，仍依赖提供器配合取消。不能从静态代码推断所有提供器 Binder 调用都有 100 ms 上限：该上限适用于 poll 循环；常规文件/文件系统也不保证 O_NONBLOCK 会限制每次底层存储 IO。须由真实故障提供器测试确认其资源退出行为，不将未运行场景计为通过。

## 安全与配置边界

本轮未发现需移交 security-reviewer 的 CRITICAL 问题。标准 MAIN/LAUNCHER Activity 导出，没有新增深链或 WebView；`allowBackup=false`、`usesCleartextTraffic=false`。导出源 canonical dataDir 前缀包含目录分隔符；release 限定 canonical cacheDir 的直接子文件与 owned 前后缀。取消/清理只处理本请求创建的 document 或 owned cache，没有删账本数据库的路径。

minSdk 为 26，版本来自 Flutter pubspec，缺少 release 签名配置时拒绝 release task。APK 中的最终包/版本/minSDK、签名身份、升级保留账本与 ZIP/ELF 16 KB 校验仍需正式构建结果证明，不能据 Gradle 配置认定产物已通过。API 26–37 系统栏和键盘/旋转/返回行为同样仍需设备执行。

## 本轮验证与 pending

已运行：PowerShell XML 解析 Manifest/strings；自动核对 16 个 Kotlin R.string 引用、17 个字符串资源，缺失 0；读取并核对冻结源码 SHA-256。没有执行 Kotlin 编译或 Android runtime 测试。

仍 pending：正式签名 APK 构建；minSDK/版本/证书/升级安装；16 KB ZIP/ELF 与页大小设备加载；API 26/29/33/35/36/37；真实 DocumentsProvider 的停滞读端、停滞写端、cancelSignal、可靠 pipe closeWithError、删除拒绝/磁盘满；复制期间销毁、句柄晚注册、路径交付与销毁同帧、release 排队时销毁；账本保留与 owned cache 清理；冷启动 20 次及 p95。根任务负责构建及真实提供器测试。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 0     | pass   |
| MEDIUM   | 0     | info   |
| LOW      | 0     | note   |

Verdict: APPROVE — 仅指最终源码 Kotlin 静态审查无未解决 CRITICAL/HIGH 阻塞项。三轮发现的问题均已复核修复；编译与平台验收仍 pending，未批准平台交付。
