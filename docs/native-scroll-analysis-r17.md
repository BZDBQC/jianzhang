# R17 滚动性能：只读分析与最小候选

记录时间：2026-10-06 00:22（Asia/Shanghai）。本次未修改源码、SDK、AVD、环境或启动参数，未构建、运行测试、调用 ADB、启动或停止模拟器，未执行外部进程性能测量。仅重新计算已有样本、核对本机 SDK 与官方文档，不干预主任务正在进行的同 APK 重复测量。

## 数据支持的结论

`.qa/android-performance-r17/archive.json` 记录当前 profile APK SHA-256 `3cad4c3fa5302cf390f2b9f71d3851e6696bd266c68a269754cad470035053bb`、source SHA-256 `8eedcd1bfcda3c78d77fc1ebcb4278beeb821c9c728149d7dfc7622ec3e7d33f`、默认 renderer、`diagnosticRun=false`。本次核对五份本机原始文件的 SHA-256 与字节数，均与既有归档一致。固定配置 SHA-256 为 `378e99165ba99851fc494384e814413fdd4fc8d6cd85582b2925f46fe9d57781`。

| 指标 | R17 结果 | 约定门槛 | 结论 |
|---|---|---|---|
| 十万笔保存 p95 | 30 样本，238.713 ms | ≤300 ms | 本项通过 |
| 十万笔筛选 p95 | 30 样本，229.120 ms | ≤500 ms | 本项通过 |
| 滚动 totalSpan >50 ms 比例 | 695 帧中 87 帧，12.5179856% | <1% | 未通过 |
| 滚动 totalSpan p95 / max | 72.688 / 154.605 ms | 附加观察值 | 不替代比例门槛 |

本次从滚动原始 `samples` 重新按 nearest-rank 计算，得到上述 695 / 87、p95 与最大值。该 JSON SHA-256 为 `313b1b8ba4645e0c598c849bbe77fa826bbf16d315df36aeb4e6d808c330fdbb`。原始 JSON 字段只有 metric、roundId、buildId、mode、configurationSha256、diagnosticRun 和 samples，**没有 buildDuration、rasterDuration 或逐帧阶段时间戳**。

[FrameTiming.totalSpan 官方定义](https://api.flutter.dev/flutter/dart-ui/FrameTiming/totalSpan.html)覆盖 vsync 开始到 raster 完成，不能等同于纯 Dart build 或纯 raster 耗时。现有 R17 数据能证明滚动指标失败，不能判断主要来自布局、绘制、栅格化、队列等待、软件 GPU 或宿主调度，也不能证明 SQL fast paths 导致这次恶化。

旧 R15 trace=true 默认 Impeller 对照（681 / 9 长帧，约 1.32%）和 Skia 对照（792 / 0）是诊断实验，代码、观测开销或 renderer 不完全相同。它们提示值得调查渲染路径，不能充当当前候选验收，不能证明启用某种 renderer 一定解决问题。

`integration_test/native_performance_test.dart` 的 trace 分支会记录同一 FrameTiming 的 build / raster 阶段，但 SQL readTrace 使用另一只、未经校准的 Stopwatch。禁止把 Stopwatch / DateTime 与 engine 时间戳相减，或据此认定 SQL 恰好阻塞某一帧。timings callback 的 flingIndex 也是批次抵达时的标签，不能当作每帧的精确 fling 归属。

## SDK 确认的候选

当前 `clients/flutter/lib/ui/ledger_pages.dart` SHA-256 为 `a57d14dfa9e75a84b6e12729eb724d0c878138b31022ee679c816b693e49e3e1`。BillsPage 第 479 行使用 ListView.separated，行是 TransactionRow，分隔符是高度 1 的 Divider，未显式配置 addRepaintBoundaries。

本机 Flutter 3.47.6 的 `packages/flutter/lib/src/widgets/scroll_view.dart:1515` 默认 addRepaintBoundaries=true，在第 1560 行将行和分隔符交替交给同一个 SliverChildBuilderDelegate；`scroll_delegate.dart` 第 561 行会把每个已构建 child 包进 RepaintBoundary。**因此简单 Divider 也有独立重绘边界，不只是账单行。** 这是 viewport / cache 内已构建 children 的数量，不能表述为十万笔全部同时建立合成层。

[SliverChildBuilderDelegate 官方说明](https://api.flutter.dev/flutter/widgets/SliverChildBuilderDelegate/addRepaintBoundaries.html)指出简单绘制内容可能不需要独立边界。[RepaintBoundary 官方说明](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html)说明它隔离 display list / Layer，并可能参与 raster cache。因此减少简单分隔符的层有合理实验依据，但 SDK 不保证这个列表在 Impeller 软件 GPU 上会变快。

**最小实验只改 BillsPage 这一个列表**：关闭 delegate 的自动重绘边界，手动保留每个 TransactionRow 的边界。下面是尚未执行的候选形状：

```dart
ListView.separated(
  itemCount: page.items.length,
  addRepaintBoundaries: false,
  separatorBuilder: (_, index) => const Divider(height: 1),
  itemBuilder: (_, index) => RepaintBoundary(
    child: TransactionRow(
      entry: page.items[index],
      view: widget.view,
    ),
  ),
)
```

保留默认 AutomaticKeepAlive、IndexedSemantics、separator 的语义排除、滚动物理、缓存范围、分页和 SQL 查询。不要把全局 TransactionRow 改为自动包边界，以免同时改变首页；不要添加固定 itemExtent / prototypeItem，行内容、备注、手续费与字体放大需要可变高度。

这个候选预期只减少分隔符的独立层。账单行仍有边界，且 SDK 本来就是在 delegate child 外包同一种边界。它不会主动减少 build、文字布局或 SQL 工作。分隔线会随祖先绘制重新画，可能抵消收益；层与缓存策略也可能在某些 renderer / 尺寸下退化。应实际核对滚动后文字与分隔线、菜单点击、弹出层、键盘焦点和语义顺序，不能仅以截图相似替代交互验证。

## 独立对照方案

1. 先完成主任务当前的同 APK、同模式、同配置重复测量，保留其原始证据。若结果波动很大，先记录波动，不能将单次差异归因于代码。
2. 若继续候选实验，只提交上面一个列表改动，独立审查后产生新候选 APK。使用原来的十万笔 fixture、profile 模式、默认 Impeller、原标准软件 GPU、相同 12 次 fling 的方向 / 距离 / 速度及现有加载等待，保持 trace=false。不改变 renderer、缓存范围、帧窗口、手势速度或阈值来获得较好比例。
3. 让原版与候选在相同安静宿主条件下各有重复样本，必要时做 A→B→A 顺序核对可逆性；每次记录完整 APK / source / config 哈希和独立 roundId。失败轮次也归档五份原始文件并核对设备与主机 SHA。报告每轮样本量、>50 ms 数与比例，不挑选最好一轮。
4. 候选必须完成既有保存、查询、三个导出与十万笔恢复的完整测试；验证行内容 / 总数 / 页码、筛选及编辑复制删除仍正常。复用已有手机尺寸与字体放大场景，并在桌面核对表格布局、鼠标菜单和键盘操作。不为不可变行高作假设。
5. 若仍不达标，或需定位来源，再使用单独 trace=true 诊断轮比较 buildDuration 与 rasterDuration；诊断结果标注观测开销，并保持不同钟源的边界。若无可重复收益或出现退化，仅撤回本实验负责的最小改动，保留其他人的代码与原始证据。

当前仅有一个有 SDK 依据、范围较小的实验候选。**未实施、未测量其收益；R17 滚动仍失败，整体性能验收和三轮完整回归均不能据此宣布通过。** 不使用此前已拒绝的 emulator 内部 feature flags、ACL、系统设置或官方镜像修改来改变测试条件。
