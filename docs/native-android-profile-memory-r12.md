# Android profile 构建内存诊断：R12

状态：诊断完成；尚未实测重建成功。没有运行构建、ADB、客户端或进程终止操作，没有修改客户端、Gradle 配置、SDK、AVD或分页文件。正式性能样本为 0。

## 直接证据

失败日志为 `.qa/native-android-profile-build-r12.log`，SHA-256 `fb978eea9c052e9c1380710b5899fb36511594a77b9c04b7aa1b0448164a51b6`。Gradle `assembleProfile` 约 15.1 秒后退出 1。

原始 JVM 崩溃日志已由 root 原样移到 `.qa/native-android-profile-build-r12-failure-88ad08ebae204b80837ab225507ae0a1/hs_err_pid23036.log`，SHA-256 `ef3d92904a15a05d3d6a91953b6e9f78b2d9157fd5a35ee78744fb2f6e82f4fe`，同目录 `evidence.json` 记录来源、归档、失败状态和零样本。

| 证据 | 实际值 |
|---|---|
| 崩溃类型 | G1 virtual space 原生 `mmap` 分配失败；`os_windows.cpp:3535` |
| 申请大小 | 91,226,112 bytes，约 87 MiB |
| 进程 | GradleDaemon 9.3.1，PID 23036，Oracle JDK 17.0.3.1 x64 |
| JVM 上限 | `-Xmx2G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m` |
| 崩溃时物理内存（行 837） | 总量 16218M，可用 5493M |
| 崩溃时提交额度（行 838，JVM 的 TotalPageFile/AvailPageFile 标签） | 总量 26458M，可用 78M |
| 崩溃时进程（行 839–840） | WorkingSet 416M，private bytes 462M |
| Java heap（行 196） | 已提交 158720K，已用 90628K |
| Metaspace（行 198） | 已提交 77696K，已用 76825K |
| Heap 地址（行 173） | `0x0000000080000000`，保留 2048 MB，Compressed Oops mode 32-bit |

最直接的解释是崩溃当时系统提交额度接近耗尽：约 78 MiB 的可用提交额度小于约 87 MiB 的原生分配。尚有约 5.4 GiB 可用物理内存与此并不矛盾。Windows 提交上限由物理内存和分页文件共同提供，不能仅检查可用 RAM。[Microsoft：系统提交内存](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/introduction-to-the-page-file#system-committed-memory)

`Xmx2G` 是上限，不能写成进程已经使用 2 GiB。实际 heap 使用约 89 MiB，故本次不是已证实的 Java heap 耗尽、依赖冲突或业务代码编译错误。日志中的 CompressedOops/HeapBaseMinAddress 内容是 JVM 通用建议；目前无需把它视为另一个确定原因，也无需改 GC、指针模式或 HeapBaseMinAddress。

## 最小风险的下一步

1. root 已停止仅本任务拥有的 API 35 模拟器，保留磁盘上的应用和账本数据。`.qa/native-android-profile-r12-owned-emulator-stop.json` 记录停止前后 FreeVirtualMemory 从 958312 KB 变为 2653520 KB；稍后的安静环境 WMI 为 FreePhysicalMemory 8104552 KB、FreeVirtualMemory 13081172 KB。这些是不同时刻的采样，额外变化的原因尚未确定，不推断分页文件自动扩容、其他程序退出或指针布局变化。root 没有修改分页参数。当前提交余量约 12.5 GiB，优先保持原有 2G 配置实测一次构建；不得与 AVD 启动、安装回归或其他重型构建重叠。
2. 如需减少本次构建的资源需求，在**实际 Gradle 构建调用**追加下述参数；保留原 target、Dart defines、profile 模式、source contract 和签名参数。不要修改冻结源码或项目 `gradle.properties`。

```text
--max-workers=1
-Dorg.gradle.jvmargs=-Xmx1G -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=128m -XX:+HeapDumpOnOutOfMemoryError
```

第二行必须作为一个完整命令参数传入，例如 PowerShell 参数数组中的单个字符串。`--max-workers=1` 与 `-Dorg.gradle.workers.max=1` 二选一。Gradle 官方规定命令行 `-D` 可覆盖 Gradle 属性；`org.gradle.jvmargs` 控制真正执行构建的 VM，单纯缩小客户端 `JAVA_OPTS` 不等价。[Gradle：属性优先级](https://docs.gradle.org/current/userguide/build_environment.html#sec:gradle_configuration_properties)、[构建 JVM](https://docs.gradle.org/current/userguide/config_gradle.html#sec:configuring_jvm_memory)、[worker 限制](https://docs.gradle.org/current/userguide/command_line_interface.html#sec:command_line_performance)

Flutter 本地 `flutter_command.dart:1088` 明确说明 `--android-project-arg` 被转为 Gradle `-P`，因此不要用它传 `org.gradle.jvmargs`。若保留 Flutter 外层调用，可在该单次构建进程中设置下述 `GRADLE_OPTS`，结束后恢复原值；本机 `gradlew.bat:75` 会将它们传入 Wrapper JVM。该语法仅供后备方案，本诊断未执行。

```powershell
$env:GRADLE_OPTS = '"-Dorg.gradle.jvmargs=-Xmx1G -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=128m -Dfile.encoding=UTF-8" -Dorg.gradle.workers.max=1 -Dorg.gradle.daemon=false'
```

内层双引号令带空格的 JVM 属性值作为一个参数传入。官方明确支持通过 `GRADLE_OPTS` 的 `org.gradle.jvmargs` 系统属性配置 daemon；不要把普通环境变量的较低优先级误套在已经由 Wrapper 转成 JVM `-D` 的值上。[Gradle：GRADLE_OPTS](https://docs.gradle.org/current/userguide/build_environment.html#sec:gradle_environment_variables)

`daemon=false` 在 client JVM 与构建所需设置不同时仍可能生成一次性 daemon，不能当成完全没有额外 JVM；它在本次构建结束后退出。实际新 daemon 上下文应确认 Xmx/Metaspace/codecache 生效。不要写入用户级 Gradle 配置、全局环境或覆盖现有 `JAVA_TOOL_OPTIONS` 网络配置。

降低这些上限是待实测的资源策略，不保证构建成功；可用提交额度释放仍是优先动作。当前没有 Kotlin daemon 引发此崩溃的实证，暂不附加 `kotlin.compiler.execution.strategy=in-process`；后续只有确实观测到独立 Kotlin JVM 压力时再评估，避免无必要的编译执行方式变化。[Kotlin：编译与缓存](https://kotlinlang.org/docs/gradle-compilation-and-caches.html)

## Source contract 与归档

JVM 默认把 `hs_err_pid23036.log` 写进实际 Android 构建工作目录。当前 source contract 会纳入 `android/` 下未列为生成缓存的文件；该新增崩溃日志因此会令源快照校验失败，不能扩大排除规则来隐藏变化。

root 已完成最小处理：验证源与目标均处于本工作区且无路径重定向，按 SHA 原样移动唯一运行时崩溃文件到新的 `.qa` 目录，校验归档 SHA 后立即重新核对源合同。结果回到冻结源 SHA `1b7f30c5bf3f23c480336fb86fc4132d372c7e821b068567641f37e53e6020bf`。无需删除日志、批量清理 Android 目录或修改生产代码。

下一次实际构建应使用新的日志文件名，记录退出状态、实际 JVM 参数、前后提交额度、源合同和生成 APK SHA。成功构建也不能替代后续 Android profile 的原始性能样本与双端回归。
