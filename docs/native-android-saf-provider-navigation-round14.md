# R14：SAF 故障文件 provider 导航与命令证据格式

## 实际复现和范围

Root 的 release R13 设备测试 `.qa/android-saf-release-r13/evidence.json` 退出 1。当前 APK SHA-256 为 `476ed43a0d40a90fa618cd474ff16aae6913d72ddd222a9d6aca257150846b4c`。首项 `valid-preview-cancel` 已实际确认 6 笔预览、全域 SQL 不变及导入缓存清理；后续 fault provider 导航失败，所以整次 SAF 验收未通过。

`019–022-provider-root.xml` 的完整 hierarchy 仍显示 Downloads 文件列表，并有 `android.widget.ImageButton`、`content-desc="Show roots"`、bounds `[0,63][147,189]`。QA provider 只在根目录 drawer 内，原 `Open-Import` 直接查找 provider，没有先打开 drawer。这是 QA 导航缺陷，不能据此宣称客户端恢复功能已失败或通过。

另一个证据格式问题是 `commands.json` 对原生 stderr 的 PowerShell ErrorRecord 对象进行深度 5 JSON 序列化，产生截断 warning 和大型嵌套对象。原 R13 文件和原始设备日志保留，未将此 warning 当作产品缺陷。

## 最小修复

仅修改 `scripts/native-toolchain/test-android-saf.ps1` 的两处 helper：

- `Open-Import` 在当前 picker 中识别目标标题；尚无文档/provider 时通过精确 `Show roots` 或 `显示根目录` 标准按钮打开 drawer。只允许唯一、有效且可交互的 drawer，随后定位唯一精确 QA provider，最后复用原有 `Find-ExactDocument` 的唯一标题选择器。编辑框、后缀名称、重复标题/provider/drawer及明确隐藏的文档拒绝；允许 provider 标题自身不可点击，点击标题坐标仍落在对应系统行上。
- `Adb` 采集 stdout/stderr 时逐条调用 `ToString()`，保存真实文本行而非 ErrorRecord 的内部对象。原 arguments、开始/结束时间、exitCode、`AllowFailure` 和非允许错误抛出行为保留。

没有修改 R13 搜索编辑器兼容修复、数据库全表比较、导入缓存检查、故障 producer、取消后 5 秒上限、客户端来源合同、APK身份或前后 SHA 守卫。未修改生产 Dart/原生源码、SDK、AVD 或发布包。

## 真正执行的纯回归

新增导航 fixture 直接抽取并执行当前 `Open-Import` AST，`Open-Picker` stub 返回真实 `Read-Ui`；实际 `Find-Node`、`Tap-Node`、`Find-ExactDocument` 和 XML 读取逻辑仍执行。仅拦截 ADB 命令，UI 状态只有在正确点击 drawer/provider 坐标后才变化。因此旧代码不能通过多次轮询凭空读到下一页。

- 保留原 20 项回归；新增 11 项导航回归覆盖 Downloads、provider/doc 已可见、中文 drawer、缺 drawer/provider/doc、同名编辑框及重复目标。
- 有效 RED `.qa/android-saf-provider-navigation-before2-r14.log` 退出 1；`.qa/android-saf-pure-fixtures-baaa6529c54b4574bafec9a02b429246/result.json` 保留 8 个失败。最初草稿日志 `before-r14` 额外包含单条 tap 数组被 PowerShell 展平导致的 fixture 计数问题，已在有效 RED 前修正，未计作脚本缺陷。
- 导航修复后 `.qa/android-saf-provider-navigation-after-r14.log` 退出 0，31 项通过。

命令采集 fixture 将实际 `Adb` AST 仅重命名为隔离别名，内部命令指向纯 PowerShell fake function，产生 Unicode stdout、ErrorRecord stderr 和指定 exitCode；从未调用 adb binary。

- `.qa/android-saf-output-strings-before-r14.log` 退出 1，两个实际 helper 测试均复现输出含非字符串 ErrorRecord；导航 31 项仍通过。
- `.qa/android-saf-provider-navigation-output-after-r14.log` 退出 0；最终 `.qa/android-saf-pure-fixtures-44f8ccd40d3a4ce4879ad703219a391e/result.json` 共 33 项通过。验证 Unicode 文本完全一致、深度 5 JSON 无 warning、完整 args/time/exitCode、允许 exit 17 仍记录输出，以及非允许 exit 17 先记录再抛错。

上述是 QA helper 回归证据，不是 release 设备 SAF 通过记录。本轮未执行任何真实 ADB、EXE 或 SDK/模拟器操作。冻结 SHA 清单写入 `.qa/android-saf-provider-navigation-r14-freeze.json`；独立复审后由 root 重跑完整设备用例，仍须确认 fault cases、严格取消时限、SQL 和缓存。

## R14b：真实 drawer overlay 及 provider 归属

R14 复审发现真实 `007-valid-downloads.xml` 含开放 drawer 和背后 provider 文档。背后 `可靠管道错误.json` 仍为 enabled=true，未提供 `visible-to-user=false`，bounds `[683,970][984,1024]`；仅依赖文档标题会将它错误返回。点击该中心点会落在宽 735px 的 drawer 外。不能将 `006` 的非 drawer 页面当作此边界证据。

完整 `007` 原始 hierarchy 为 40563 字节、SHA-256 `e1613242dba8b6f35ff2548bcb24133b04b637f5a4b8de64bb1bcce5bbd6db7e`。纯 fixture 以 gzip/base64 只做无损压缩，展开后先校验原始字节 SHA，再通过真实 XML 读取与 `Open-Import` AST 执行。fixture 不依赖该临时原文件，状态仍只由合法 tap 驱动。

先补此回归时 `.qa/android-saf-drawer-overlay-before-r14b.log` 退出 1，原 33 项仍通过，仅真实 overlay 新项失败；红证据 `.qa/android-saf-pure-fixtures-6bc4bc87279546298bdf569c23a70bbc/result.json`。这是真实完整 hierarchy 的失败，不是简化节点或自动推进下一页的假设。

此次导航策略统一为“确认真实 provider 根，再取文档”：

- 先通过 `roots_list` 的合法 `drawer_roots` 祖先、有效且互相包含的 bounds、各级可见/未禁用状态判断 drawer 已开放。关闭、明确隐藏、零面积、负坐标或孤立 list 不作为开放 drawer。
- 未开放则点击唯一标准 Show roots/显示根目录按钮；开放后只在该 list 后代中匹配唯一精确 QA 标题。toolbar/header/breadcrumb 和背后文档均不参与 provider 匹配。
- 标题本身 clickable=false 合法。向上查找该 list 内最近的可交互行，要求行及标题均在合法区域内、祖先未隐藏/禁用，再点击行。真实 `007` 的父行 bounds `[0,1079][735,1226]`，tap 为 `(368,1152)`，落在 drawer 内。
- 点击 provider 后才使用既有唯一精确 document selector；其返回的同一 hierarchy 中 drawer 必须已经关闭，文档/祖先也须有效可见。overlay 持续开放则拒绝，不点击背后文档或 scrim。

因此旧“文档文本已在场时零次导航”的 fixture 改为验证仍先正确确认 provider：两次 drawer/provider 导航后才返回文档。编辑框/重复文档测试也先确认 provider，随后拒绝文件选择；未放宽标题、来源或故障行为。

`.qa/android-saf-drawer-overlay-complete-after-r14b.log` 退出 0，最终 `.qa/android-saf-pure-fixtures-b13b1bef765e46808eb3fb930d19942e/result.json` 共 43 项通过：原 R13 的 20 项、R14 两项命令格式回归和 11 项导航语义，以及完整 overlay 与 9 组 drawer ancestry/区域/重复/闭合边界。保留 R14 的 ToString、depth5 无 warning、SHA/SQL/cache、producer 及取消后 5 秒规则。

本次未执行 ADB、SDK、AVD、EXE 或修改生产源码/APK，设备 SAF 完整重测仍待 root 执行。新冻结清单 `.qa/android-saf-drawer-overlay-r14b-freeze.json`；原 R14 freeze、RED 和原始设备证据保持，补丁前文档另保存在 `.qa/android-saf-provider-navigation-r14-doc-before-overlay.md`。
