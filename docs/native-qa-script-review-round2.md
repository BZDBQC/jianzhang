# 双端 QA 脚本第二轮独立审查

日期：2026-10-05。结论：**CLEAR，原报告的两项 HIGH、一项 MEDIUM 已关闭；本轮发现的结束时来源复核缺口已修复并复核。** 结论限于下面列出的脚本身份与审查范围，不代表实际平台回归已完成。

## 已关闭问题

1. Windows `RoundId` 在参数绑定阶段限制为字母、数字、下划线和连字符；`Qa-Child` 对派生目标重新进行绝对路径、QA 后代边界、文件类型和祖先链接检查。安装目标、文件用例、权限用例、卸载器临时副本和结果文件均使用该合同。含路径分隔符的 RoundId 在脚本正文执行前被拒绝，未创建输出。
2. Windows 安装 QA 开始与写入 pass 前均执行 `Assert-CurrentSources`：核对当前 Flutter Windows 源合同、每个实际 packaging/helper 源文件的 SHA，以及 setup 和最初冻结 sidecar 的 SHA；结果记录最初 sidecar SHA。Android UI 在设备测试前核对 release/source 合同及实际已安装 APK，在测试结束时重新核对当前源与最初 release manifest 身份。旧候选不能通过当前源核对。
3. Windows QA 在完整安装工作流内对专用 QA 登记键执行只读递归快照，包含全部值、类型和子键；每个升级故障用例比较完整快照。不是单独的注册表探测。本次审查没有调用该快照函数。

## 本轮发现并已修复的来源冻结缺口

修复前，Windows 安装 QA 及 Android 冷启动测量只在开始时比较当前源；测试期间修改源后，仍可能写入 pass/测量结果。现 Windows 开始和结束都调用同一 `Assert-CurrentSources`；Android 冷启动在结束时再次比较当前客户端源，且 release/source manifest 必须保持开始时 SHA。确认末尾校验位于结果写入之前。

补充核对 Windows 冷启动的新增来源保护：冻结 build manifest SHA，在测量结果写入前重新校验该 SHA 和完整当前 Windows 客户端源；原有执行文件与完整引擎、AOT、插件、运行库、资源 payload 前后核对仍保留。这里仅复核该新增保护，不替代其既有完整审查。

## Android UI 交互复核

读取实际 UI 树并根据当前 ScrollView 可视范围滑动；查找并触发账单节点前检查节点处于可视范围，避免按旧屏幕坐标假定按钮存在。横屏检查使用旋转后稳定 UI 树和真实截图宽高。输出目录必须为本次新目录，已存在目录拒绝覆盖；远端 XML/PNG 使用本次唯一名称。设备设置恢复及失败状态记录保留。

## 本轮验证与边界

四份脚本 PowerShell AST 均为零错误。执行三项仅参数绑定的拒绝检查：含路径的 Windows RoundId、Android API 25、非 SHA 的冷启动配置哈希，均在正文前被拒绝，输出不存在。证据：`.qa/native-qa-script-review-round2-7f6fb3a3c6324d82a92e9c500f508047/evidence.json`。

本次没有执行实际安装器、卸载器、注册表 API、ADB、模拟器或性能采样；没有修改实现。实际安装、设备交互、性能门槛和最终三轮同候选回归仍须由执行方完成。Windows 10、Android 真机及真实短信验证边界保持未验证。

## 审查身份

| 文件 | SHA-256 |
|---|---|
| test-windows-installer.ps1 | 1e7ec4ef747e8a83b611ca3831577bdcd1d99bd8d87a46eb1e7315c8d6d55cd9 |
| test-android-ui.ps1 | bd3143ee917af7648bd8bd308581d403d2fb3f3029435e392b3b5e2f56eb5bdf |
| measure-android-startup.ps1 | dfdc828fb1c27614860ca60ba10918b7710cb9848a24129db82575f103634ea4 |
| measure-windows-startup.ps1 | b4d1cd7630c0ad0feada67d33a09dbb53296f368cf773e348ab044e347787f3e |

CRITICAL：0。HIGH：0。未解决 MEDIUM：0。审查结论：**CLEAR（限定上述身份和范围）**。
