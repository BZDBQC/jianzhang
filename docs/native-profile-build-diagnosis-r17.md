# R17 Android profile 构建耗时诊断

检查时间：2026-10-06 00:06–00:09（Asia/Shanghai）。结论：**本轮存在 ARM profile 引擎下载进展，不能判为死锁或完全停滞。** 模拟器测试可明确只构建 `android-x64`，复用已有引擎缓存；正式 release 全架构安装包及应用源码保持原合同。

本检查只读当前日志、进程、指定构建中间文件和精确 Flutter profile 缓存，没有启动新构建、停止进程、运行线程转储、读取签名密码或修改环境。仅本报告按 Root 指令写入。

## 已确认的等待范围

当前记录为 `.qa/android-profile-build-r17c.log`。Flutter 进程 17792、Gradle client 22644、单次 Gradle daemon 11180 均属于本轮；daemon 日志明确 `currentDir` 为 `.tools/android-build-client/android`。`--no-android-gradle-daemon` 下仍出现本轮单次 daemon，与日志中“构建结束即停止”的状态一致。

00:06:59 时没有 Dart frontend 或 `gen_snapshot` 活动进程。daemon 保持两条到 `34.3.1.27:443` 的 TLS 连接，本地端口 51850、51851；client 等待本机 daemon。当前 quiet 构建日志只有 SDK XML 版本警告，没有具体任务输出。该警告本身不能证明耗时根因。

所用 Flutter engine hash 为 **`692136cb6582dbfc5af3fb33c2515a069f2f66d0`**，来自 `.tools/flutter/bin/cache/engine.stamp`。对应 Gradle artifact 版本均为 `1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0`。

| 精确 artifact | 同版本 POM | 同版本完整 JAR |
|---|---|---|
| `io.flutter:armeabi_v7a_profile` | 已缓存 | 未缓存 |
| `io.flutter:arm64_v8a_profile` | 已缓存 | 未缓存 |
| `io.flutter:x86_64_profile` | 已缓存 | 已缓存，45,670,964 字节 |

缓存范围限定为 `.tools/gradle-cache/caches/modules-2/files-2.1/io.flutter/` 下上述三个 artifact 的该版本，没有泛扫缓存。x64 JAR 为 `x86_64_profile/1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0/9960eb219cd237e77f88fc4968d8345d4db4c56c/x86_64_profile-1.0.0-692136cb6582dbfc5af3fb33c2515a069f2f66d0.jar`。

## 实际下载进展与元数据差异

00:09:03，通过只读 `FileStream`（共享 ReadWrite/Delete）读取两个正在下载的精确临时文件，结果如下。仅检查前 4096 字节中的 ZIP 签名与文件名，没有读取环境变量或凭据。

| `.tools/gradle-cache/.tmp/` 内临时文件 | FileStream 实际长度 | ZIP 中可识别的内容 |
|---|---:|---|
| `gradle_download6323716226443591661bin` | 5,265,073 | `lib/armeabi-v7a/libflutter.so` |
| `gradle_download9125454698757381196bin` | 5,432,423 | `lib/arm64-v8a/libflutter.so` |

此前同一轮 `Get-Item` 仍报告这两个文件分别为 3,979、31,497 字节，最后写入时间停在 00:03:13–14。**本次活动下载的文件属性没有反映实时长度；不能只用 `Get-Item.Length/LastWriteTime` 判断没有进展。**

独立进程计数也显示增长：00:06:59 → 00:08:10，daemon 11180 的累计写入从 9,118,776 增至 10,732,654 字节，写操作从 19,151 增至 20,530；CPU 从 66.671875 增至 67.265625 秒。结合 ZIP 内容，可确认两份未缓存 ARM profile 引擎正在下载。当前证据没有定位下载缓慢的具体网络原因，也没有证明任何 Java 线程死锁。

Flutter AOT 中间件曾在 23:54:30–32 生成三架构 `app.so`，本轮 `flutter_build.d`/`outputs.json` 更新到 00:03:10；`compileProfileKotlin` 目录更新到 00:03:11。但 quiet 日志与目录时间不能确定具体 Gradle 任务或线程的等待栈，不把这些时间当作线程转储证据。

## 最小调整与记录边界

Root 提供的对照：旧 R15 成功的 profile 构建明确使用 `--target-platform android-x64`，耗时约 76 秒；R17b/R17c 未限制目标，默认请求 `android-arm,android-arm64,android-x64`。当前验收模拟器只需 x64，因此下一次 profile 构建可恢复显式 `--target-platform android-x64`。这项选择只限制测试构建 ABI，不修改正式 release 的全 ABI 合同或性能测试源码。实际重建结果仍需另行记录，不能由本诊断视为通过。

保留 `.qa/android-profile-build-r17b.log` 和 `.qa/android-profile-r17-stall.json` 的历史事实：R17b 在 476.6 秒后由 Root 取消，`threadDumpUnavailable=true`；本检查没有取得线程转储。当前发现修正的是“仅据文件属性判断本轮无进展”的方法，不回填或编造上一轮的等待栈。

可复查证据位置：`.qa/android-profile-build-r17c.log`、`.tools/gradle-cache/daemon/9.3.1/daemon-11180.out.log`、上述同版本缓存及两个下载临时文件。本报告保留检查时的数值；下载完成或构建取消后，临时文件和活动进程可能消失。
