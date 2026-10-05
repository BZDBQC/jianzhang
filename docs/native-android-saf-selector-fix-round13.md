# R13：系统文件搜索框选择器修复（待独立审查）

R12 正式 APK 的真实 SAF 回归在合法 JSON 预览之前失败，原因是 API35 DocumentsUI 的搜索框 class 为 `android.widget.AutoCompleteTextView`，原脚本只接受 `android.widget.EditText`。实际四份 XML 都含有同一个搜索框；这是 QA 选择器问题，四个 SAF 案例仍未完成。

只修改 `scripts/native-toolchain/test-android-saf.ps1` 和对应纯 fixture。搜索框限定为两个标准 search_src_text 资源 ID、两种标准可编辑 class、enabled/clickable，拒绝显式隐藏节点、无正面积或格式错误的 bounds；唯一性检查和四次有界重试保留。实际 UIAutomator 搜索框 XML 没有 visible-to-user 属性，因此缺少该属性不会被当成隐藏。文件标题选择同时排除两种编辑器，防止查询文本被当成真实文件。没有扩大文件名匹配、取消系统文件选择器或修改 APK、客户端、Provider 和来源合同。

先补测试再改脚本。RED 使用原脚本 SHA `204fffef28340a6233672db9123531c52ba68fdbd57b33ca7550daf46b44b7e0`，20 组中 10 组失败、10 组通过，退出码 1；真实 API35 搜索节点逐字保存为独立 fixture。GREEN 20/20、退出码 0，两个文件 PowerShell Parser 均 0 错误。新测试覆盖 AutoCompleteTextView、旧 EditText、错误 ID、同名非编辑器、查询标题、重复编辑器、禁用/不可点击/隐藏状态、非法 bounds 和完整精确文件搜索；既有八组来源、Downloads 防污染和恢复预览断言仍通过。所有设备调用均由纯 mock 接管，没有运行 ADB 或模拟器。

证据目录：`.qa/android-saf-selector-fix-r13-d8cd149bab694afb90fd34400649178b`，包括 red/green 日志、原始纯 fixture 结果路径、Parser 结果和 freeze.json。

| 文件 | 冻结 SHA-256 |
| --- | --- |
| scripts/native-toolchain/test-android-saf.ps1 | 2c8eb2ff1cb209878bf54a85f41044c8e10364c5bdf0c8a748e2890bc7db4ecd |
| tests/native-qa/android-saf-script-fixtures.ps1 | 4fabcf73e75bc04348e2578c292b571e5ac12b74b5949bae6756c4509b4c596a |

R12 生产 APK SHA 仍为 `476ed43a0d40a90fa618cd474ff16aae6913d72ddd222a9d6aca257150846b4c`。独立审查批准后才可重跑四个实际 SAF 案例，纯 fixture 不能代替验收。下一次设备交接还须实际退出 DocumentsUI 的搜索和文件选择任务并核对 topResumed；此前只按 Home 和 force-stop 客户端没有清除外部 chooser，因此不能当成冷启动前置条件已经满足。
