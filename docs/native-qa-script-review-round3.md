# Android QA 来源文件冻结补充独立审查

日期：2026-10-05。结论：**CLEAR，零新增 CRITICAL/HIGH**。本轮复核 Android UI QA 的原始 source-manifest SHA 新增保护，以及随后提交的 API 37 启动内存小改；不替代第二轮完整脚本审查或实际设备验收。

冻结 `scripts/native-toolchain/test-android-ui.ps1` SHA-256：`0ac57d7fd7a903308a49951d8609f7dbac64a86d4aa364518d834c595c09c941`。前后身份相同，PowerShell AST 零错误。

开始测试时读取并校验 release/source 语义合同后记录 source-manifest 原始字节 SHA（line 136）；结束时先重核当前客户端源与 release manifest，再比较 source-manifest 原始 SHA（line 196）。任何不改变语义摘要的 source-manifest 文件修改也能拒绝。该检查位于成功路径结束之前，异常写入 failure，finally 的 evidence 状态因此为 failed；证据记录开始时的原始 sourceManifestSha256（line 210）。设备设置清理与第二轮已核对逻辑保持一致。

独立验证只从实际冻结脚本 AST 提取这一个只含 Get-FileHash 的 if/throw 源文件保护，在自有 JSON fixture 上执行：未改字节通过，修改字节后明确拒绝。没有执行脚本正文、ADB、设备、安装器或 Registry，也没有更改实现。证据：`.qa/android-qa-r3-c1ff4191/evidence.json`。

## API 37 启动内存补充复核

随后提交的 `start-emulator.ps1` 冻结 SHA-256：`c472d24330ea8c36e9c7caf8df7e5e41f9aa0f83e3d7665e4d5946ffb0feae6f`。仅复核新增 memoryMB 分支及参数、日志引用：API 37 为4096 MB，其余五个约定 API 为2048 MB；Start-Process 的 `-memory` 参数与显示记录都取该变量。隐藏窗口和环境 finally 恢复保留。PowerShell AST 零错误，从实际 AST 提取纯赋值语句，六个 API 分支值全部符合预期；没有执行脚本正文、启动模拟器或调用 ADB。证据：`.qa/android-qa-r3-c1ff4191/emulator-memory-evidence.json`。

官方 36.6.11 发布说明要求 API 37 手机 AVD 至少4 GB RAM，当前4096 MB 设置符合此要求。[Android Emulator 发布说明](https://developer.android.com/studio/releases/emulator#36611-stable-jun-2-2026)。这项配置检查不代表该模拟器启动或性能验收通过；实际测试配置与原始测量记录须反映 API 37 的4 GB内存。

实际六个 API、横竖屏、系统设置恢复与 release 性能验收仍由执行方完成；Windows 10、Android 真机、真实短信边界保持未验证。
