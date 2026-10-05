# 原生工具链状态

2026-10-05 更新；这是工具、编译与测试能力记录，不是兼容性验收结论。

## Flutter

- 官方稳定 release 索引实际位于 `https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json`。旧 `/flutter/releases/` 路径返回 HTTP 404。
- 选择 Flutter 3.47.6 / Dart 3.13.5，部署目录 `.tools/flutter`。
- 官方 SHA256：`a01bb0d26de91bc23c97cd9ccfaad281a612fb8304213fdd5df1119a09404796`。
- SDK 1,933,193,895 字节已下载、校验、解压；实际 Flutter 3.47.6 / Dart 3.13.5，日志 `.tools/flutter-version-ready.log`。
- 客户端 pub get 完成，日志 `.tools/client-pubget.log`。CLI 关闭遥测，PUB_CACHE、TEMP/TMP、APPDATA、LOCALAPPDATA 只在工具进程内指向 `.tools`；不更改 HOME/USERPROFILE，生产应用数据仍使用正常系统目录。

## Android

- 部署目录 `.tools/android-sdk`，已有 JDK 17.0.3.1。
- 工具包以 Google 官方 repository2-3.xml 发布的校验和验证；该索引提供 SHA1，不能将其描述为官方 SHA256。
- 首次 PowerShell 5.1 安装调用 Invoke-WebRequest 失败（IE 解析器 NullReferenceException），已改为 `-UseBasicParsing` 后重试。
- 已部署 command-line tools 23/19、platform-tools 37.0.1、emulator 37.2.12、platform/build-tools 36、NDK 28.2.13676358、CMake 3.22.1。
- 最新 SDK CLI 起初配置目录拒写，设置 ANDROID_USER_HOME 后仍有远程索引连接失败；官方 Java sdkmanager/avdmanager 19 工作正常。
- 直接解压 emulator 缺少 package.xml，AVD-manager 报未安装；已补官方同版本元数据，安装脚本也会从官方索引生成本地 package.xml。
- API 26/29/33/35/36/37 六个 AVD 均已准备；官方 API 37 包名为 `system-images;android-37.0;google_apis_ps16k;x86_64`。日志 `.tools/emulator-prepare-all.log`。只验证了 26 开机，其余尚未运行。
- API 26 已真实启动，serial `emulator-5554`、进程 PID 24112、SDK 26、boot_completed=1。最多运行一台 2 GB RAM 模拟器。
- Android 构建入口 `scripts/native-toolchain/build-android.ps1`，使用 `.tools/android-build-client` 刷新源码、pubspec/lock、资源；记录源码 SHA256，若构建期当前源码改变则拒绝发布。
- 包名 `com.jianzhang.ledger`，minSdk 26，2.0.0+3，armv7/arm64/x86_64，复用旧正式签名；不输出密钥。构建后验证签名、包信息、ZIP 16 KB 对齐和 64 位 ELF LOAD 对齐。
- 首次 Gradle wrapper 跳转 GitHub 卡在 ZIP 0 字节。一次 curl HEAD connection reset，后续官方 GitHub 地址可访问，正在下载官方 Gradle 9.3.1-all；官方 SHA256 `17f277867f6914d61b1aa02efab1ba7bb439ad652ca485cd8ca6842fccec6e43`。`install-gradle.ps1` 校验后预填相同 wrapper 缓存；wrapper 添加 SHA256 和 120 秒网络超时。APK 尚未构建或安装成功。

## Windows

- 本机 Windows 11 家庭版，工具进程非管理员；用户实际安装后，Visual Studio 2022 Build Tools 17.14.41 已就绪，路径 `.tools/vs-buildtools`，C++、CMake、ATL 可用，无需重启。初次用户安装的是 VS Code 扩展，不能提供 MSVC。
- AllSigned 可能拦截未签名安装脚本；可在管理员 PowerShell 直接执行 Microsoft 签名安装器，不改变执行策略：

  ```powershell
  & 'C:\Users\RM\Desktop\001\jianzhang\.tools\downloads\vs_buildtools.exe' --passive --wait --norestart --installPath 'C:\Users\RM\Desktop\001\jianzhang\.tools\vs-buildtools' --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended
  ```

- 原 Windows plugin symlink 权限不足；项目自有 junction 实测被 Dart 识别为 Link，Link.existsSync=true，Flutter 构建已使用它们，无系统策略修改。刷新前只解除链接本身，不递归删除 PUB_CACHE 目标。
- 首次构建与 Flutter tester 共享 build，sqlite3.dll 被测试锁定，报 install_code_assets / MSB8066。已通过 `.tools/windows-build-client` 独立快照隔离。
- 快照首次缺少 generated_plugins.cmake、随后缺少 package_graph.json；现已补齐 pub 元数据和生成注册文件。
- Windows release 实际构建成功（80.7 秒），入口 `scripts/native-toolchain/build-windows.ps1`。完整 bundle 在 `.tools/windows-build-client/build/windows/x64/runner/Release`，日志 `.tools/windows-release-build.log`，源码指纹 `.tools/windows-build-manifest.json`。
- Windows 安装器需分发全部 DLL/data 和 VC runtime。必须在 Windows 10 实际安装、运行和升级回归；Windows 11 编译不能证明 Windows 10 兼容。

## 测试硬件

- 本机约 16 GB 内存，C 盘剩余约 262 GB。
- CPU 属性最初报告虚拟化 false，实际 emulator -accel-check 证明 WHPX installed and usable，API 26 已开机。
- 模拟器按 API 26/29/33/35/36/37 顺序准备，最多运行一个；没有运行的版本必须列为未验证。

工具安装记录不得替代真实 APK 安装、桌面启动、离线记账、导入导出或性能回归。

- Android SAF 的 `jianzhang/files` channel 流式导入导出，不传大 bytes，取消返回 null/false；单生命周期只允许一个文件选择操作。
- `jianzhang/performance.reportFullyDrawn` 由 Dart 在数据库可用且首帧完成后调用；Activity TotalTime 不等于可记账时间。最终冷启 20 次使用 force-stop，不清账本，记录 API/页大小与 p95。
- 绿色账本图标复用旧正式资源，Windows 标题为“简账”。最终修复后须重建双端相同候选，完成真实设备功能回归和连续三轮验收。

## 后台交接 checkpoint

- 已退出：首次 Android build session 43896（wrapper 卡下载后停止）；Windows 最终成功 build session 67316；AVD prepare session 63558 完成日志。
- Gradle 官方 ZIP 下载 session 32404 / curl PID 22224，最终应为 234,893,460 字节；12:54 文件约 28.5 MB，继续下载。
- 顺序 Android pipeline session 97642：等待该 curl 退出，执行 install-gradle.ps1 验证 SHA256/预填 cache，再执行 build-android.ps1。日志分别 `.tools/gradle-install.log`、`.tools/android-release-build.log`。下载失败或构建期间源码变化必须报告并重新构建，不能使用旧 APK。
- 当前运行模拟器仍为 API 26 / PID 24112 / emulator-5554，日志 `.qa/emulators/Jianzhang_API26.out.log` 和 `.err.log`；其他镜像只有准备结果。

## 打包审查修复 checkpoint

- 上述 sub-agent 后台 session 在代理结束后终止，不能继续依赖；Gradle 下载已由 root 自有 session 29747 接管。此代理不再下载或启动后台 pipeline。
- `source-contract.ps1` 是双端构建和 Windows 打包共用源清单/哈希算法，覆盖平台工程、生成插件、pub 元数据、lib 和资源。构建版本与 pubspec 相同；实际 Flutter machine version/revision/channel/Dart 必须匹配官方 3.47.6 记录。
- 新 Windows build manifest 为 schema 2，包含完整 source/payload 文件长度与 SHA256。旧 schema-1、源码变化、DLL 缺失、bundle 被修改都会拒绝打包。最终候选须重建，早期 bundle 不作为新候选。
- Windows packager 不修改 build bundle，在受控 snapshot 注入 CRT、README，并记录实际 CRT 版本/库 SHA；NSIS 编译后再次验证当前 source、build payload、snapshot、打包源码、helper/config 未变，才以同卷替换发布 setup。
- `environment-scope.ps1` 在 finally 恢复各工具改过的进程环境；旧变量不存在时使用 Env provider 删除，避免 PowerShell 将 null 变成空字符串变量。
- Flutter 安装器检查现有 SDK 实际 machine version；错误版或不完整目录先在受控 staging 完整解压验证，替换时保留旧目录并在失败时恢复。
- NSIS 负责 UI、同卷 staging 解压和 uninstaller；Windows 内置 .NET Framework 4.x 的 `installer-transaction.cs` helper 负责真实安装事务。helper 为 winexe，不闪出控制台窗口；不下载运行时、不触碰账本目录、不运行独立注册表诊断。
- 事务预检全部 payload 父目录类型、真实创建/改名/删除权限、旧文件读写与替换权限及占用、空间与路径边界。candidate 解压完整并校验后才移动旧目录到完整备份，随后提交整个新目录，避免混版本。
- 登记前保存全部旧注册值/类型/子键和快捷方式字节、时间、属性；每项登记/shortcut 有写前 journal。失败还原完整旧 payload 与所有被改入口；恢复失败保持 marker/备份并返回失败。进程中断后下一次真实 installer 恢复 journal。
- 成功提交后完整旧备份留在 `安装目录.__jianzhang_transaction`，下一次 installer 或 uninstaller 校验候选身份后清理。先持久提交再清理，避免部分删除 rollback 备份后仍声称可恢复。
- QA helper 仅 QA 编译允许 `/QAFAIL=N`（throw，自动 rollback）和 `/QACRASH=N`（exit 99，NSIS 同样退出并留下 journal，供下一次运行恢复）；production helper 不含这些触发代码。`steps.log` 在 QA root 记录编号和阶段。
- Windows native 就绪时间从 wWinMain 开始，DB-ready 请求后经平台消息重新注册 native frame fence + ForceRedraw，确认该帧绘制再返回/输出 `JIANZHANG_READY` JSON。COM RAII 与 GetMessage -1 已修；独立 C++ 复审进行中。
- 已执行 `verify-packaging.ps1 -CompileInstaller`：12 项脚本/源与 payload gates/环境恢复/SDK版本拒绝/编译检查，9 项文件-only测试通过，production/QA 两种 NSIS 假 payload 语法 smoke 编译成功。没有运行假 installer、没有访问注册表；这些不替代 root 的真实首装/升级/失败注入/中断恢复 QA。

### 安装事务恢复边界修复（2026-10-05，待独立复审）

- 初始日志在同卷独立 `.__jianzhang_transaction.preparing-GUID` 目录写入并 `Flush(true)`，完成后才原子改名为正式事务标记。创建、写入、刷盘失败或发布前进程退出均不会产生缺日志的正式标记；未发布临时日志不阻断后续安装，也不包含或移动旧 payload。
- 完成回滚/已提交事务先清理 payload 子树，持续保留 `RolledBack`/`Committed` 日志。子树遇锁可幂等重试；日志最后通过原子目录改名移至严格命名的 `cleanup-GUID` 残留目录，再删除日志和目录。下一次实际安装预检清理该残留；只允许完整、匹配的终态日志或严格命名的空目录，未知文件仍拒绝并保留。
- `RolledBack` 重试只执行文件清理，不再读取已清理的快捷方式备份或重复恢复登记。
- `verify-packaging.ps1 -CompileInstaller` 最新 exit 0：30 项纯文件测试、12 项打包检查，生产/QA C# helper `/warnaserror+` 与生产/QA NSIS 语法编译通过。故障 hooks 仅存在于 `INSTALLER_FILE_TESTS` 编译；生产与安装 QA helper 均不含此入口。
- 证据：`.qa/packaging-unit-809a16ae0d70437998d7b7bbeec34fd8/evidence.json`。测试使用独立文件入口及其子进程，从未调用 installer Main、Preflight、Rollback、Registry API 或实际安装/卸载程序。真实安装升级、登记/快捷方式回滚与 Windows 10 验收仍由主任务执行；必须重新独立 C# 复审后才能解除源码阻断。

### 升级/卸载保留个人文件修复（2026-10-05，待第三轮独立复审）

- 新安装记录 `.jianzhang-payload.json`，包含验证过的 payload 与实际生成的卸载器字节数/SHA；安装身份 token 绑定该清单 SHA。程序文件清单只记录安装器管理的文件，复制的个人文件不会被重新标记为程序文件。
- 升级将清单外及用户已改写的旧托管文件视为个人内容，先复制到同卷 stage 并核对字节/SHA，保留中文/空格子目录、JSON/CSV/XLSX/notes 和空目录，再提交新版本。个人路径与新 payload 相同、父子类型冲突或仅大小写不同均拒绝覆盖，旧安装不动。已改写但新版不再使用的旧托管文件继续保留。
- 复制/验证时锁住旧文件，目录原子移动前释放句柄，移动后立即重新锁住并校验整个旧备份。纯文件成功路径实际发现 Windows 在子文件句柄持有时拒绝目录移动，已修复；移动后若备份发生变化，拒绝继续并保留完整备份供恢复，不能伪报成功。
- 卸载删除前校验本版清单与每个仍存在的托管文件；用户改写托管路径时停止，不删除修改内容。卸载只删除程序清单路径，额外文件及非空目录保留。旧恢复备份未带个人文件保留验证时拒绝清理；已经部分清理的本版已验证备份支持按剩余清单校验后重试。
- 无旧可信清单的历史安装或损坏的清单不会自动迁移/删除。安全操作步骤：导出账本，另行完整备份原安装及恢复目录，使用原版本卸载器移除旧安装登记，再选择空目录安装新版。同目录且具有效清单的 2.0.0 同版升级已连续验证两次。
- 最新 `verify-packaging.ps1 -CompileInstaller` exit 0：56 项纯文件测试 + 12 项打包验证；production/QA helper `/warnaserror+` 和 production/QA NSIS 语法编译通过。证据 `.qa/packaging-unit-3e106345254f4f00b070bab7bf958c9a/evidence.json`。纯文件 harness 调用共享 `CommitPayload` 文件子函数及 ownership/cleanup 文件检查，没有运行 installer Main、完整 Commit/Preflight/Rollback、Registry API、NSIS 安装/卸载。
- 源码修复需第三轮独立 C# 和 PowerShell/NSIS 复审；Root 需重新编译打包并执行实际首装/升级/卸载、登记/shortcut 回滚及 Win10 验收。此次不改 Flutter/Dart/Android 构建源。

### 卸载持久重试与个人文件并发恢复（2026-10-05，待第四轮独立复审）

- 卸载先在同卷独立 preparing sibling 完整 flush 恢复日志及卸载器副本，再原子发布 `安装目录.__jianzhang_uninstall`。日志绑定本卸载器 config、原 owned 清单与 token。仅存在可验证 `Uninstalling`/`Completed` 日志时容许已删除的程序文件缺失；无记录的缺失不被当成合法卸载。
- 普通程序文件统一由 helper 每个文件持替换锁、核对 SHA 后删除。NSIS 生成删除清单只清理空托管目录，不再直接删除 payload 或身份文件。仍存在的修改文件/个人目录立即拒绝删除，额外文件和账本目录不进入删除清单。
- payload/shortcut/登记阶段完成后，helper 删除两份身份文件；任一失败仍保留原卸载器和完整恢复日志。先持久记录 `Completed`，最后删除 `Uninstall.exe`；成功后无可失败的清理步骤。最后入口删除失败也可以从 Completed 记录重试。小型已完成日志/卸载器副本由下一次实际安装预检清理，避免清理错误使完整卸载失去重试依据。
- 安装与卸载持有同一个整个操作期间的 NSIS mutex。旧备份恢复改为验证固定 owned 清单/token 身份和无 links，再恢复整个旧目录；个人文件 edit/add/delete 不再被准备阶段 SHA 阻断，也不采用 stage 陈旧副本覆盖最新个人内容。原托管身份变更仍拒绝恢复并保留全部目录。
- 最新 `verify-packaging.ps1 -CompileInstaller` exit 0：94 项纯文件故障/恢复测试 + 12 项打包检查；production/QA helper `/warnaserror+` 和 NSIS 语法编译通过。证据 `.qa/packaging-unit-57a342f2f22849f7bc084b56de2b6b06/evidence.json`。包含 5 种解锁/relock/移动并发故障与新日志读取重试、部分 payload 删除、身份删除前后故障、最后入口占用、卸载阶段进程退出及原文件锁解除重试。
- 未运行 installer Main、整体 Commit/Preflight/Rollback、Registry API 或真实 NSIS 安装/卸载。后段 shortcut 失败只做文件 surrogate；实际 .lnk 占用、登记失败、首装/升级/卸载与 Win10 验收仍由 Root 执行。此轮更改需新源码身份的 C# 与 PowerShell/NSIS 独立复审，不能沿用上一轮审查通过结论。

### 后段安装失败保留最新个人文件（2026-10-05，待第五轮独立 C# 复审）

- 回滚先按可信 owned 清单和原个人副本区分候选程序文件、未改的个人副本与新增/修改个人内容。候选侧新增及更新内容经过字节/SHA 验证，保存到同卷独立的 `简账恢复-事务ID` 可读目录；该目录不进入事务递归清理。旧侧仍为初始版本时合并候选更新；两侧同路径均已修改时保留旧路径及两份可读副本，不静默覆盖。未改变的默认副本不制造假冲突，首装失败的个人文件同样保存。
- 候选清理逐文件锁定、核对、保存并删除，未知并发新增文件阻止清理。候选目录最后原子移至可幂等重试的 terminal 目录，只删已知身份文件和空目录；未完成副本先写临时文件并刷盘，再原子发布，不把半个副本当恢复成功。个人恢复副本路径纳入安装错误结果。
- 最新 `verify-packaging.ps1 -CompileInstaller` exit 0：117 项纯文件测试和 12 项打包检查，生产/QA C# `/warnaserror+` 与生产/QA NSIS 语法编译通过。新增覆盖两侧编辑冲突、修改候选托管文件、6 个文件故障点、4 个真实子进程中断点、文件锁解除重试及首装失败个人文件保留。
- 原第四轮审查 `late-personal-review.cs` 在新源码下重新编译及运行 exit 0：旧安装恢复、最新备注及新增个人 JSON 均保留。证据 `.qa/packaging-unit-85bb9ddf2ab8462390b0eb7df123e99f/evidence.json` 与其 `exact-review-repro/evidence.json`。前一次同源文件测试在 `MovingOld` 阶段 journal `File.Replace` 报 `无法删除要被替换的文件。`，原因未确定；保留失败 fixture，未计为通过，新 fixture 重跑完整通过。
- 本轮仅修改 helper 与纯文件测试；未执行安装器、注册表探针或真实账本。须独立第五轮 C# 复审；真实安装/升级/卸载与 shortcut/登记故障、Windows 10 验收仍由 Root 执行。

### 删除绑定文件对象修复（2026-10-05，待第六轮独立 C# 复审）

- 第五轮确定复现表明允许 delete sharing 的锁不能阻止编辑器原子替换路径。现 `LockFile` 只允许 READ sharing，阻止外部写入和重命名；核验删除统一使用该锁句柄的 `SetFileInformationByHandle(FileDispositionInfo)`，没有按路径删除的失败回退。覆盖候选程序/个人文件、卸载 payload、身份文件、最后卸载入口、候选终态身份、完成日志和已核验旧备份文件。复制及 Hash 使用兼容分享的只读流，严格对象锁确保其路径在核验期间不被替换。
- 个人内容合并改用 `DuplicateHandle` 获取相同锁定对象的流句柄写入，并核对完整 SHA；已保存的双方可读副本保持保留。旧目录移动前仍明确释放全部锁，移动后立即重新锁定并检查。已持久 Completed 卸载重试不再重复发布相同完成日志。
- 最终同源连续两轮 `verify-packaging.ps1 -CompileInstaller` exit 0：各 145 项纯文件测试和 12 项打包检查。生产/QA helper `/warnaserror+` 及生产/QA NSIS synthetic 语法编译通过。新增真实 File.Replace、直接写入和重命名拒绝、同对象删除，以及候选 notes/README/两身份和卸载 README/两身份/最后入口的待保存字节保留与失败解除重试。
- 未修改的两项第五轮 atomic reviewer 源重新编译运行 exit 0：均不能持锁替换路径，最新待保存字节仍存在；候选回滚成功，卸载被明确 IOException 阻止时 managed 文件保留。证据 `.qa/installer-r6-atomic-repro-969dadd05e104d7fb709bf995b70f360`。总证据 `.qa/packaging-unit-c53d3ac6c450442cbed2cb5b1434494b/evidence.json`，连续通过前一轮 fixture 为 `packaging-unit-5fbfddc5feab4638b7a448253720931b`。
- 中间测试失败如实保留：两次 journal File.Replace IOException、一次退出注入子进程未到目标边界、一次卸载 configBinding 拒绝；旧 harness 未捕获其确切 HResult，原因未确定，未凭假设添加 blind retry。现 harness 保留原反射异常 stack，打印每层 HResult/Win32 code，记录 fixture/boundary/currentBinding/recordBinding，并捕获子进程 stderr。增加诊断后未再复现，最终两轮完整通过不代替对先前失败的说明。
- 实现依据 [Microsoft SetFileInformationByHandle 文档](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)：FileDispositionInfo 需要 DELETE 访问，删除绑定句柄并在关闭后生效，该 API 支持 Windows Vista 及以上。此次只做 Windows 原生文件 API 实测和编译；Windows 10 完整安装兼容仍须 Root 验证。未运行 Registry probe、真实 NSIS 安装或真实账本；需要独立第六轮 C# 复审后才可解锁此源码候选。

### 内部安装与恢复路径预算（2026-10-05，R7）

- 配置检查现在同时预算最终文件、stage/old/failed 内容、candidate retirement 身份、事务 preparing/cleanup 日志、卸载 preparing/cleanup/入口、个人副本临时路径、可读双方恢复及版本 suffix、快捷方式备份和写入探针。文件完整路径小于 260 UTF-16 字符、目录及文件父目录小于 248；GUID 按 32 位、恢复版本按 Int32 最大十位预留，不依赖修改 Windows 长路径配置。依据 [Microsoft 路径限制说明](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)。
- 现有个人文件及空目录同样预算其未来移动/复制路径。旧 marker、卸载记录、preparing 与 cleanup sibling 只检查路径，先于日志解析/清理；过长路径明确中文拒绝，说明本次路径检查未移动或删除现有安装、个人文件和恢复备份，推荐默认或较短目录。旧版本已经遗留过长恢复树时仍保留它，不能自动移动/删除来“修复”；应先完整另行备份旧安装、恢复目录及账本，再在受支持短路径处理。
- 候选目录在初始 preflight 后可能新增个人文件，回滚移动前再次预算，防止把新内容移入不可操作的长恢复路径。
- 当前 `verify-packaging.ps1 -CompileInstaller` exit 0：156 项纯文件测试、12 项打包检查，production/QA helper warnaserror 与 NSIS synthetic 编译通过。精确 177 final/262 internal 输入两种早拒绝测试确认旧文件/hash/marker 不变；manifest/个人文件/空目录长相对路径拒绝；最大可接受退休身份 259 字符实际完成候选 commit、晚期个人文件回滚、可信卸载与清理，不以缩短原问题输入代替修复。
- 证据 `.qa/packaging-unit-94a0e3bab33f4640a5d8f9f9aad6d90a/evidence.json`。途中 Prepared 阶段 journal File.Replace 真实失败 HRESULT `0x80070497`（Win32 1175）；同一待发布 source/target 在重新持有旧安装全部 11 个严格锁时一次替换成功，target SHA 与原 source 一致。原因未确定；未添加 blind retry，冻结源不漂移。诊断位于旧失败 fixture `packaging-unit-fbcc7cc2eeb2432096c31bb51db0aec1` 的 `crash-rollback-afterRestoreOld/journal-io-diagnostic.json`。
- 本轮未执行 Registry probe、真实 installer/卸载或真实账本。真实同候选安装矩阵、登记/shortcut 故障与 Win10 兼容仍由 Root 验收；任何新运行失败仍按原证据处理。
