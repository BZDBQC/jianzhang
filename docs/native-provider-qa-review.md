# Android 故障文件 Provider 独立审查

日期：2026-10-05。结论：**静态审查通过，实际 SAF 故障场景尚待执行**。这是独立 QA 包，不是生产 APK，不能把其 Java 编译或资产核对当作手机导入、取消、可靠错误检测通过。

审查者未编写以下实现，未修改 Provider/build 脚本，未执行 ADB、Registry、Flutter SDK 或真实账本操作。

| 文件 | 审查 SHA-256 |
|---|---|
| `android-provider-qa/FaultDocumentsProvider.java` | `b60cc1baeca68b32ba38841c2d4316649dd234eb9a928a85215e912bd2d9ab34` |
| `android-provider-qa/AndroidManifest.xml` | `11a276508215eba8fe6363d3b61c570dd292156c4fe8d9429ce8fc1432ed1a29` |
| `build-android-provider-qa.ps1` | `8d622d84ae86668cdaee445b3588c25f6d00b82df281da0eadb1d1ca0674da7b` |

文件均位于 `scripts/native-toolchain`。若 Owner 后续修改上述文件，此表对应结论不自动适用于新源码。

## 可靠错误与数据来源

- `reliable` 先通过可靠管道写入完整 `assets/ledger.json`，随后调用 `closeWithError("QA_RELIABLE_PIPE_FAILED")`。导入方必须检测可靠描述符错误，不能只以 JSON 解析失败作为通过依据。
- `corrupt` 单独写入格式损坏 JSON 并正常关闭，是不同故障场景；它不能替代 reliable 路径的错误检查。
- 独立读取现有构建 APK ZIP，确认 `assets/ledger.json` 为 8142 字节，SHA-256 为 `d7b72b4bde897287c4434103ba9c0b6d7530b101ae6b21e6ae8562cedb40b2e1`，与真实 `tests/fixtures/native-ledger-v1.json` 完全一致。样本含 6 笔账单、3 个账户和 59 项分类；现有 repository 导入回归直接引用该样本。APK 有 `classes.dex`，完整 APK SHA 与构建 manifest 相同。
- 可靠通道错误在 EOF 后由消费方检测，是 Android 文件接口提供的机制；Document Provider 可返回只读管道。[Android DocumentsProvider 官方说明](https://developer.android.com/reference/android/provider/DocumentsProvider#openDocument(java.lang.String,%20java.lang.String,%20android.os.CancellationSignal))、[ParcelFileDescriptor 官方说明](https://developer.android.com/reference/android/os/ParcelFileDescriptor#checkError())。

## 停滞和生命周期边界

- Owner 明确确认 `stalled` 故意忽略 `CancellationSignal`，模拟不协作的第三方 Provider。线程等待 30 秒后关闭 writer；若 Provider 主动响应取消，可能掩盖客户端自身阻塞复制问题。因此不把这一故障注入行为判为生产缺陷。
- 该场景只用于验证客户端自己的非阻塞复制、Activity 销毁/重开响应、账本不变以及临时导入缓存回收。不能据此宣称 Provider 线程及 FD 在客户端取消时立即释放；Provider 端只具备 30 秒有界释放。建议在源注释中明确此测试意图。
- writer 使用 `AutoCloseOutputStream` 的 try-with-resources；正常、可靠错误、损坏内容、sleep 中断和 IOException 路径均退出该作用域并关闭 writer。reader 由客户端持有。没有 Provider Activity，故不应伪称测了 Provider 自己的 `onStop`。客户端文件选择过程进入后台本身也不能直接当成取消条件。

## 签名与构建隔离

- Manifest package/authority 为独立 `com.jianzhang.qa.faultprovider`；`MANAGE_DOCUMENTS` 与 URI grant 用于文件选择器访问，不复用生产客户端 package 或密钥。该调试包只进入唯一 `.qa/android-provider-build-GUID` 目录。
- 构建脚本先校验 workspace/ancestor/reparse 边界，再创建新输出；所有 native exit code 检查，APK 签名验证，Java/XML 源与账本 fixture 编译前后核对，`JAVA_HOME` 在 finally 恢复。随机生成一次性 QA keystore，不读取客户端 release signing。重建 QA 包签名会改变，重新安装时应只替换/卸载这个专用 QA 包，不能触碰生产包。

## 独立验证与验收限制

- PowerShell parser 与 AndroidManifest XML parser 通过。
- Java 17 `javac --release 8 -Xlint:all -Werror` 对当前源码及已存在 Android 35 jar 独立编译 exit 0，产物目录 `.qa/provider-review-javac-7c4bca39325a4f36b976c87127ccefba`。
- 现有 APK 只读核对目录 `.qa/android-provider-build-a17c12583fa6456da9a3fa1a6963bfcd`；未运行 Provider 或安装 APK。
- 未发现此冻结源码的确定 HIGH/MEDIUM。实际可靠错误文字/无假成功、30 秒超时、客户端生命周期取消、DB 不变、缓存与线程释放证据仍由 Android QA Owner 在隔离模拟器执行。Fixture 开发/打包通过不能替代这些运行结果。

## Owner 解释性补丁复核

Owner 后续只补充了有意忽略 CancellationSignal 的故障注入注释和 writer 的 finally 显式关闭；新 Java SHA 为 `8c0a87e5f167b16c07eda0cdced1fc1e2ea490bf81fbd4a00a367db45bc64d0d`。独立复核确认不改变非协作 stall 的测试目的，并以同样 Java8 lint/Werror 编译再次 exit 0，产物 `.qa/provider-review-final-013a05bfee4b4920958781555005e77f`。新 APK `.qa/android-provider-build-40432ac2a69341609c24e07645262f6c/fault-provider.apk` SHA 实际核对为 `75a66e2367f52b5806f71283e100032d3f41f8df10711e56ffed38e770ae8478`，manifest 的 ledger 样本 SHA 不变。此解释性补丁静态批准；实际 SAF 验收仍未由本审查执行。
