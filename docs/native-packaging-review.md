# 简账 2.0 构建与安装专项审查

日期：2026-10-05（Asia/Shanghai）。状态：首轮静态审查，待修复、待安装验收。

范围：`scripts/native-toolchain/**`、`scripts/package-windows-client.ps1`、`clients/flutter/packaging/windows/installer.nsi`、当前 Windows release bundle 与 QA setup manifest。已检查 staged/worktree diff、完整新增脚本及安装器。沿用 verification-loop 技能中的构建证据、差异与独立验收要求；只写本报告，未改生产代码，未运行安装/卸载或独立注册表诊断。

当前 `.qa/native-installer-setup.exe` 仅为较早源码快照的打包 smoke，不是最终验收候选。本报告不得把编译成功转记为安装、升级或 Windows 10 通过。

## HIGH

### P1 — 打包脚本没有验证 bundle 与当前源码及构建记录一致

File: `scripts/package-windows-client.ps1:14`、`:18`、`:102`、`:110`。

Issue: 打包仅检查 exe、Flutter 引擎、icudtl 和 assets 路径存在，没有读取并验证 Windows build manifest 的 bundle、版本和源码 SHA；没有固定 release 文件的稳定快照再交给 NSIS。源码修复后直接调用打包脚本，仍能把旧 release 或编译期间变化的 bundle 标为 2.0.0 candidate，manifest 的 payload 哈希也未必对应 NSIS 最后读取的内容。

只读核算结果：Windows build manifest 和 build-client 源快照均为 `483011ebe2bf2032706634544419279a7f3aeb773f5a09535bb8e011ea1ef09f`，读取时当前 client 源码为 `4385a2ad549fcc0129f5c3265d1192bf407b7338c4c1f668aa49daeacca67fbd`。实施期间修改导致不一致本身正常；缺陷在于打包器没有拒绝过期 bundle。QA setup 被明确限定为 smoke，不能据此称最终交付错误。

Fix: 构建成功时记录版本、统一源输入清单及 SHA、完整 release 文件清单及 SHA。打包前验证当前源码与记录匹配，检查生成插件和 native assets 所需 DLL，复制到受控且稳定的 packaging snapshot 后重新核对 payload。CRT 的注入应成为可追溯的单独阶段，记录实际库版本和 SHA。NSIS 编译完成后再核对源码/payload 未变；setup manifest 记录 source/build/payload 身份，版本取自同一构建合同。回归必须拒绝过期源码、缺失 DLL 和打包中变化的文件。

### P2 — 登记或快捷方式失败后没有回滚已写入状态

File: `clients/flutter/packaging/windows/installer.nsi:227`、`:242`、`:263`。

Issue: 快捷方式依次创建、注册值依次写入，错误分支直接 Abort。若 DisplayName/DisplayVersion 已写入而后续写入失败，首装会遗留部分登记，升级会把旧登记改为新版本的一部分；已有快捷方式也可能被部分替换。错误退出码正确，但不能证明“失败不得登记成功”或旧安装入口仍完整。

Fix: 开始写入前快照全部旧注册值和是否存在、全部相关快捷方式及其属性，不能只保留 InstallLocation/DisplayVersion。成功完成 payload、uninstaller、shortcuts、registry 后才提交安装状态；失败时首装撤销本轮新建入口，升级恢复全部旧值、旧 shortcut 和旧 payload。QA 在每个登记/快捷方式阶段注入失败，核对首装无成功登记、升级保持完整旧状态，并确认 rollback 自身失败会明确报出而不是返回成功。不得另建工具绕过先前被拒绝的注册表诊断。

### P3 — 子目录未预检，升级途中失败可能留下混合版本

File: `clients/flutter/packaging/windows/installer.nsi:99`、`:132`、`:151`、`:220`。

Issue: preflight 只探测安装根目录，并对已存在的 payload 文件做 append-access 检查；没有检查所有 payload 父目录的类型及新文件创建/删除权限。若 `INSTDIR\\data` 是普通文件，或某子目录允许旧文件写入但不允许创建新增文件，根 exe/DLL 可先被覆盖，随后 `File /r` 失败。Abort 不会恢复被覆盖文件，原安装因而可能变成不可启动的混合版本。

Fix: 从完整 payload 清单生成全部父目录检查：目录路径不能是文件，现有目录须可创建并删除自有 probe，已有文件需可覆盖且可替换，覆盖目录、文件只读及占用情形。先把完整候选解压到安装目录外的同卷 staging 并校验，再提交带 rollback 的更新；与 P2 共用失败回滚。只读/占用的任一深层文件、`data` 文件类型冲突、不能新建文件的子目录都应在改动旧 payload 前失败。

## MEDIUM

### P4 — 工具脚本的进程环境变量未恢复

File: `scripts/native-toolchain/install-flutter.ps1:6`、`:13`；`scripts/native-toolchain/start-emulator.ps1:5`；`scripts/package-windows-client.ps1:9`、`:74`。

Issue: 这些脚本设置 TEMP/TMP、APPDATA/LOCALAPPDATA、PUB_CACHE 或 NSISDIR 后没有恢复。用户在已有 PowerShell 中以 `& script.ps1` 调用时，环境变量仍属于同一进程，脚本退出不会恢复；后续启动的软件可能把配置、临时文件甚至支持数据写进工作区。两个 build 脚本已有 finally 恢复模式，可直接沿用。

Fix: 记录所改进程环境变量并在 finally 恢复，或显式启动仅承载工具任务的子进程。回归在同一 PowerShell 进程验证成功及失败路径均不遗留覆盖。

### P5 — Flutter 安装器不能确认已安装 SDK 是请求的版本

File: `scripts/native-toolchain/install-flutter.ps1:30`、`:34`。

Issue: 只要 `.tools/flutter/bin/flutter.bat` 存在便跳过解压；最后只检查 `--version` 退出码，没有核对其输出。已有其他版本或中断留下的可执行入口时，下载 archive 的 SHA 正确也不能证明实际使用的是请求版本。

Fix: 检查已安装 SDK 的 machine-readable version、revision、channel 与官方选定 release 相符；不符时在受控目录完成替换并验证，不能输出请求版本已准备好的结论。覆盖安装旧版后请求新版，以及部分解压但入口存在的场景。

## 已核对的正向证据与验证边界

- 9 个 PowerShell 脚本 AST 解析均无错误。本项仅说明语法，不说明安装或运行成功。
- Android 构建脚本使用原 keystore，密码仅置于进程环境并在 finally 恢复；没有输出密码。最终证书 SHA 与旧安装身份 `c398060dfa1cca49974bec7cf030ae818a4e1d83a91796c3c8152ce4c6e48c10` 比较；aapt 检查包名、versionCode、versionName、minSdk。原签名覆盖升级仍需在模拟器实际执行。
- Android 脚本在发布前检查 APK ZIP 的 16 KB alignment，并逐项检查 arm64-v8a/x86_64 ELF PT_LOAD alignment、地址/偏移关系及 segment 表边界。本轮没有对最终 2.0 APK 执行这些检查，不记录 APK 通过。
- 两端 build 脚本在源复制前后以及构建完成后核对源码指纹，可阻止构建期间 client 源码变化。Windows 插件 junction 使用非递归 `.NET Directory.Delete(..., false)` unlink 后再清理自己的普通目录；清理前有路径及 reparse-point guard。Android 单平台 snapshot 不复制 Windows symlink 工程。
- 当前 Windows release 根目录包含 exe、Flutter engine、SQLite、file_selector、secure_storage、dartjni DLL；manifest 还记录 app.so、assets 等完整递归 payload，NSIS 使用 `File /r` 打包。三个 app-local CRT 库已从已安装 Visual Studio redistributable 目录复制。P1 仍要求把完整性锁定为自动门槛。
- NSIS `SetOverwrite try` 与 `IfErrors` 组合能报出跳过的文件写入失败，不能因其没有弹出逐文件 Ignore 对话框而误判成功；参见 [NSIS File 说明](https://nsis.sourceforge.io/Reference/File)。既存文件 append probe 可以提前捕获常见锁定/只读问题，P3 指出的是其未覆盖子目录边界。
- Windows 安装为 current-user，默认 LOCALAPPDATA Programs 目录；Flutter 数据通过 application-support directory 保存在安装目录外。卸载按 payload 清单删除文件和非递归空目录，不删除 ledger/support directory。相关升级、卸载保留数据库场景尚需真实 QA 证据。
- 错误安装/卸载路径设置 exit code 2 并 Abort；卸载会核对登记目录所有权，最终 uninstaller 删除失败时尝试恢复可重试的登记。这些措施不代替 P2 的安装阶段完整回滚。
- Windows 10、Android 真机、真实短信仍为约定的未验证范围。当前 Windows 11 的首装/升级/卸载、只读/占用/中文空格目录、各阶段失败处理，以及六个 API 的 APK 安装运行，均不能只凭 QA setup 编译成功转记通过。

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 3 | warn |
| MEDIUM | 2 | info |
| LOW | 0 | note |

Verdict: WARNING — 3 HIGH 问题应在最终候选打包和安装验收前解决。
