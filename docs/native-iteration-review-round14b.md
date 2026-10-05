# 原生迭代 R14b 独立复审：SAF 抽屉遮挡修复

日期：2026-10-05。结论：**APPROVE，仅批准本次 QA 脚本变更进入真实设备复测**。R14 已复现的抽屉遮挡问题，在本轮独立实际 XML 回放中已修复。没有发现本次范围内尚未解决的 CRITICAL/HIGH 问题。

## 范围与冻结来源

依据 `.qa/android-saf-drawer-overlay-r14b-freeze.json`，只审查以下作者冻结文件；未修改作者代码、生产客户端或 APK。

| 文件 | SHA-256 |
|---|---|
| `scripts/native-toolchain/test-android-saf.ps1` | `088fc36d2d476ed268f2fc4bb2fec2037976a3ddd8ef7a497d9f1cda8e833bf6` |
| `tests/native-qa/android-saf-script-fixtures.ps1` | `1aadcb5e3f730f8644f9f92b9a1ac77a2670bcadce3bb20fab6ea9499796f164` |
| `docs/native-android-saf-provider-navigation-round14.md` | `db339d4c977e0f68d0cfb01f7076809f77b0aecc0a581ae18002e68380427b15` |

测试前后复核源码 SHA。已保留 [R14 BLOCKED 报告](native-iteration-review-round14.md)及原失败证据，不将其改写为通过。

## 独立证据

先完成以下纯本地执行，再通知 root“纯执行已结束”。此后只静态读取和保存本报告，没有执行 ADB、客户端 EXE、SDK、构建或任何新测试。

| 检查 | 结果 | 独立证据 |
|---|---|---|
| 作者冻结的纯脚本测试 | 43/43，失败 0；`nativeAdbUsed=false` | `.qa/android-saf-overlay-independent-r14b.log`；`.qa/android-saf-pure-fixtures-48c376f0ff5e42bdaaeaea2f6049c5e2/result.json` |
| 两份 PowerShell 文件 Parser | 两份均错误 0 | `.qa/android-saf-overlay-parser-independent-r14b.json` |
| 本复审独立提取实际 `Open-Import` 等 AST、回放原始完整 XML | 7/7，失败 0 | `.qa/android-saf-navigation-actual-review-r14b.ps1`；`.qa/android-saf-navigation-actual-independent-r14b.log`；`.qa/android-saf-navigation-actual-independent-r14b-8d61a41b52e940c098b0c080a7694577/evidence.json` |

独立回放使用 R13 保存的完整系统选择器层级，未用简化标题样本代替实际抽屉：

| 原始 XML | SHA-256 |
|---|---|
| `018-picker.xml`，Downloads 页面 | `2f8946d121b66e1592cbbcd9c2c59445664d014ee1e307aa308b4d63aafeb05a` |
| `007-valid-downloads.xml`，真正打开的 roots 抽屉，40,563 字节 | `e1613242dba8b6f35ff2548bcb24133b04b637f5a4b8de64bb1bcce5bbd6db7e` |
| `006-valid-picker-drawer.xml`，QA provider 文档页面 | `1905556daa4ed94b9442695a4b1ac3bf58cee1f66368ba558a4457b04bb387e9` |

以上文件位于 `.qa/android-saf-release-r13/`。006 是 Show roots 点击前的 provider 页面；007 是点击后的真实抽屉。输入文件 SHA 在独立回放前后未变。

三个故障文件分别从 Downloads、provider 页面开始，共六例。状态机仅在正确坐标点击后改变页面，均观察到 Show roots 点击 `(74,126)`，随后 QA 根的有效可点击父行点击 `(368,1152)`，最终状态为 provider。另一个用原始完整 007 已打开抽屉起步的旧失败例，现在先点击该父行一次，最终 provider 状态才返回唯一故障文档。回放中没有启动真正的 adb；坐标和状态证据不替代真实触控结果。

## 实现核对

`Open-Import` 已移除看到背景同名文件便直接返回的路径。故障导入统一确认合法 roots 抽屉及 QA 来源；返回文档前要求新的层级已关闭 roots 抽屉，且文档可见、有有效面积。

抽屉识别要求允许的 `roots_list` 资源 ID、允许的 `drawer_roots` 祖先、可见且启用的祖先链，以及列表完整包含于抽屉的有效范围。QA 标题只在该列表后代中匹配允许的 title 资源 ID，排除搜索编辑器、列表外标题、页头和面包屑。真实标题本身不可点击时，向上寻找位于列表内、启用、可见、有效且包含标题的可点击父行。多个抽屉或多个 QA 标题拒绝执行，未改为任选同名节点。

独立运行的 43 例包含原选择器/命令回归、完整 007 遮挡例及边界组：隐藏或无面积/负坐标的抽屉、缺失合法祖先、列表外标题、越界父行、无可点击父行、禁用父行、重复抽屉、点击 QA 根后抽屉仍未关闭、隐藏文档祖先。抽屉持续打开时不会返回背景文件或继续点击 scrim 后的文档。

嵌入的完整 XML gzip 样本校验原始字节 SHA，解压相关流均在 `finally` 释放。原 R14 的命令输出转换仍使用 `ToString()`，保留 Unicode stdout、ErrorRecord stderr、退出码 17 的允许/拒绝分支以及日志 JSON depth 5；这两例仍通过。

静态复核既有合同仍在：指定 owned API35/QA provider；完整客户端与 provider 源合同、release/source/provider manifest、本地及 installed APK 和共享 fixture 前后身份守卫；只读 SQLite 全表逻辑摘要；合法 JSON 六笔预览取消；拒绝/取消后 SQL 不变及缓存清理；停滞生产者取消前必须存在实际缓存，取消后最终 elapsed 超过 5 秒或已达到 30 秒均拒绝。没有以脚本导航修复减弱这些真实验收要求。

## 验证边界

本轮未运行任何真实设备导入。旧运行的一例合法 JSON 预览取消通过，不能据此声称本轮四个真实场景全部通过。可靠管道错误、损坏 JSON、停滞管道取消及合法 JSON 仍需在同一候选 APK 上完成新的实际 SAF 运行和证据归档。

本批准不包含性能测量、完整产品验收或连续三轮完整回归结论。Windows 10、Android 真机和真实短信仍未验收。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **APPROVE — R14b 冻结 QA 变更可进入实际 SAF 复测；设备四场景验收仍未完成。**
