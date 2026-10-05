# 简账 R20 本轮交付与检查报告

状态：R20最后一轮已完成，按用户2026-10-06“再优化一轮就停止”的要求停止循环。正式连续三轮验收仍为0/3；本轮交付为候选版本，完整兼容矩阵尚未验收。

本轮将保存事务的版本号更新与返回合并为一次SQLite操作，减少一次数据库往返；保持整数分、CAS、预算去重、事务提交后通知。上一轮已修复“提交后读取失败误报保存失败”。专项11项、全量182项测试通过，Flutter静态检查无问题，两项独立源码审查通过。

## 安装文件

| 平台 | 候选文件 | SHA-256 |
|---|---|---|
| Android | `releases/android/jianzhang-2.0.0.apk` | `a13b8394431bb3bea4d93fa64f766ea05e592f51287a086f57e08bffacdfea4f` |
| Windows x64 | `releases/windows/Jianzhang-2.0.0-x64-setup-r20.exe` | `0fec6e359dcb46d91e8574e09bfe4a54b6fd35bd2f004fbbb089d925ee1d6a7f` |

Windows可运行交付副本位于 `C:/Users/RM/Desktop/jz-native-qa-r12b/releases/windows/Jianzhang-2.0.0-x64-setup-r20.exe`，内容校验一致，文件使用普通目录默认继承；未修改ACL或系统策略。Android保持原包名、原签名、2.0.0/versionCode3，构建中全ABI原生库及ZIP 16KB静态校验通过。

## 本轮证据

- `docs/native-iteration-review-round20-returning.md`：源码独立审查APPROVE。
- `.qa/flutter-tests-r20.log`：182/182通过，包括十万笔恢复/导出及整数金额。
- `.qa/flutter-analyze-r20.log`：无问题。
- `.qa/revision-returning-red-r20.log`、`revision-returning-green-r20.log`：成本回归先失败后通过，专项11/11。
- Windows构建44.7秒，Android正式全ABI构建122.4秒。
- 安卓API35同签名R19候选覆盖R20成功；16步实际界面回归通过、重启保留三类账单、设置恢复无错误：`.qa/android-ui-r20-api35/evidence.json`。系统字号放大属于Widget覆盖，不列为本轮设备字体设置验收。覆盖安装时旧候选是空账本，不将其算作旧1.x带数据升级证明。
- Windows新安装器实际47/47通过，包括首装、升级、中文/空格目录、故障注入、中断恢复、文件占用/只读拒绝及重试、卸载保留数据：`.qa/windows-installer-r20-normalb-results.json`。最初因已登记的R19冷启动QA副本而拒绝异目录首装，现场保留；仅通过原QA卸载器清理该副本后重测。

## 本轮Android性能

API35 x86_64普通模拟器、WHPX、软件图形、1080×1920/density420、4虚拟CPU；profile保持默认渲染设置、未开启额外追踪、无并行构建。原始五份文件均经过设备前后与主机SHA校验，见 `.qa/android-performance-r20/archive.json`。正式APK仍包含全部ABI。

| 项目 | 实测 | 本轮结果 |
|---|---:|---|
| release冷启动，20次p95 | 1471 ms | 达标（≤5000） |
| 十万笔保存，30次p95 | 207.632 ms | 达标（≤300） |
| 十万笔组合查询，30次p95 | 169.635 ms | 达标（≤500） |
| 滚动大于50ms的帧 | 2/854，0.234192% | 达标（<1%） |
| JSON/CSV/XLSX导出与恢复 | 全部通过，恢复100000笔 | 通过 |
| 导出/恢复阶段导航p95 | 25.737–41.800 ms | 保持响应 |
| 五个IO阶段最大事件循环间隔 | 48.069 ms | 记录值 |

JSON/CSV/XLSX导出分别约4.97/22.24/33.15秒。事件循环最大值取各阶段记录的最大值；原始顶层字段只对应最后阶段，不用它冒充全程最大值。冷启动证据 `.qa/android-coldstart-r20-release.json`，性能明细 `.qa/android-performance-r20/summary.json`。

这些是单轮模拟器结果，不能作为真机性能或连续三轮稳定性的结论。R19和更早失败样本保持独立，不剔除后合并计算；本轮优化与测量改善不用于证明全部收益只来自一条SQL改动。

## 尚未完成的范围

- 全部安卓API26/29/33/35/36/37最终候选矩阵未完成；API37模拟器在安装应用之前出现图形进程断言故障。
- Windows10、安卓真机、真实短信发送未验证。短信服务配置留空，本机离线记账无需登录。
- 连续三轮完整正式回归未完成。此前不同候选/渲染实验及失败数据均保留，不合并为本轮通过。
- 全套安装/文件选择器/云端错误恢复/视觉尺寸矩阵尚未按同一最终候选完成三轮。
- 本轮Windows冷启动和十万笔界面性能未重测。R19历史冷启动1815.0468ms及更早性能记录不移算为R20。

迁移、分类、使用、导出与卸载的数据行为详见 `docs/native-user-guide.md`。JSON导入前先预览校验并备份；Windows卸载保留账本，Android卸载会清除本机数据，卸载前应导出备份。

测试模拟器已正常关闭；本轮不保留继续迭代任务，不重新启用原四小时巡检。SHA-256清单：`releases/SHA256SUMS-native-r20.txt`。
