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
