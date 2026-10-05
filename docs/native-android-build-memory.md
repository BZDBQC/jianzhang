# Android 构建内存故障记录

2026-10-05 的 Android release 第 8 次构建失败。原始证据保留在
`.tools/android-release-build-round8.log` 和
`.tools/android-build-client/android/hs_err_pid15368.log`。

Gradle 报告 daemon 意外退出；对应 JVM 崩溃记录明确指出 G1 虚拟空间申请
2,600,468,480 字节时 `mmap` 失败，属于本机构建进程的内存分配故障。
该进程的原始参数为 `-Xmx8G`、`MaxMetaspaceSize=4G` 和
`ReservedCodeCacheSize=512m`。崩溃记录中的宿主为 15 GiB 级内存、12 个逻辑核心；
当时还需为安卓模拟器及其他工作进程预留内存。证据不能据此判定客户端运行时存在内存故障。

最小修复仅调整 `clients/flutter/android/gradle.properties`：堆上限 2 GiB，
元空间上限 1 GiB，代码缓存上限 256 MiB，并将 Gradle 并行 worker 上限设为 2，
减少同时进行编译工作时的内存压力。保留原有 OOM 堆转储参数及其他 Android 设置。
没有修改系统分页文件、全局 Java 设置、代理、签名或生产 Dart 代码。

此检查点只完成日志核对和配置静态检查；尚未执行修改后的实际 release 构建。
最终结果必须以调度者执行的新构建日志为准，原失败日志不删除、不覆盖。
