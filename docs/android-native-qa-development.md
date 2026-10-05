# Android 原生开发验收记录

本记录是开发检查，不属于连续三轮完整干净回归。Windows 10、安卓真机及真实短信服务仍未验证。

## 当前实际证据

生产 APK：`releases/android/jianzhang-2.0.0.apk`，版本 `2.0.0+3`，包名 `com.jianzhang.ledger`。15:48 的开发产物 SHA-256 为 `3adde28bae3df5efcfe7d8ee07dc2d76d3006c56e3d15628ada81fdbfa9b95c4`，用于 API 29/33/36 开发检查。加入 SafeArea 后重建产物 SHA 为 `4910bba7e0fd217cd66fd0828c2e578bb94c8901c6b860016a8ac73c6a6079de`，source SHA 为 `a8d4ed7844663a8af671e74cb7ca35c2e36b13bfcee12081b7da86b103f92b35`，用于 API 35 SAF 开发检查。后续候选身份以独立 manifest 为准。设备 UI 脚本先读取已安装 base APK 的实际 SHA-256，与 release manifest 一致才执行；不能以安装命令返回成功替代运行验收。

| 模拟器 | 实际执行 | 结果与证据 |
| --- | --- | --- |
| API 26 | 旧 1.0.1 到原生 2.0.0 同签名覆盖；UID、QA marker 保留；断网主页、实际支出/分类/备注保存、重开 | 当前新版 APK 重新完整复测待执行。此前 evidence `.qa/android-api26` 使用下午首个 APK，不能作为当前候选完整证据 |
| API 29 | 当前生产 APK 首装；首次断网直接使用；触控录入支出 12.34、收入 50.00、转账 10.00 与 0.25 手续费；分类、备注；关闭重开；滚动找到本轮三个独立备注；键盘、横屏、返回取消 | 通过实际操作，`.qa/android-api29-development-ui-3/evidence.json`，16 张截图和各操作 XML。稳定横屏补充图 `home-landscape-stable.png` |
| API 33 | 当前生产 APK 首装；实际三种记账、手续费、分类、独立备注、关闭重开、账单滚动、键盘、稳定横屏、返回 | 已通过，`.qa/android-api33-development-ui-3/evidence.json`。前两次为 QA 手势定位失败，修复后用新目录复测 |
| API 35 | 新 SafeArea release 首装、离线；真实系统文件选择器故障 provider 的可靠管道错误、损坏文件与不响应取消的停滞读取 | `.qa/android-api35-saf-development-r3`。错误拒绝不修改账单；返回 Activity 后自有 import cache 在 771 ms 清除，重开仍 0 笔。错误文案存在已知问题。开发十万笔性能仍待测 |
| API 36 | 当前生产 APK 首装、三种账单与手续费/备注、关闭重开、触控、键盘与返回操作均通过 | `.qa/android-api36-development-ui-2/evidence.json`。稳定横屏发现 body 与右侧系统导航栏重叠，见下方已知缺陷，尚不能整体验收 |
| API 37 / 16 KB | 已启动官方 16 KB 模拟器、确认 `PAGE_SIZE=16384`，当前 release APK 安装成功 | 系统图形环境阻断，未完成使用验收。初始 SurfaceFlinger 在 APK 安装前即持续崩溃，详见下方；安装成功不能替代功能与适配验证 |

## 开发过程中发现的 QA 问题

- API 26 的 root QA fixture 创建了应用 `files` 目录，却只 `chown` 而未修复 SELinux 标签。应用 SQLite 正确拒绝访问。仅对 QA 所建目录执行 `restorecon` 后，正确标签为 `app_data_file:s0:c512,c768`，marker 和数据保留，离线主页立即正常。前后标签及错误/成功屏幕见 `.qa/android-api26/selinux-fixture-*.log`。该第一次失败启动不计成功或启动性能。
- Android profile 的十万笔 fixture 使用逐条 `IOSink.write` 造成大量小 stream 事件，文件缓慢增长。VM 只读检查确认 main 与 Drift isolate 均在 Resume，没有被调试器暂停。原 host drive 在子代理容量中断时被销毁，根代理曾接管 existing VM；之后明确终止这次开发测试，保留 partial fixture 与日志。尚未进入正式保存、筛选、滚动及导出测量。测试输入改用 400 条聚合后重新测量，不改变输入字节和生产业务逻辑。
- UI 脚本第一次单行 PowerShell 返回值用 `[0]` 取成首字符，误读 SDK；清理不存在的临时文件又遮盖了原始错误。已改数组捕获，并独立记录 cleanup 错误。失败日志保留 `.qa/android-api29-development-ui-run*.log`。
- 初次账单断言只看当前 viewport，遗漏需滚动才能看到的收入。修复为遍历真实账单 ScrollView、收集本轮 UUID 后缀备注、保存每个位置截图。
- 系统旋转动画截图在 350 ms 时仍是中间帧。该旧图片保留，另存稳定截图；脚本改为截图前 `uiautomator dump` 等待系统 UI idle。
- API 37 / 16 KB 初次软件渲染环境的 SurfaceFlinger 因 `hasReadColorBufferDma` 断言持续 SIGABRT，`screencap` 同样失败，系统服务随后反复重启。完整日志 `.qa/android-api37-environment-full.log` 的首次系统崩溃时间早于应用安装完成，不能归因于应用。已保存首次与恢复尝试日志；进程级 renderer/feature 恢复正在检查，尚未取得可用系统屏幕或完整功能证据。
- API 37 的官方模拟器要求至少 4 GB RAM，QA 启动器仅为此 API 改为 4096 MB，其余 API 保持 2048 MB。[Android Emulator 官方发布说明](https://developer.android.com/studio/releases/emulator)。4 GB 恢复曾出现宿主 QEMU access violation，Windows crashpad 事件保存在 `.qa/android-api37-4096mb-software-held-1/windows-crash-events.json`；SDK 临时 minidump 后来自动清理，不作为持久证据链接。
- API 37 新 QA 分区配合 `-qt-hide-window` 能 boot、确认 page 16384，但未安装应用即再次发生相同 mapper/SF 错误。证据 `.qa/android-api37-qt-clean-3/gesture-boot-device.log` 与 `initial-overlays.txt`；默认 gestural 开启。尝试切 threebutton 的 overlay binder 命令阻塞，终止了唯一该命令客户端；console TCP 未回应，未取得可信截图。已结束这次诊断并恢复 API 35，不停用 SystemUI，也不把此环境阻断算作客户端通过。
- 这一实验曾误用 `-data` 与 `-wipe-data/-initdata`，以为只清理独占新分区；实际 emulator 先清理默认 API 37 QA userdata，导致初始化源失效。已报告并禁用该组合；仅此前无账单的 API 37 QA 分区受影响，API 26 的升级 marker、API 35 数据及所有原日志保留。后续独占新分区启动不带 `-wipe-data`，不能声称旧 API 37 分区已保留。
- SAF 停滞测试早期手势在系统选择器过渡尚未完成时点击导航，另一次断言假定“正在处理文件”是单独 semantics 节点；实际它与卡片文本合并，修复观察方法后完整运行。最后用关闭前后 `DB+WAL` 字节 SHA 比较导致 QA 假失败：正常关闭 checkpoint 会把 WAL 提交到主数据库并删除 WAL。保存此失败，另以只读 SQLite `integrity_check`、账单与暂存表行数及重新打开 UI 核对数据，不以文件布局变化判断账单变化。

## 已知产品缺陷

- API 36 横屏、三键系统导航模式下，强制 edge-to-edge 使主页 body 伸入右侧导航栏。稳定截图 `.qa/android-api36-development-ui-2/home-landscape.png` 与对应 `*home-landscape-idle.xml` 显示系统栏从 x=1794 开始，`下个月` 按钮与统计区域右边界却到 x=1857，右侧箭头被遮挡。API 29 的同操作右边界为 x=1731，正常避开系统栏。根代理已加入左右 SafeArea，独立审查批准并重建，API 36 新版实际视觉复测仍未完成，不能以源码修复替代验收。
- API 35 SAF 可靠管道错误被正确拒绝，但错误 snackbar 直接显示 `PlatformException(FILE_IO, Remote error: QA_RELIABLE_PIPE_FAILED, null, null)`，缺乏可操作中文说明。实际截图 `.qa/android-api35-saf-development-r3/reliable-result.png`。根代理正在修改用户错误映射并保留内部诊断日志；新候选还需实际复测。

## 可复用检查脚本

- `scripts/native-toolchain/test-android-ui.ps1`：实际生产 APK 触控检查；每次输出独立目录、唯一备注及临时 sdcard 路径；恢复原网络/旋转设置；错误保留原始 cause 与清理错误。
- `scripts/native-toolchain/measure-android-startup.ps1`：至少 20 次 release `force-stop` 冷启动；完整已安装 APK SHA、源码 manifest、原生 ledger-loaded 回调与新 PID 验证；通过唯一 QA log marker 隔离每次日志，采样 AMS `Fully drawn`，不依赖受拒绝的 `logcat -c`，不把 `am start -W` first frame 当账本就绪。
- `scripts/native-toolchain/test-android-saf.ps1`：当前可复用脚本加入合法 JSON 真实预览与主动取消、三种故障、全表 SQL 摘要、临时 cache、交付本地 APK 与安装 APK 及源码前后守卫；新增正常路径尚待实际运行。已执行的故障开发证据与未执行的新脚本分开记录。

新增脚本的独立审查及设备实测仍在进行，不能把脚本语法解析通过当正式验收。

性能固定配置的 `ramMB=2048` 是分配参数；`guestMemTotalKB=2532436` 是首次启动观测基线。API 35 后续启动实测 2532432 KB，相差一个 4 KB 系统保留页，不表示分配参数变更。每轮 raw 必须另外记录实际 MemTotal、page size、geometry、CPU、renderer，不能把首次基线冒充本轮观测；固定配置 canonical hash 继续由根代理统一管理。
