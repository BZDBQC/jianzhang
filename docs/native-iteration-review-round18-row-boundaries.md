# R18 账单行 repaint boundary 对照独立审查

日期：2026-10-06。审查仅限 `clients/flutter/lib/ui/ledger_pages.dart:479` 的最小对照修改。未修改源码、未运行测试/编译/构建，也未重新触达设备。本轮仅新增此报告；生产 APK/EXE 仍为 R17，新源码对照尚无性能结果，后续实验标识为 `dev-r18-row-boundaries`。

## Findings

未发现置信度超过 80% 的未解决问题。对当前未传 key 的 TransactionRow，这次修改保留原账单行包装结构，仅移除 separator Divider 的 repaint boundary。

唯一 diff 为 ListView.separated 新增 `addRepaintBoundaries: false`，itemBuilder 显式返回 `RepaintBoundary(child: TransactionRow(...))`。对照唯一基线 `.qa/android-performance-r17/baseline-ledger-pages.dart`，文件其余内容逐字未改。

## 包装与行为核对

本轮读取本机 Flutter 3.47.6 源码（framework revision `5fc346839b5d0eef006ed8404392afb4dfae428d`），并由只读 explorer 独立复核 delegate 包装顺序。

| 检查项 | 静态结论与证据 |
|--------|----------------|
| 默认行 repaint boundary 等价 | SDK `scroll_delegate.dart:559–572` 原本对 builder 子组件依次包 RepaintBoundary、IndexedSemantics、AutomaticKeepAlive（含 _SelectionKeepAlive）、KeyedSubtree。新 builder 已返回同一个无 key RepaintBoundary，而 delegate 仅跳过该重复包装开关。旧/新行最终层次均为 `KeyedSubtree → AutomaticKeepAlive → _SelectionKeepAlive → IndexedSemantics → RepaintBoundary → TransactionRow` |
| Divider 仅少 repaint boundary | SDK `scroll_view.dart:1561–1566` 偶数 sliver index 是行，奇数是 separator；`:1575–1579` 保留所有 delegate 参数，separator semantic index 始终为 null。新 separator 结构为 `KeyedSubtree → AutomaticKeepAlive → _SelectionKeepAlive → Divider`，其余包装未取消 |
| keys 不变 | App 旧 TransactionRow 与新外层 RepaintBoundary 均未传 key。SDK 在自动包装之前读取 builder 返回组件的 key（`scroll_delegate.dart:559`），最终 KeyedSubtree key 两者均为 null；没有移走或丢失原 key |
| keepAlive 与 selection 不变 | `addAutomaticKeepAlives` 默认参数未改；AutomaticKeepAlive 和 _SelectionKeepAlive 的层次/开关保持，未把行或 separator 改为不同缓存策略 |
| semantics 不变 | `addSemanticIndexes`、semanticChildCount、行 index 映射未改；行 IndexedSemantics 仍在 boundary 外部，Divider 原本没有 IndexedSemantics。RepaintBoundary 没有新增语义标签、动作或语义边界 |
| layout 与字体缩放不变 | SDK `basic.dart:7544–7565` 的 RepaintBoundary 是 SingleChildRenderObjectWidget，创建 RenderRepaintBoundary；`proxy_box.dart:3486` 继承 RenderProxyBox，仅提供 repaint isolation。`:116–119` 将原 constraints 传给 child 并采用 child size，未增加布局尺寸、padding、clip 或 TextScaler。App `TransactionRow:102–240` 的 LayoutBuilder、950 宽度分支和所有 Text/Wrap 内容未变 |
| 触控与账单操作不变 | RenderProxyBox `:130–131` 向 child 传递原位置 hit test；行原先已存在同一 boundary。TransactionRow 的菜单、busy 开关、编辑/复制/删除回调未改，Divider 仍是原 Divider(height:1) |
| 筛选、分页与加载不变 | App `_query:351–377` 的 generation/scope/offset/CAS 捕获，以及 `:491–518` 的分页判断和页码未改；itemCount、builder index、查询与 FutureBuilder 状态处理也未改 |

这只是静态结构等价审查。repaint boundary 本身的数量和 paint/compositing 工作发生变化，实际 raster/scroll 成本可以升或降，不能由较少的 separator boundary 推断帧率改善。

## 源码与基线 SHA-256

| 对象 | SHA-256 |
|------|---------|
| 唯一 R17 基线 ledger_pages.dart | `a57d14dfa9e75a84b6e12729eb724d0c878138b31022ee679c816b693e49e3e1` |
| R18 当前 ledger_pages.dart | `76ef2b831add3c8542cec7c298b3a6a58bc55f2634d4200aaa92f16a6dfa484a` |
| 保持不变的 sqlite_ledger_repository.dart | `a6ca3fb957e2cd62ff92d86a9d93cc1cc254857eb102fbdeb7469594c1365b8d` |
| 保持不变的 sqlite_queries.dart | `3183fde2142b17299588ff2e5554b17972b6e562c9e4f43e72938fa66be26fe4` |

基线哈希与指定值匹配。实际 git diff 和基线对照 diff 只有上述一处改动；两份 SQL 源码哈希与 R16/R17 审查值一致。

## R17 原始性能证据保留及解释

本轮脚本从两组原始 samples 重算 >50 ms 长帧数量，并核对每组 5 个 host artifacts 的 SHA-256 与原 archive 一致。未修改原始记录；设备侧原始 SHA 验证沿用 archive 记录，没有在本轮重新测试设备。

| 原始子运行 | 帧数 | >50 ms 帧 | 比例 | 相对原记录 1% 上限 |
|------------|------|-----------|------|--------------------|
| `.qa/android-performance-r17/` | 695 | 87 | 12.5179856% | 失败 |
| `.qa/android-performance-r17-repeat/` | 611 | 4 | 0.6546645% | 通过 |

两个 archive 的已安装 profile APK SHA 均为 `3cad4c3fa5302cf390f2b9f71d3851e6696bd266c68a269754cad470035053bb`，source SHA 均为 `8eedcd1bfcda3c78d77fc1ebcb4278beeb821c9c728149d7dfc7622ec3e7d33f`，configuration SHA 均为 `378e99165ba99851fc494384e814413fdd4fc8d6cd85582b2925f46fe9d57781`。两次均是 R17；archive/summary 的 formalAcceptance=false。它们记录同一旧 APK 的运行波动，不包含本次 R18 源码变化，因此不能宣称 R18 修改使 12.52% 改善为 0.65%，也不能以第二次结果覆盖第一次失败。

## Pending

根任务后续需用新标识 `dev-r18-row-boundaries`、精确绑定新源码/profile APK 与固定配置运行对照，并保留原始样本。R18 是否改善滚动性能、触控/字体缩放/分页的运行时回归，以及最终发布候选验收均尚未在本轮执行。生产 R17 包不能作为此源码对照的测量产物。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0     | pass   |
| HIGH     | 0     | pass   |
| MEDIUM   | 0     | info   |
| LOW      | 0     | note   |

Verdict: APPROVE — 仅批准最小源码对照的静态结构等价性。性能改善与正式验收仍 pending。
