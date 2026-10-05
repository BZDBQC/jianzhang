# 原生迭代独立复审，第十三轮 SAF 搜索选择器

结论：**APPROVE — 本冻结的选择器修复没有未解决审查问题。** 独立 pure fixture 20/20、真实 API35 保存 XML 回放及补充矩阵 9/9、两份 Parser 0 错误。批准允许重跑真实 SAF；实际四个 SAF 用例仍未通过，不能将 XML/pure 回放计为设备验收。

## 冻结范围

输入 `.qa/android-saf-selector-fix-r13-d8cd149bab694afb90fd34400649178b/freeze.json`。

| 文件 | SHA-256 |
| --- | --- |
| `scripts/native-toolchain/test-android-saf.ps1` | `2c8eb2ff1cb209878bf54a85f41044c8e10364c5bdf0c8a748e2890bc7db4ecd` |
| `tests/native-qa/android-saf-script-fixtures.ps1` | `4fabcf73e75bc04348e2578c292b571e5ac12b74b5949bae6756c4509b4c596a` |

读取 staged/unstaged diff、实际 helper 和 fixture 周边代码。两个冻结 SHA 在独立 fixture 执行前后、真实 XML 回放前后及报告落盘前匹配。未修改作者脚本、fixture、生产客户端或 APK。

## 原始失败与实际 XML 核对

原真实记录 `.qa/android-saf-release-r12-a6f17675b601489b8a36b9376fd2f38c/cases/evidence.json` 为 **status=failed、完成用例=0**，错误 `System file search editor is missing.`，绑定 R12 APK `476ed43a0d40a90fa618cd474ff16aae6913d72ddd222a9d6aca257150846b4c`。原始失败不可改写成四用例通过。

独立读取上述目录实际保存的 `009`、`010`、`011`、`012-valid-search-editor.xml` 完整层次树。实际编辑器都是 `android.widget.AutoCompleteTextView`、`com.android.documentsui:id/search_src_text`，enabled/clickable=true，bounds `[210,78][1059,173]`，与只接受 EditText 的旧选择器不匹配。

新增选择器只接受 EditText/AutoCompleteTextView 和两个明确资源 ID `android:id/search_src_text` / `com.android.documentsui:id/search_src_text`。要求 enabled、clickable、非显式 hidden，以及合法非负坐标且宽高均大于零。找不到仍有界失败；多个候选直接报 ambiguous，不任意取第一个。原 DocumentsUI XML 没有 visible-to-user 属性，因此“未声明 hidden”被接受；这不是独立可见性或截图验收。

文件标题选择仍要求唯一、大小写精确 basename、允许的 title 资源 ID 和 enabled；明确排除上述两种编辑类，防止 query 自身同名被当成 JSON 文件。没有把真实选择文件替换成页面直调、直接导入接口或模拟成功。

## 独立执行证据

冻结 pure fixture **20/20、脚本成功**，模拟 Adb 只记录命令/回放自有 XML，不调用真实 adb。覆盖实际 AutoCompleteTextView、原 EditText/两种 ID、无关 ID/类型、重复候选、disabled/nonclickable/hidden、非法/负/零/倒置 bounds、query 与 title 混淆、精确系统 Search 输入和唯一文件选择。原八组的路径、无效 basename、重复/缺失文件、APK/manifest 漂移和预览/取消/SQL 合同检查继续通过。

- `.qa/android-saf-selector-independent-r13-after-wrapper-fix.log`
- `.qa/android-saf-pure-fixtures-18e9ab670341443c95076477c5fd4e94/result.json`
- `.qa/android-saf-selector-parser-independent-r13.json`

首次 pure 也得到 20/20，但自有命令包装器把未初始化 LASTEXITCODE 的 null 误判为失败；修正包装器的状态检查后再次独立运行成功。没有改产品或作者测试，这不计业务 RED。

自有 `.qa/android-saf-actual-xml-review-r13.ps1` 提取真实选择器函数，仅读取保存 XML；替换 Read-Ui 为离线返回节点，不装载生产 Adb 或设备命令。四个完整真实 XML 都选中正确 editor，原 XML SHA 前后不变。另补两种编辑器与两个 ID 的完整 2×2 组合，以及 AutoComplete query 带 title ID 时仍只选真实 TextView 文件，共 **9/9**。

- `.qa/android-saf-actual-xml-independent-r13.log`
- `.qa/android-saf-actual-xml-independent-r13-fd7c354e085d41ce97d4c58cc39d2c6a/evidence.json`

作者 RED wrapper 的 `result` 记录 10 项真实条件失败，GREEN 为 20/20；批准以本次独立执行为准。

## 保留的真实 SAF 与数据合同

仍从应用“恢复 JSON 备份”打开系统 picker、切换 Downloads、点击系统 Search、清空旧 query、输入严格 UUID basename、提交搜索和选择唯一实际 title。临时 XML/截图/SQL 副本继续在 `/data/local/tmp` 的唯一前缀内，只有目标 JSON 放入 Downloads。

合法共享六笔 Ledger JSON 必须实际到恢复预览，核对笔数后主动取消；验证缓存清除和 baseline/after SQL 摘要一致。故障 provider 的可靠管道错误、损坏 JSON 与不响应取消的停滞管道路径继续实际选择。停滞用例必须先确认非空 pending cache；Back 后最终时间严格不超过五秒，并早于 producer 三十秒，缓存与 SQL 不变。没有放宽这些断言。

Snapshot 仍 force-stop 唯一 QA app 后复制 DB/WAL/SHM，仅 chmod 自有 tmp 副本。Python 以 URI mode=ro 读取完整 sqlite_master 非系统表，包含 schema、列信息和按全部列排序的行摘要，并显式关闭连接；比较逻辑状态，避免 checkpoint 文件布局变化导致误报。没有降格到仅笔数核验。本轮未重新执行原已审 SQL 摘要 fixture，不将静态保留当作真实数据库无变化。

运行前后保留本地/已安装 release 与 provider APK、两 release sidecar、provider manifest、共享 Ledger fixture、客户端/provider source contract 的身份与 hash 检查。只允许 owned API35 emulator/QA provider；失败与 cleanup 错误均写 failed evidence，完成用例只在原实际断言全部通过后追加。Pure fixture 中真实提取的 APK/manifest 漂移拒绝条件实际执行并通过，但没有在真实设备上再次核对。

## 验证边界

没有 ADB、真实 app、安装器或注册表操作。原实际 SAF 四用例完成数仍为零；后续完整运行需要当前 APK/manifest/source guard、预览/取消/故障/缓存/全表 SQL 证据。Windows 10、Android 真机和真实短信仍未验收。此审查与 Windows R12d helper 的批准分别记录，不累计连续完整干净回归。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **APPROVE — 仅批准本冻结的 SAF 选择器与 pure fixture。** 真实四用例状态保持未通过，等待独立设备运行证据。
