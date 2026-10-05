# 原生迭代独立复审，第十四轮 SAF 导航与命令输出

结论：**R14 导航仍 BLOCKED；Adb 输出转文本修复认可。** 冻结 pure fixture 33/33 通过，但完整实际 XML 回放发现 drawer 已打开时会直接返回背后文件标题。保存这一确定负例，等待只限 QA 流程的导航修复；本轮未执行真实 ADB。

## 冻结范围与通过证据

输入 `.qa/android-saf-provider-navigation-r14-freeze.json`。

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/test-android-saf.ps1` | `54a5ca75f1d6fc7b3d53f82a589d9350cf37b9423be5daddf4bb03237e247d9e` |
| `tests/native-qa/android-saf-script-fixtures.ps1` | `af157da2ba8aaf92a221a564ef5b1196f5a35abb9ef646166976359cff041f09` |
| `docs/native-android-saf-provider-navigation-round14.md` | `454035b01f1f8b59987d1787861b3bcc6e6388adae6bc15d5c48ac461247f734` |

读取 staged/unstaged diff、完整新 Open-Import/Adb 和 fixture 周边。独立目标 pure **33/33、failedCount=0**：原 20 项、11 个 tap 驱动导航场景、2 个真实 Adb AST 输出场景。两份 Parser 为 0 错误；脚本 SHA 在执行前后匹配。

- `.qa/android-saf-navigation-independent-r14-after-wrapper-fix.log`
- `.qa/android-saf-pure-fixtures-c104df3ca3384f7ca9e16714133cc8ca/result.json`
- `.qa/android-saf-navigation-parser-independent-r14.json`

最后一个纯输出负测刻意保留 fake 的 LASTEXITCODE=17。首次自有包装器错误地将此视为整组失败；最终包装器检查脚本成功及结果，记录这确为预期 fake 退出码。没有作者测试或产品失败被忽略。

## 实际 XML、时序与正常路径

原 `.qa/android-saf-release-r13/evidence.json` 为整体 failed，只有 `valid-preview-cancel` 一项：6 笔预览、domainUnchanged=true、cacheCleared=true。后续错误是找不到 QA provider；其余故障用例未通过。这个已执行子项保留，不提前算完整四用例通过。

特别核对 dump/Tap 的顺序：`006-valid-picker-drawer.xml` 是点击 Show roots 前的当前 provider 内容页；`007-valid-downloads.xml` 才是打开 drawer 后、点击 Downloads 前的层次树。006 的同名 breadcrumb/toolbar 不代表根项。实际 007 的 QA 根项是 `android:id/title`、TextView、clickable=false、bounds `[168,1125][714,1179]`，位于 roots_list 内；标题子节点不可点击并不妨碍行内坐标触控。018-picker 和 019–022-provider-root 是实际 Downloads 页面，尚未打开 drawer。

自有 `.qa/android-saf-navigation-actual-review-r14.ps1` 直接执行真实 Open-Import、Find-Node、Find-ExactDocument、Tap-Node AST；仅读取完整实际 018/007/006 XML。Open-Picker/Read-Ui 离线返回保存的整棵树，Adb 只拦截并核对 tap 坐标。只有正确 drawer/root 坐标能切换状态，不能靠轮询读取下一页。原 XML SHA 前后不变。

实际 Downloads→drawer→QA provider→三个精确故障文件的 **3 个正常路径**通过，root 选择器排除实际 breadcrumb/header、选择唯一根行。已在 provider 内容页直接返回三个精确文件的 **3 个正常路径**也通过。合计 **6/6 正常路径**，不是设备运行。

## [HIGH] 已打开 drawer 时匹配了 scrim 背后的文件

文件：`scripts/native-toolchain/test-android-saf.ps1:135` 的初始 `$titles` 与后续直返分支。

完整实际 007 hierarchy 不只包含 roots。它还保留背后 provider 页的 `可靠管道错误.json`：android:id/title、enabled=true、没有 visible-to-user 字段、bounds `[683,970][984,1024]`。同时存在实际可见 `drawer_roots` / `roots_list`，区域右边界为 735。

当 Open-Picker 返回这棵已经打开 drawer 的实际树时，初始 `$titles` 将背后的文件当作可操作文档，跳过 provider 导航；Find-ExactDocument 又返回同一标题。真实函数回放的结果是：**root taps=0，最终仍处于 roots，而预期是点一次 QA 根项进入 provider**。返回标题中心 `[834,997]` 在 drawer 之外，后续真实触控会落在 overlay/scrim 区域，无法以此证明打开指定故障文件。我们没有执行该触控或声称真实设备已经再次失败。

Synthetic 的“provider 已可见”测试树只有根项，没有实际背后文档，因此 33 组通过没有覆盖这个状态。

冻结复现：`.qa/android-saf-navigation-actual-independent-r14-29cdae6c7daa473f9851e00deeeb7736/evidence.json`，SHA-256 `8f5ccfd73ce80a2342c0cfe002d21716f82a0e1962f4d4afbc09790306ee9de1`。绑定当前 helper SHA 和三个原 XML hash，记录 **6 正常路径通过、1 实际 drawer 负例失败**。日志 `.qa/android-saf-navigation-actual-independent-r14-final-fixture.log`。首次自有 mock 有 XML 类型变量重用错误，修正后才完成真实回放；该构造错误不计产品 RED。

最小建议：在确认真实可见 roots_list/drawer_roots 时，优先从其祖先结构和有效区域内选择唯一精确 QA provider，再进入内容页选文档；不允许初始文档直返越过 drawer。也可仅对三个 QA 故障文件固定使用标准 drawer→实际 provider→唯一文件流程。保留 title/resource/类型/唯一性、child clickable=false 的兼容和所有数据/producer 限制，补完整 007 overlay 的 tap 驱动负测。不要放宽到任意同名 breadcrumb 或 toolbar。

## Adb 转文本与保留合同

实际 Adb AST 的内部命令仅替换为纯 PS fake，验证 Unicode stdout 与 ErrorRecord stderr 都完整转换为 string，commands 的 Depth 5 JSON 无 warning；完整 arguments、timestamps、exitCode 保留。AllowFailure 的 exit 17 返回且记录输出，非允许 exit 17 在记录后抛错。这个修复没有吞掉失败码，独立纯用例认可。

静态及保留的原回归确认 R13 编辑器/精确文件选择器、合法六笔预览取消、所有用户表 schema/列/排序行摘要、mode=ro 与显式 close、私有 DB 的一致复制及仅 tmp 副本 chmod、缓存检查、producer、严格五秒取消及早于三十秒的最终断言、前后本地/已安装 APK/manifest/fixture/source guard 均保留。没有生产源码或 APK 变更；不以这些静态保留代替实际故障用例 SQL/缓存证据。

## 验证边界

没有真实 ADB、SDK、AVD、EXE 或注册表操作。没有扩展到其他任务。原 R13 设备整体状态仍 failed，当前修改后的四项 SAF 必须重跑。Windows 10、Android 真机、真实短信及连续完整干净回归边界保持不变。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 1 | pending |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **R14 导航 BLOCKED — 等待完整真实 drawer overlay 的导航优先级修复和重新冻结。** 命令输出转文本范围认可，不代表实际四用例通过。
