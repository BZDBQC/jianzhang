# 简账 2.0 独立客户端执行检查点

状态：实施中，尚未验收。最后更新：2026-10-05（亚洲/上海）。

## 固定范围

- Flutter 3.47，Android API 26+，Windows 10/11 x64；实际验收当前 Windows 11 和 API 26/29/33/35/36/37 模拟器。
- 本机 100,000 笔、无 8 MB 文件限制；云端 20,000 笔且实际请求体不超过 8,000,000 字节。
- 本机功能无需登录；短信保持空配置，禁止生产伪验证码。
- 同包名 `com.jianzhang.ledger`、原签名、版本 `2.0.0+3`；Windows 完整安装包且数据位于安装目录外。
- 旧浏览器账本以裸 Ledger JSON 导入，先预览、备份，再原子替换。原浏览器数据和输入文件保留。
- 同一候选完整回归连续三轮无问题方可完成；行为/交付修改清零。四小时巡检保持关闭。

## 工作分配

- 根代理：工程根配置、原生 Bearer 服务端接口、云客户端、文件服务、整合及最终验收。
- native_architecture_plan：工具链、Android/Windows 平台工程与安装适配。
- web_review：领域合同、后台 SQLite 仓库、共享样本、数据回归。
- windows_csharp_review：Riverpod 状态、响应式中文 UI、界面与端到端用例。

## 验收状态

| 项目 | 状态 |
| --- | --- |
| 领域/迁移/10 万笔数据 | 完整 24 项及 Unicode 补充通过；R2-1 修复后非 100k 回归 31 项、最终读取屏障 targeted 7 项及 owned analyze 通过，源码冻结待复审。100k debug 保存 P95 12 ms、查询 P95 51 ms，release/profile 尚未验收 |
| 云接口/鉴权/冲突/超限 | Node 原有+新接口 26 项已通过；Flutter 云/文件服务 8 项通过。尚未发布原生接口，真实 SMS 未配置 |
| Android 六个 API 与离线/升级/16 KB | 未执行 |
| Windows 安装与锁定/只读/登记失败 | 未执行 |
| 视觉/大字体/键盘/触控 | 首轮 60 项 Flutter UI 回归通过；原生实际截图、键盘/显示比例验收待执行 |
| release/profile 性能 | 未执行 |
| 独立审查 | 原生 TypeScript 鉴权/账本接口通过；Flutter 与安装审查发现缺陷，修复及复审中；Kotlin/C++ 专项待执行 |
| 连续三轮完整回归 | 0/3 |

Windows 10、安卓真机和真实短信属于明确未验证边界。旧 1.0.1 Windows 包登记失败，不能作为 2.0 的通过证据。既往注册表诊断命令被自动审批拒绝，不得绕过重试。

## 执行环境与进度

- Flutter 3.47.6 / Dart 3.13.5 官方 ZIP 校验通过，工程 93 个依赖已解析，pubspec.lock 已生成。
- Android SDK 36、build-tools 36、NDK 28.2、CMake 3.22 已部署；WHPX accel-check 成功。API 37 镜像官方路径为 android-37.0/google_apis_ps16k/x86_64。
- 工具子进程使用项目内 PUB_CACHE、TEMP/TMP、APPDATA、LOCALAPPDATA，并抑制 analytics；不修改 HOME/USERPROFILE/CODEX_HOME。生产数据目录仍用系统 path_provider，QA 数据必须隔离。
- 用户已安装 Visual Studio Build Tools 17.14.41，vswhere 确认 MSVC/CMake/SDK/ATL 完整且无待重启。完整 Windows release bundle 已构建成功，仍须修复后重建再验收。早期 unsigned PowerShell 错误通过直接运行 Microsoft 签名安装程序解决，未放宽执行策略。
- Dart shared golden 与领域/SQLite 完整 24 项真实 Flutter 回归通过；日志 .qa/flutter-domain-data-final.log。全 Unicode casing 修复后领域/SQL 针对性 5 项通过。公共合同与未验证边界见 [领域接口](native-domain-api.md)。
- 原生接口本地构建成功，Sites 通用 build helper 的 npm.cmd 路径解析失败；直接 npm run build 成功。发布仍需独立审查和最终工作流。

## 当前修复循环（尚未计入干净轮次）

- 所有写入绑定工作区身份与版本，防止延迟表单跨账本写入；列表/报表按工作区刷新，删除末页夹紧分页位置。
- 导出经同目录 staging 和单次系统替换提交；Windows 只读失败、筛选 JSON、Android 导入临时文件清理正在补回归。
- 验收门槛补独立轮次/时间、真实证据文件和包 SHA-256、原始样本核算，拒绝虚构通过数据。
- 安装包旧构建拒绝、完整 payload 预检、失败回滚程序与登记正在修复。旧快照 QA setup 仅为编译烟测，不能算安装验收。
- 六个 AVD 已准备完毕，API 26 已启动。Android 官方 Gradle 9.3.1 分发已完整下载并通过官方 SHA-256 校验；APK 尚未成功构建。

## 2026-10-05 下午开发测试检查点

- Windows 原生 profile 离线支出、收入、转账、手续费及关闭重开集成测试通过，实际截图已生成并检查：`.qa/native-windows-ledger-drive.log`。保存提示遮挡桌面按钮已修复，1000/1440 宽度的实际应用矩形与点击回归 2/2 通过：`.qa/flutter-notice-regression.log`。
- Windows 十万笔开发 profile 测试通过，30 个保存样本 p95 221.76 ms、30 个查询样本 p95 163.28 ms，1018 个滚动帧超过 50 ms 比例 0；CSV/XLSX/JSON 导出及恢复时导航、帧更新和事件循环均通过。原始记录位于 `.tools/temp/jianzhang-native-performance/evidence/windows-development-profile-1`。该开发构建不属于最终候选，也不计入三轮验收。
- Kotlin 文件生命周期、非阻塞 provider pipe 和可靠 pipe 错误检查已通过第三次静态复审；Windows C++ 已通过独立复审。设备故障测试与 Windows 10 运行仍未验证。
- Android Java 官方依赖请求使用现有系统代理后已连通。构建新发现测试插件注册器误入 release，正在修复官方生成流程与构建快照根/祖先 junction 防护，未更改系统代理、签名或执行策略。
- 安装事务的当前目录锁和初始/终态恢复日志问题已经修复并通过纯文件回归。随后发现成功升级会清掉安装目录内用户额外文件，正在补托管清单与保留/冲突保护；尚未进行完整安装或注册表故障验收。
- 替换回滚后孤儿备份的物理清理及清理故障状态已修复；领域 targeted 9/9、非十万笔回归 41/41、owned analyze 通过。真实强杀未提交 SQLite writer、Windows 只读残留继续记账和跨连接保护已验证；UI 提示行为与独立复核仍待根代理确认。性能测试补 provider 与实际账单结果就绪等待。上述修改将触发重建及复审，连续完整干净轮次仍为 **0/3**。

## 2026-10-05 15:35 修复循环检查点

- 原生完整 APK 已真实构建，2.0.0+3/原包名与原证书、64 位 ELF 16 KB 和 ZIP 对齐通过；Windows 完整 release bundle 已构建。最终产物因仅加 Dart if 花括号清理 analyzer 提示而需按当前源码再构建。
- 当前全部 Flutter UI/服务回归 97/97 通过，全工程 Dart analyzer 无问题。只读孤儿备份警告独立显示，重新检查和表单输入保护已验证。
- API26 同证书旧包覆盖升级保留 UID 和 QA marker。QA root 创建 files 缺少 SELinux categories 的测试环境问题已 restorecon 修正；随后真实首次离线、触控支出12.34/备注和关闭重开通过。单次启动值不作正式性能结论。
- Windows 安装第四轮 PS/NSIS review APPROVE，C# review 新发现 PayloadInstalled 后用户个人文件的新编辑会在失败回滚清理丢失，owner 正在修复并补断点重试测试。未执行真实 installer 或 standalone Registry probe。
- 验收 gate 加强固定配置 canonical hash、跨轮模式、两端分别8项性能指标；独立 review 发现动态功能日志跨轮复用仍可能误判，正在补结构化执行记录、独立日志 SHA 与真实 cleanRounds，未计验收。
- Android API35 profile 十万笔测试正在实际运行，仅 development 证据；最终固定配置记录 .qa/fixed-configuration.json，当前 hash 378e99165ba99851fc494384e814413fdd4fc8d6cd85582b2925f46fe9d57781。
- 当前仍为 0/3 完整干净轮次，未验证 Windows10 实机、Android真机、真实SMS。

## 2026-10-05 16:43 修复循环检查点

- API29、33、36 开发 release 的三种记账、手续费、备注及关闭重开已完成设备操作并保存证据。API36 横屏发现右侧系统导航栏遮挡内容，横向 SafeArea 已修复并通过两项几何回归与独立审查；当前 UI/服务 99/99 通过，全工程 analyzer 无问题，双端 release 正按当前源码重建。
- C# R6 的同句柄删除及拒绝原子替换已通过独审与短路径 145 项纯文件回归。新增确定缺陷：最终 payload 路径177字符仍可能产生262字符的内部退休文件路径并阻断清理。R7 正补所有内部路径的安装前预算检查，超限明确拒绝且保留现有安装和个人文件。
- API37 的16 KB镜像已确认页大小，但最初系统 SurfaceFlinger 在安装APK之前已崩溃。官方模拟器文档要求该API至少4 GB内存；正在自有AVD进程上恢复环境，不更改固定API35配置，不算API37运行通过。
- Android UI/source-manifest guards、双端冷启动样本脚本及测试专用SAF Provider均已独立审查。可靠管道错误、非协作停滞Provider的实际设备故障测试仍待完成。
- 完整 Windows QA/生产 EXE 已打包但尚未执行安装事务验收；由于新的界面及安装器修复，需要重新打包。所有开发通过不计入最终三轮，当前仍为 **0/3**。

## 2026-10-05 17:24 修复循环检查点

- R7 内部路径预算独立复审 CLEAR，156 项文件测试和12项打包检查通过；原最终177字符/退休262字符目录已在事务前明确拒绝，原安装及恢复树33个条目保持一致。默认安装目录与短QA目录用于后续完整安装实测；journal1175历史失败保留为真实证据，不推断原因，不加未经验证的重试。
- API35 release 的实际SAF可靠管道错误、损坏JSON拒绝、停滞producer期间导航/返回取消和缓存清除已完成开发验证；SQL完整性正常。原文案直接显示PlatformException的问题已修复，6项新错误UI回归和全UI/服务105项通过，analyzer无问题。
- Android十万笔profile开发测试已恢复100k并进入导出，但原JSON导出在数分钟内只输出部分文件。记录两次进度及18.65MB未完成导出的真实SHA后主动停止，结果明确为 aborted-development-test，不算性能通过，没有完整原始指标。
- JSON/CSV/XLSX在原500行检查点合批写出，保留顺序和原子发布。21份完整文件byte golden保持一致；29项导出、备份和中途失败回归通过，新11项经独立复跑通过。待实际API35完整profile验证改善，不能将静态批准当性能达标。
- 测试工具补全SQL领域摘要、APK/source/manifest前后冻结、取消前缓存存在及实际5秒上限；独审已抓住并关闭过期轮询仍可能误通过的测试缺陷。最终SAF脚本仍在逐增量冻结复核。profile原始采样移至导出前落盘并增加阶段日志，整体成功仍须导出和恢复完成。
- 生产/QA Windows EXE和APK开始按上述当前源码重建，Windows QA根缩短为 `.qa/i`；完整安装事务、固定配置双端正式性能、最终六API矩阵、原生云接口上线及连续三轮完整回归仍未完成，当前 **0/3**。

## 2026-10-05 18:30 修复循环检查点

- Android release R9 在 Gradle 2GB 堆/2 workers 配置下实际构建成功（81秒）；APK SHA256 `67bf5be16af367559404c22955ac5d4d9a38cf1f4d0127a1bc9099a9d86ccd51`，原签名、versionCode3、16KB ZIP/ELF检查通过。其后新增 Esc 修复，故该 APK 不作为最终当前候选。
- API35优化后十万笔 profile 的三格式导出、恢复、导航响应及阈值断言全部通过（2分31秒）。Flutter drive 默认结束后卸载 QA 应用，导致原始指标/PNG采集时已不存在；`.qa/android-profile-r9-complete/result.json` 明确 evidence incomplete，不算正式性能验收。后续 Android drive 使用 `--keep-app-running` 并先归档实际指标再卸载或切换签名。
- 独立审查已批准打包的 PowerShell null 参数最小修复与 Windows 原生键盘测试参数修复。重打包又实际出现 Win32 1175；旧 QA EXE和新候选均完整保留，ACL/属性/通常共享探针及隔离PE复制/映射实验未定位根因，不推断为杀毒软件或盲目重试。下一次使用受控诊断与唯一新输出路径继续完整安装验收。
- Windows原生640窗口实际DPI106/FlutterDPR1.10417和尺寸收敛、恢复已验证，但 Esc 无法关闭记账表单使 R9b 失败。客户端非可点击关闭遮罩同时禁用 Flutter 默认 Escape；新增局部快捷键调用 `Navigator.maybePop`，由原 PopScope 在保存中阻止退出。新回归运行前2闲时失败/1保存中通过，修复后3项通过、analyzer无问题，生产增量待独审和原生重跑。
- SAF R9b失败来自测试自己将每次XML放在 Downloads、按时间排到合法JSON前。脚本将XML/截图/SQL副本移到唯一 `/data/local/tmp` 并通过系统搜索精确定位JSON；8纯fixture及parser通过，实际正常6笔预览/取消、可靠错误、损坏JSON和停滞管道尚需独审后重跑，未将纯fixture计为设备通过。
- API37普通4KB官方镜像 revision6完整大小/SHA1校验通过、SDK Manager安装退出0；独立 `Jianzhang_API37_Normal` 4GB/4核定义已准备，未启动，不把新镜像准备或与旧镜像相同高级特性当运行成功。旧16KB环境失败证据保留。
- 完整源代码提交 `b3cd9f39e3a47af54a9a2427af56f42ff40589e9` 已推送纳入版本管理，Sites版本4已部署原生云API。真实HTTP7项通过：游客session200/configuredfalse、未登录ledger401、send/verify明确SMS未配置503、logout200、外来Origin403、旧Cookie接口session200；没有发送真实短信。证据 `.qa/native-api-live-r9/evidence.json`。后续仅QA和Esc代码编辑未自动重新发布该版本。
- 尚须双端R10完整构建/真实安装、SAF/原生窗口、API37及最终六API矩阵、保留原始样本的固定配置性能和同候选连续三轮完整回归；当前 **0/3**。Windows10实机、安卓真机、真实短信边界不变。

## 2026-10-05 18:55 修复循环检查点

- 第11轮独立审查批准 Esc 局部修复（3项回归及同帧保存/Esc边界验证）、SAF 测试隔离（8项纯fixture）和发布诊断（11项fixture），冻结7份源文件。真实设备及安装事务仍须复测，1175原因未定位。
- 新的只读探索发现 Windows `path_provider` 调用当前用户 `SHGetKnownFolderPath`，不由 APPDATA/LOCALAPPDATA 环境覆盖。现冷启动脚本20次默认启动会打开并更新真实默认数据库；未运行该测速。正在新增显式、严格绑定 `.qa` 和独立样本的数据库参数，正常生产无参数行为不变，配置错误不得回退真实账本；修复后重建并独立审查。
- API35 `adb emu kill` 返回0但进程未退出；核对路径、AVD和父子PID后，仅停止本任务拥有的23220/22572及其已核实子进程。交接独立官方 API37 Normal 启动验证，不修改原16KB AVD，不绕过 APK 来源守卫。此时最终干净轮次仍为 **0/3**。

## 2026-10-05 19:35 修复循环检查点

- 完整 Flutter 回归171项通过，含真实十万笔恢复/三格式导出/故障与视觉规则；全量analyzer无问题。启动配置10项和PS readiness条件18项分别独立验证；R12/R12b审查文档保留原Int32条件阻断与仅两括号修复证明，不把原阻断抹去。
- 双端当前生产源码已冻结并重建。Android APK SHA256 `476ed43a0d40a90fa618cd474ff16aae6913d72ddd222a9d6aca257150846b4c`，原签名/2.0.0+3/16KB静态检查通过；Windows生产EXE `releases/windows/Jianzhang-2.0.0-x64-setup-r12.exe` SHA256 `886a844636e867c06fe82967a6d4b5ed6f5858bd69d3c047dc695aade3799dba`，QA EXE `.qa/native-installer-r12-setup.exe` SHA256 `3b040531fe9fc9cebca2d991f149f37c9e1863a40b718f67524e36d3755c888a`。旧1175输出及候选原样保留，新唯一输出成功不等于旧失败原因已查明。
- Windows完整安装首次实际QA在 `HKCU/Software/Jianzhang/NativeInstallerQA` 创建登记项时被系统拒绝访问、退出2，安装器回滚，0个完整case通过。`.qa/native-windows-installer-r12/installer-results.json`保留失败。已将完整包及已审脚本准备给用户在普通PowerShell运行；复制路径漏斜杠后已提供正斜杠代码块纠正，外部结果尚未收到，不代写通过。
- Windows原生适配R12c通过：真实640/1024/1600外窗、当前DPI106/DPR1.10417、Ctrl+N/Ctrl+F/Esc、48dp触控目标和窗口最终恢复。9份实际截图及JSON按SHA归档于`.qa/native-windows-adaptation-r12c`。首次R12因root构建标识包含测试不允许的加号退出校验；R12b因DartWorker线程启动异常退出；停止本workspace Gradle/Kotlin后台进程、核实Dart可启动后R12c完成，不推断线程异常根因。
- 冷启动生产入口已严格隔离SQL；只读启动链探索确认首页不自动调用云身份/系统凭据。`.qa/windows-startup-payload-r12`为经过完整manifest匹配的生产打包payload逐字节复制，未执行installer登记，不算安装验收。真实首样本得到nativeReady后CloseMainWindow失败；独立单样本复现实际window存在/enabled但持续不可见，原因是测量脚本设置Hidden影响首次ShowWindow。正在修正主GUI启动/实际可见条件/失败诊断，原样本不算有效性能。
- API37普通官方r6/4GB实测软件和标准host后端均在APK安装之前反复SurfaceFlinger SIGABRT、screencap退出134、无可信PNG。软件证据`.qa/android-api37-normal-boot-r11-1a10bafee1a`；标准host证据`.qa/android-api37-normal-host-r12-1cdfd41f439a424f8ae7398692a7f1aa`，host后续日志请求超时且进程自行退出，原因未知，不伪造关闭成功。显式GLDirectMem/共享槽强制开启实验被自动审批以“blocked by policy”拒绝，未执行，也未通过其他工具/配置绕过。官方只读诊断记录在`docs/native-api37-graphics-diagnosis.md`，不把推断当修复。
- Android测试交接当前R12 API35正常模拟器，继续真实SAF四场景；最终原始30样本性能、20冷启动、其余API矩阵、安装全回归和连续三轮仍待完成，当前 **0/3**。

## 2026-10-05 19:57 修复循环检查点

- 当前R12 release APK 在固定 API35 配置实际完成20次全新进程冷启动，AMS Fully drawn p95 **1422 ms**，低于5000 ms；新PID、native renderer回调、前后安装APK及源manifest SHA均核对。原始样本/日志与实际运行配置保存在`.qa/android-coldstart-r12-release.json`，guest RAM2532436KB/4CPU/4096页与配置一致。这是当前候选的开发性能证据，不计完整干净轮次。
- SAF首轮实际退出1、四case未完成：DocumentsUI搜索控件为`AutoCompleteTextView`，QA脚本只识别`EditText`。四份实际XML、PNG和安装身份守卫保存在`.qa/android-saf-release-r12-a6f17675b601489b8a36b9376fd2f38c`；正在补严格资源ID/唯一性/控件类型回归再改选择器。原handoff的Home/force-stop仍留下外部picker task；首个冷启动尝试返回DocumentsUI且无客户端PID，退出搜索与picker后才开始上述20样本，不把预检失败当应用崩溃或性能样本。
- Windows可见窗口测量修复经独审发现最终deadline判定缺口：Refresh越过20ms测试deadline仍接受非零句柄。真实helper延迟刷新RED已留证，作者补最终elapsed判定后17组纯fixture/18 readiness场景通过，等待R12d独审。生产源码未变，不提前运行或记录Windows20样本通过。
- 用户侧完整安装QA结果仍未收到；API37图形栈环境阻断、最终矩阵及三轮完整回归仍未完成，**0/3**。

## 2026-10-05 20:03 双端冷启动检查点

- R12d 独立复审解除 Windows 最终deadline阻断，迟到句柄的真实helper场景正确拒绝；保留此前blocked资料。实际完整release payload随后完成20次新进程启动，p95 **1772.2725 ms**、最大1776.534ms，低于3000ms。20份样本都有非零自身可见窗口、close成功/exit0、只读SQL完整guest/sequence0/零笔；原始`.qa/windows-coldstart-r12-visible.json`绑定当前安装包886a844…和完整payload ec0d22…，每次SQL放在独立QA目录，未触碰真实账本。
- 当前候选的Windows与API35 release冷启动指标均达到约定阈值；Windows运行的是与生产安装器内容逐字节一致的完整payload复制，完整安装登记场景仍需外部用户执行，不以此替代安装验收。正在执行当前Windows十万笔profile全场景性能；Android四SAF场景、profile原始证据、最终六API矩阵与连续三轮仍待完成，**0/3**。

## 2026-10-05 20:09 十万笔与文件操作检查点

- 当前Windows profile完整真实驱动通过：保存30样本p95 **160.708ms**、筛选30样本p95 **121.748ms**，929滚动帧中超过50ms为0。三格式全量导出与十万笔恢复成功，5个IO阶段导航10.9–24.0ms、各自事件循环最大间隔28.2–35.9ms。五份原始JSON/PNG按SHA复制到`.qa/windows-performance-r12`，drive日志和当前来源/编译EXE绑定另存，派生summary清楚标明development-performance-pass，不能冒充完整轮次。
- R13选择器独审20组/真实XML回放9项批准后真实SAF重新退出1，第一case已完成：6笔旧JSON预览后取消、完整domainSQL不变、导入cache清空。随后故障provider选择失败，实际019–022 XML均在Downloads列表；OpenImport没有先展开根目录抽屉。`.qa/android-saf-release-r13/evidence.json`保留1case和真实错误，正在补OpenImport导航回归及最小QA修复，三个故障case仍未完成。客户端APK与源码未改。
- 官方只读核对发现不同API37.1/16KB r9镜像，声明最小emulator36.5.11而当前37.2.12已满足；原37.0普通r6及ps16k r7都无同包更新，没有同断言修复证明。准备独立安装37.1候选，保留原SDK/AVD，不启动、不强制内部feature；该候选后续须实际SDK major37/page16384/系统PNG和完整回归才可提供兼容证据。

## 2026-10-05 21:09 安卓性能与文件测试检查点

- 当前 R12 Android profile 用预编译 x64 APK实际驱动2分30秒，保持应用运行后在任何卸载之前按设备/主机 SHA 归档全部五份原始 JSON/PNG于`.qa/android-performance-r12`。测试用例执行通过，但性能验收失败：保存30样本 p95 **310.026ms** 超过300ms；查询 p95 **184.527ms** 通过；593滚动帧14帧超过50ms，比例 **2.3609%** 超过1%。派生summary明确development-performance-failed，不计干净轮次。三格式导出/十万笔恢复通过，各IO导航33.7–55.2ms，事件循环最大间隔45.3–61.0ms，均持续响应。正在只读追踪保存和滚动瓶颈，未降低阈值或改样本。
- 首次profile构建因Gradle JVM native commit失败退出，hs_err原始日志按SHA移出源码快照保存，源合同恢复一致。错误发生时可用pagefile仅78MB，不是已证实的Java heap上限不足。仅停止本任务旧模拟器后保留原2GB Gradle配置重建成功；未改全局pagefile/系统策略。诊断与当前编译来源在`docs/native-android-profile-memory-r12.md`及`.qa/native-android-profile-build-r12b.json`。
- R14 QA导航独审发现真实drawer叠层中误点背景文档，BLOCKED资料原样保留。R14b增加合法drawer祖先/边界/父行点击验证，43项纯回归、7项完整实际XML回放通过，独审APPROVE只允许真实SAF四场景复测。当前生产APK及源码未变；先安全归档profile证据，再恢复原签名release以执行实际文件操作。
- 官方不同包API37.1 ps16k r9已通过Java cmdline-tools19安装，并准备独立新AVD `Jianzhang_API37_QPR1_16KB`，标准4CPU/4096MB，无内部feature覆盖。原37.0镜像、AVD与emulator二进制保留。准备结果是prepared-not-booted，尚无SDK37/16KB/系统截图或应用兼容通过结论。CLI23.0先前exit0但缺包的尝试不计安装成功。
- 用户侧Windows命令再次在解析阶段失败：两行粘成一行导致AmpersandNotAllowed，尚未运行安装脚本。已提供仅一行、全部绝对路径的命令，真实外部完整安装结果仍待返回。最终六API矩阵、安卓性能整改、Windows完整安装及连续三轮未完成，**0/3**。

## 2026-10-05 21:23 当前原生文件操作复测

- R14b已审脚本在当前R12原签名APK真实4/4通过：旧Ledger JSON六笔预览取消、可靠管道错误、损坏JSON拒绝、原30秒停滞生产者导入Back取消；后者缓存714.79ms清空。5份实际domain SQL摘要含9表且内容SHA一致，70份原始SQL/XML/PNG/ADB日志按SHA归档，`.qa/android-saf-release-r14b/evidence.json`status=passed。测试后系统top确认客户端，Home/force-stop只QA包，ADB交还root。未将前三轮失败或纯fixtures代替本次真实结果。
- 新`.qa/native-windows-installer-r12-user/installer-results.json`记录真实r12usr执行，13:06:07–13:06:09 UTC，registration.create仍失败并回滚、0cases。用户明确确认从Windows开始菜单打开PowerShell执行，撤销“仅工具进程限制”解释。只读诊断发现当前工具token是Medium/IsTokenRestricted=false，工作区001有显式Low Mandatory Label、子目录/当前QA及生产安装包继承Low；尚无历史child token观测，不将目录Temp/Low单独作为进程身份证明。继续诊断，不修改DACL/完整性标签、系统策略或做独立注册表写探针。
- 源码/审查/QA修复检查点已提交Git `d3a36657b80666c018713110d399efe20c4ce898`。安卓性能未达标继续整改，下一次仅QA harness额外保留全部帧的build/raster时间和SQL result callback时间戳，原指标计时/阈值及全部totalSpan不变；回调间隔不是孤立SQL耗时，会明确标记诊断边界。

## 2026-10-05 22:03 正常安装验收副本与性能诊断检查点

- 新官方37.1 ps16k r9实际启动命令已确认SDK major37、full37.1、codename REL、page16384；预安装完整15.6MB logcat记录5次SurfaceFlinger SIGABRT，同一DMA断言。无正常系统PNG/完整CPU-RAM/客户端smoke，未安装APK；SystemUI缺失导致采集器空值汇总失败，原始输出保留并从已有stdout补事实，不补造截图退出码。parent14980自行退出原因未知，ADB为空后已交回，证据`.qa/android-api37-qpr1-boot-6dd2d29d503445658078fbc74ec6f839`。
- 安装文件标签诊断已写`docs/native-windows-integrity-diagnosis-r12.md`，官方MIC/NSIS证据及历史child token未观测边界明确。未修改原001工作目录、任何MIC标签或系统权限。首次正常Desktop任务副本复制与profile编译并发碰到SDK内部Gradle executionHistory.bin文件锁，复制真实exit1，原部分副本保留；自动审批拒绝含清理缓存与续传的整条操作（仅blocked by policy），未执行，也未交由子agent换工具执行同删除。
- 改用不同的无删除fresh稳定输入复制：新`C:/Users/RM/Desktop/jz-native-qa-r12b`，提前排除SDK内部生成的Gradle .gradle/build运行缓存，无源/数据删除、无DACL/SACL/标签改写，19449文件逐字SHA匹配，原Windows source61文件及Release15文件合同通过。`.qa/normal-windows-qa-copy-r12b.json`status source-and-payload-verified，22:01:53完成。复制build manifest只重绑定镜像bundle路径，保留qaCopyOrigin/原manifest SHA，明确不是重新构建。待原样已审脚本在正常新自有`.qa/i`打包并完成真实完整安装/卸载验收；旧Low环境失败未被抹去。
- 只QA performance harness增加默认false诊断开关，原30save/query/12fling/全部totalSpan/导出与cleanup逐字独审8/8通过；SQL callback Stopwatch与frame engine epoch未校准，记录明确禁止跨时钟相减。所有metric/operations附diagnosticRun bool，验收门禁拒绝非false诊断标记，旧缺字段证据兼容。真实RED→GREEN及TypeScript独审通过（所有8指标true/多种非法类型均拒绝、原p95公式未改、原证据SHA不变）。R15两份独审文档冻结。
- 首次diagnostic build命令误用不存在的Java目录，真实exit1保存；修正为已有JDK17.0.3.1和原gradle-cache后76s编译成功，`.qa/native-android-phase-build-r15b.json`含真实来源/时间/内存，profile APK SHA60153b5145e1bda8c17a58ec11420d168b386b85f39d9a735db57457cb214746。生产source仍1b7f30c...且正式APK476ed...未变。官方停止本任务Gradle，标准API35/2048MB/4CPU/software重新启动parent10792，后续trace严格不计干净轮次，性能整改尚未完成，**0/3**。

## 2026-10-05 22:28 安装与模拟器运行环境检查点

- 正常目录 QA 安装包已原样打包并校验：`C:/Users/RM/Desktop/jz-native-qa-r12b/.qa/native-installer-r12-normal-setup.exe` SHA `f9fe46e031de28c08ad408b8dc636cf9f1041854ea64fe7eb362ca935a941538`，其完整19文件payload仍为ec0d22…，客户端来源1379338b…；生产EXE复制后仍886a844…，未修改原工作区标签。正常副本build manifest仅重绑定bundle路径，明确记录原build manifest及全部复制证据来源，不能视为重新构建。完整真实安装/升级/回滚/卸载脚本继续执行准备，尚无通过结论。
- 第一 API35 parent10792已消失，退出原因未知。第二次标准启动由长驻父命令持有，owner1572和QEMU1552的创建时间及映像路径均匹配；22:20实际只读线程查询显示QEMU全部59线程Suspended、CPU0.796875秒，而parent仍在等待。Application Error事件1000记录22:07:33.4222154本任务SDK的crashpad_handler.exe自身异常0x80000003，原始XML按SHA保存；与QEMU挂起的因果关系尚未证实。当前可用物理内存约7.7GB、虚拟约9.5GB。没有解冻、改变作业限制或修改系统安全配置；新的profile APK尚未安装或执行，`.qa/android-phase-r15-runtime-state.json`明确offline-no-profile-execution，**0/3**。

## 2026-10-05 23:45 回归与性能对照检查点

- R17 安装恢复日志发布修复：只对确定的 Win32 32/33/1175 错误进行有界重试，不改权限、不删除旧日志、不改变回滚合同。独立 C# 静态审查通过；真实完整文件测试 179/179、打包检查 13/13 通过，记录在 `.qa/installer-journal-r17-full-regression.log`。完整新安装包实际回归尚未完成。
- R16 SQL 优化完成；真实全量 Flutter 测试 179/179，包含十万笔恢复导出。静态检查发现测试文件多余导入并修正，复查无问题。日志 `.qa/flutter-tests-r17c.log`、`.qa/flutter-analyze-r17b.log`。两个较早测试启动因进程配置路径不可写失败，原日志保留。
- 同一冻结 R12 profile APK 的两组诊断均真实完成并按设备/主机 SHA 校验归档。Impeller：保存 p95 309.436ms、681 帧中 9 长帧；Skia 对照：保存 p95 295.836ms、查询 p95 192.75ms、792 帧中 0 长帧。原始六份对照记录在 `.qa/android-skia-r16/archive.json`，分析在 `comparison-analysis.json`；实际启动日志明确 `enable-impeller false`。诊断不计正式轮次，配置差异明确保留，生产渲染配置未改变。冻结 APK 已另存 `.qa/android-phase-r15/frozen-profile.apk`。
- 正常目录 API37 ps16k 仍在安装应用前发生 SurfaceFlinger DMA 断言，不能完成截图或客户端验收；记录 `.qa/normal-api37-boot-r16-16b0c719a46346e98fdece6a6f8bb8f5`。停止的仅是已核对归属的测试进程，没有修改系统安全策略。
- Windows 新源码正在构建。关键测试仍未齐全，正式干净轮次 **0/3**，不能宣告完成。
Windows R17 actual installer regression: 47/47 passed; QA setup SHA 227b8411e5cac0f2478aa2714860802b82c5f310460b64cacf26ca6020f24e28; copied results .qa/windows-installer-r17-normal-results.json. API35 release UI: 16 screenshots/steps, status passed; source 8eedcd1bfcda3c78d77fc1ebcb4278beeb821c9c728149d7dfc7622ec3e7d33f; APK 9f186ad187c505c5e84d0641245f75caaf02d027aa73fff1e935deff80dc4394. New fixed-renderer profile build still executing; no formal clean round.

## 2026-10-06 R17 独立复审及安装验收检查点

- `docs/native-iteration-review-round16-sql.md`、`docs/native-iteration-review-round17-installer.md` 两项独立复审均 APPROVE；全仓 ESLint 实际 exit0。测试最终哈希变化唯一来源为删除冗余导入，已精确核对，新增测试最终8/8通过。
- R17 正常目录 QA 安装器实际47/47通过，覆盖首装、升级、18个升级故障注入、中断恢复、锁定/只读文件、卸载保留账本、17个首装故障注入、目录占用和不可写父目录。原始结果已按SHA复制到 `.qa/windows-installer-r17-normal-results.json`。生产候选安装器 SHA `15c38a3a27bb08b84a547eb082506f447214bc4de4cc95b835dad82b93649919`。
- 安卓 API35 新正式包真实16步界面回归 passed；APK SHA `9f186ad187c505c5e84d0641245f75caaf02d027aa73fff1e935deff80dc4394`，仍原正式证书 c39806…、versionCode3、16KB静态校验通过。开发 profile 的证书5be30f…与正式包不同，最初覆盖失败已记录；原六份诊断证据和profile APK归档完成后，仅卸载该模拟器的开发诊断包，正式新装成功。不能把此步骤称为旧正式版本的同签名升级验收。
- API35 UI真实检查首次离线、支出/收入/转账及手续费、关闭重开三笔保留、账单列表、横屏、字体放大、键盘、返回撤销草稿；16份截屏证据 `.qa/android-ui-r17-api35/evidence.json`。系统设置清理无错误。
- 新默认渲染配置性能 profile 编译476.6s未完成，取消已核对本任务的Gradle client6036及只读jstack helper16172，保留失败日志及 `.qa/android-profile-r17-stall.json`。官方 Gradle stop 无运行daemon；随后使用 `--no-android-gradle-daemon` 和进程内Kotlin策略重试，仅改变构建进程策略，不改变生产源码或运行配置。
- 尚无 R17 实际100k性能结论、完整安卓矩阵或正式干净轮次，仍 **0/3**。API37应用启动前图形故障未解决；Windows10/安卓真机/真实短信边界不变。
