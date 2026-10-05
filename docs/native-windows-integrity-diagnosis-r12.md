# Windows R12 安装登记失败：只读完整性诊断

记录日期：2026-10-05；最终身份复核时间：13:32:23 UTC。工作区：`C:/Users/RM/Desktop/001/jianzhang`。

## 结论与验收状态

当前 QA 安装包与生产 R12 安装包均继承低完整性文件标签。工作区父目录 `C:/Users/RM/Desktop/001` 有可继承的 Low 标签，子目录和文件因此继承 Low。微软的进程创建规则取启动者和可执行文件完整性的较低值；所以从开始菜单打开普通 PowerShell，仍不能保证这个安装包以中完整性运行。

这一实际文件状态、正常用户登记所需的注册表权限、以及失败后显示的 `Temp/Low` 插件目录，组成一致的原因链。但历史安装程序和临时事务 helper 的实际 token 没有被记录，不能声称已经直接观测到这两次失败进程的 Low token，也不能把失败仅归因于 Codex 工具进程。

当前仍是未解决的安装验收项。两次运行均完成 0 个测试用例，不能计作安装成功或完整回归通过。未进行任何权限修复或新的安装试验。

## 实际失败证据

| 项目 | 记录 |
|---|---|
| 工具进程运行 | `.qa/native-windows-installer-r12/installer-results.json`，`roundId=r12dev`，`status=fail`，首装返回 2，完成 0 个用例 |
| 用户运行 | `.qa/native-windows-installer-r12-user/installer-results.json`，`roundId=r12usr`，`status=fail`，完成 0 个用例 |
| 用户确认 | 用户明确确认 `r12usr` 使用从 Windows 开始菜单打开的 PowerShell 执行纠正后的一行命令；报告本身尚不包含此父进程的 token 记录 |
| 用户运行开始 | `2026-10-05T21:06:07.0038075+08:00` |
| 用户运行结束 | `2026-10-05T21:06:09.9798899+08:00` |
| 用户目标目录 | `C:/Users/RM/Desktop/001/jianzhang/.qa/i/安装 空格-r12usr` |
| 失败步 | `.qa/i/steps.log` 最后为 `8:registration.create`；前面为载荷提交及三个快捷方式步骤 |
| 原始失败输出 | `.qa/i/failure.txt`，按 GBK/代码页 936 解码：对 `HKEY_CURRENT_USER/Software/Jianzhang/NativeInstallerQA` 的访问被拒绝；旧安装状态已恢复 |
| NSIS 插件目录 | 失败输出 `Output=C:/Users/RM/AppData/Local/Temp/Low/nshA7F.tmp` |
| 失败文件时间 | `2026-10-05T13:06:09.9394089Z` |
| NSIS 原始日志 | `.qa/i/install.log`，UTF-16LE，包含拒绝访问、返回 2、终止和临时 helper 清理记录 |

共享 `.qa/i` 的 `failure.txt` 和安装日志反映最后一次 `r12usr`；两次运行各自的结果 JSON 保留各自结论。已清理的历史插件文件无法事后重新读取标签或 token。

## SHA-256 身份复核

以下实际文件哈希与对应发布 manifest 一致；此次未改变任何程序、安装源或测试脚本。

| 文件 | SHA-256 |
|---|---|
| `.qa/native-installer-r12-setup.exe` | `3b040531fe9fc9cebca2d991f149f37c9e1863a40b718f67524e36d3755c888a` |
| `releases/windows/Jianzhang-2.0.0-x64-setup-r12.exe` | `886a844636e867c06fe82967a6d4b5ed6f5858bd69d3c047dc695aade3799dba` |
| `.tools/installer-input-1dc6e6b1bb6d44959c06898226328a4e/installer-transaction.exe`，与 QA manifest 指定 helper 相符 | `9cf63a0c510c375d8208808f7881ee39021e6e8c153820fc7d2a894c9bffcfc6` |
| `clients/flutter/packaging/windows/installer.nsi` | `f7bde8557fd46accb49c2e07e1668a8a92c541aea774a6ebb4f7a29adb1b1fd9` |
| `scripts/native-toolchain/installer-transaction.cs` | `2724a706822440cb7c8cda03e1d2a95edc7cd1fc4cb58940bfa15a7eadab4e81` |
| `scripts/native-toolchain/test-windows-installer.ps1` | `1e7ec4ef747e8a83b611ca3831577bdcd1d99bd8d87a46eb1e7315c8d6d55cd9` |

## 文件标签与继承关系

只读使用 `GetNamedSecurityInfo(..., LABEL_SECURITY_INFORMATION=0x10)` / `GetSecurityInfo`，并以不带修改参数的 `icacls.exe <path>` 交叉核对。查询没有使用 `SetSecurityInfo`、`Set-Acl`、`icacls /setintegritylevel` 或其他修改操作。

| 路径或对象 | 实际标签 |
|---|---|
| `C:/Users/RM/Desktop/001` | `Mandatory Label/Low Mandatory Level:(OI)(CI)(NW)`，本级未显示继承标志 `(I)` |
| `jianzhang`、`.qa`、`.tools/temp`、`.tools/installer-temp` | `Low Mandatory Level:(I)(OI)(CI)(NW)` |
| QA EXE 与生产 R12 EXE | `Low Mandatory Level:(I)(NW)` |
| QA EXE 的仅标签 SDDL | `S:AI(ML;ID;NW;;;LW)` |
| 与 manifest 相符的构建 helper EXE | `Low Mandatory Level:(I)(NW)` |
| `C:/Users/RM/Desktop` | `icacls` 未显示显式完整性标签；无标签对象按微软规则视为 Medium |
| 当前普通用户 TEMP | `C:/Users/RM/AppData/Local/Temp`；仅标签查询结果为空 |
| 当前 TEMP/Low | `S:(ML;OICI;NW;;;LW)` |
| HKCU/Software，仅标签查询，32 位视图 | `S:AINO_ACCESS_CONTROL`；未返回 Mandatory Label ACE，无标签对象按微软规则视为 Medium |

`OI/CI` 表示文件/目录继承，`ID` 或 `(I)` 表示继承所得，`LW` 表示 Low，`NW` 表示禁止向更高完整性对象写入。上述父级确实存在这些标签，诊断没有判断或修改其原始设置来源。

## 当前 token 与注册表只读状态

直接读取本次诊断工具 PowerShell 自己的进程 token，使用 `OpenProcessToken(..., TOKEN_QUERY=0x8)` 与 `GetTokenInformation`，无 token 修改或权限调整：

- 用户 `DESKTOP-RBMFB7J/RM`，SID `S-1-5-21-1592005885-3242550562-1073713893-1001`；无线程模拟身份。
- `TokenIntegrityLevel=S-1-16-8192`，即 Medium；`TokenElevation=0`，`TokenElevationType=3`。
- `IsTokenRestricted=false`，`TokenRestrictedSids=[]`，`TokenIsAppContainer=0`。
- `TokenVirtualizationAllowed=1`，`TokenVirtualizationEnabled=0`。
- `TokenMandatoryPolicy` 实际 4 字节为 `03-00-00-00`，含 NO_WRITE_UP 和 NEW_PROCESS_MIN。
- `TokenHasRestrictions` 的实际返回长度为 1 字节，原始值 `01`，只记录为非零。此字段表示 token 曾经过滤，不表示存在 restricting SID；没有把它作为限制 SID 的证据，也没有把此前按 4 字节读取的未初始化高位当作有效字段值。
- 当前环境 `TEMP` 和 `TMP` 均为 `C:/Users/RM/AppData/Local/Temp`；当前 shell 为 bundled PowerShell 7.6.5，64 位进程、64 位系统。

这些结果属于当前诊断 shell，不能代表历史 `r12dev`、`r12usr` 或 NSIS 子进程。`whoami /groups` 的 Medium 行也不能单独代表子进程身份。

当前 `HKCU/Software` 的 DACL 只读 SDDL 为：

```text
O:SYG:SYD:P(A;OICI;KR;;;RC)(A;OICI;KA;;;SY)(A;OICI;KA;;;BA)(A;OICI;KA;;;S-1-5-21-1592005885-3242550562-1073713893-1001)(A;;KR;;;AC)(A;;KR;;;S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681)
```

它给 RM FullControl，给 RESTRICTED ReadKey。当前 `HKCU/Software/Jianzhang` 与 `NativeInstallerQA` 都不存在。DACL 给用户写权限并不能覆盖 MIC 的完整性检查；不能通过此 DACL 推断低完整性子进程能够登记成功。

## 安装代码与两个完整性层级

当前 R12 原生安装包使用 `clients/flutter/packaging/windows/installer.nsi`。`native/windows/launcher/installer.nsi` 是旧浏览器客户端脚本，不是本次 R12 包的编译输入。

1. **安装包进程层级。** 原生 NSIS `RequestExecutionLevel user`；实际 QA EXE XML manifest 是 `<requestedExecutionLevel level="asInvoker" uiAccess="false"/>`。没有代码主动提权或降低 token。文件自身 Low 标签依然会影响操作系统创建进程的完整性。
2. **事务 helper 层级。** `.onInit` 在 `InitPluginsDir` 得到的 `$PLUGINSDIR` 中解压 helper 与 JSON，随后普通 `ExecWait` 启动 helper。编译 helper 为 `/platform:x86 /target:winexe`，实际 helper manifest 也是 `asInvoker`。没有另建高权限 token、`runas` 或注册表权限修改。

QA 的 NSIS `REG_KEY` 与 C# `RegistryPath` 完全一致，均为 `Software/Jianzhang/NativeInstallerQA`。生产键为 `Software/Microsoft/Windows/CurrentVersion/Uninstall/Jianzhang`。本次异常位于 C# `Registry.CurrentUser.CreateSubKey(RegistryPath)`，在 `registration.create` 记录之后。

NSIS 3.12 官方源码的临时目录选择是：先 `GetTempPath` 并验证能写入；失败再尝试 `Windows/Temp`；仍失败且不是管理员组成员，才回退原 TEMP 下的 `Low`，并更新自身及子进程 `TEMP/TMP`。因此 `Temp/Low` 不是所有普通用户安装的默认必选目录，也不能单凭目录名直接测定 token。

插件初始化在选定的 `$TEMP` 中创建目录。非管理员分支使用没有自定义安全描述符的普通目录创建；`File` 提取使用 `CreateFile` 的空安全属性，新文件自然继承目标目录的标签。构建目录中 helper 的 SACL 不作为 NSIS 压缩数据内的文件安全描述符恢复。

因此，如果 setup 本身处于正常中完整性、其启动者也是中完整性，并且普通 TEMP 可写，插件 helper 可以自然获得正常标签。但如果实际选中 `Temp/Low`，helper 解压位置仍有独立的 Low 继承问题。仅把 setup 搬走，不能跳过对实际解压 helper 标签及 token 的验证。

QA helper 是 x86 不构成本次视图错误解释：微软将目标系统的 `HKCU/Software` 列为共享视图，此 QA 路径没有位于特殊重定向的 Classes 子树。没有发现显式 `SetRegView` 与 C# 的视图冲突。

## 下一步的最小侵入方案

建议先增强专用 QA 失败报告：记录启动者和实际 installer/helper 的用户 SID、完整性、限制 SID、AppContainer、实际注册表视图、setup 与插件 helper 文件标签、所选 TEMP、PID 与创建时间。这些均为只读身份/权限元数据，不能输出云端凭据、环境中的密钥或验证码；报告写入自有 QA 证据目录。发现低完整性上下文时应清楚解释原因，而不是改 ACL、修改 token 或请求管理员权限。

分发可增加 ZIP：用户在常规用户目录中展开可产生继承该目录标签的新文件，不把工作区 NTFS 标签当作安装文件的产品属性。实际展开的 setup 仍必须只读检查文件标签和 SHA，随后也须确认 NSIS 选定目录及 helper 身份。此建议没有被执行或验收；不会由工具自动去除文件标签来绕过工作区的安全约束。

当前 `test-windows-installer.ps1` 的 Setup、QaRoot、OutputDirectory 都由 `Assert-WorkspacePath` 约束到工作区，随后还必须在工作区 `.qa` 下。故当前脚本不能直接接受用户在常规外部目录展开的 setup。未来可单独审核增加已交付 setup 路径：严格绑定当前 manifest 的安装包 SHA、完整 payload 合同、版本和包装输入来源，保持 QA 目标及输出为自有目录，不改变登记事务或降低来源验证。

本次未执行独立注册表写入探针，未再次运行安装包，未修改 DACL/SACL/完整性标签、系统策略或 token，未提权，没有把先前被自动审批拒绝的探针换工具重试。只新增这份诊断文档。

## 官方依据

- [微软 Mandatory Integrity Control](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control)：可执行文件与新进程完整性、无标签对象视为 Medium、MIC 先于 DACL 检查。
- [微软 TOKEN_MANDATORY_POLICY](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-token_mandatory_policy)：NO_WRITE_UP、NEW_PROCESS_MIN。
- [微软 TOKEN_INFORMATION_CLASS](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ne-winnt-token_information_class)：各 token 只读查询字段；HasRestrictions 仅表示曾经过滤。
- [微软 IsTokenRestricted](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-istokenrestricted)：只检查 restricting SID 列表，不能概括所有 token 过滤。
- [微软 WOW64 Registry Keys](https://learn.microsoft.com/en-us/windows/win32/winprog64/shared-registry-keys)：目标 HKCU/Software 共享视图。
- [NSIS 官方 RequestExecutionLevel](https://nsis.sourceforge.io/Docs/Chapter4.html#arequestexecutionlevel)：`user` 使用正常用户权限。
- [NSIS v312 Main.c](https://raw.githubusercontent.com/NSIS-Dev/nsis/v312/Source/exehead/Main.c)：临时目录验证、Low 回退、自身与子进程 TEMP/TMP。
- [NSIS v312 build.cpp](https://raw.githubusercontent.com/NSIS-Dev/nsis/v312/Source/build.cpp)：`add_plugins_dir_initializer` 创建 `$TEMP` 下插件目录。
- [NSIS v312 exec.c](https://raw.githubusercontent.com/NSIS-Dev/nsis/v312/Source/exehead/exec.c)：插件目录创建的普通/管理员分支、文件提取。
- [NSIS v312 util.c](https://raw.githubusercontent.com/NSIS-Dev/nsis/v312/Source/exehead/util.c)：普通 `CreateProcess` 与 `myOpenFile` 的空安全属性。

上述源码为官方 v312 标签；本机使用经过下载 SHA 校验的 NSIS 3.12 编译工具。未进行安装进程调试或逐指令验证；对历史执行的解释保留这一证据边界。
