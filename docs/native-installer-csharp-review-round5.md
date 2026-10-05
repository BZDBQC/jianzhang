# Windows 安装事务 C# 第五轮独立审查

日期：2026-10-05。结论：**BLOCK / not clear**。第四轮普通晚期个人文件变化的删除缺陷已修复；本轮实际复现一项 HIGH：允许 delete sharing 的锁未阻止原子替换，按路径删除移除了未经核对的新对象。候选回滚清理和卸载普通 payload 均存在该缺陷。

冻结源 SHA-256：helper `6f18b380b0eb3d299d22f7825337cc528d3a859c53ebcad2fd0828a919fa33e8`；file-only tests `db8f4500160cf9441b1021d85bb53a959441282c177695eab2357324c6931c42`。独立编译/测试前后源身份一致，没有修改实现。仅创建自有文件测试和本报告，不执行完整 installer/uninstaller、Registry、Main、Preflight 或整体 Rollback。

## [HIGH] 允许原子替换的锁配合按路径删除会丢失新个人内容

File: `scripts/native-toolchain/installer-transaction.cs:157`、`:677`、`:451`。

Issue: LockFile 以 share=5 打开文件，即允许 read/delete sharing。普通写入被阻止，但外部编辑器可以用 File.Replace 原子替换该路径。此后 SafeFileHandle 仍锁定旧对象，File.Delete(path) 却删除替换后的新对象。已有 SHA、恢复副本和删除检查都属于旧对象；新个人字节没有经过保存或验证就被删除，操作仍报告成功。不能用“持有文件锁”证明路径所指对象稳定。

### 确定复现 A：候选个人文件回滚清理

用当前原 file-only LateCandidate 建立晚期 notes 编辑；调用原 CompleteFileRollback。在现有 `rollback.beforeCandidateDelete` hook 中，确认普通写入仍被当前锁拒绝，然后用 File.Replace 把 failed 候选中的 notes 替换为另一份最新用户字节。原函数继续按路径删除。

实际结果：`attemptedUnderInstallerLock=true`、`atomicReplaceSucceeded=true`、`rollbackError=null`、`newestUserBytesSurvive=false`；原安装恢复成功，活动恢复目录也已清理。最新原子保存字节没有任何副本。

Evidence: `.qa/installer-atomic-personal-review-d3e23df424f94d5ebcdd317d818a69aa/fixture/evidence.json`。测试源码为同目录 `atomic-personal-review.cs`，与冻结 helper/tests 共同编译，入口 `JianzhangInstaller.AtomicPersonalReview`；未修改生产逻辑。

### 确定复现 B：卸载普通托管文件删除

用原 SeedOwned 和 BeginUninstall 开始可信纯文件卸载；调用 DeleteUninstallPayload。在 `uninstall.beforeDeletePayload` hook 中，确认 README.txt 正被锁住，再用 File.Replace 将该路径替换为新的个人内容。

实际结果：`atomicReplaceSucceeded=true`、`deletePayloadError=null`、`newestPersonalBytesSurvive=false`、`managedPathExists=false`。原本应拒绝删除已改写托管路径的规则没有保护这种原子保存。

Evidence: 同目录 `uninstall-fixture/evidence.json`；源码 `atomic-uninstall-review.cs`，入口 `JianzhangInstaller.AtomicUninstallReview`。该测试只调用共享文件函数，没有 Registry 或 NSIS 行为。

可分别复跑两项确定文件测试，参数使用新的自有目录：

```powershell
& '.qa/installer-atomic-personal-review-d3e23df424f94d5ebcdd317d818a69aa/atomic-personal-review.exe' '.qa/installer-atomic-personal-review-d3e23df424f94d5ebcdd317d818a69aa/repro-candidate-again'
& '.qa/installer-atomic-personal-review-d3e23df424f94d5ebcdd317d818a69aa/atomic-uninstall-review.exe' '.qa/installer-atomic-personal-review-d3e23df424f94d5ebcdd317d818a69aa/repro-uninstall-again'
```

Fix: 验证、保存和删除必须绑定同一文件对象；可禁止 rename/delete sharing，并用已核对的同一原生句柄执行删除。若允许路径替换，则不能再直接 File.Delete(path)，必须保留新路径对象并重新核对/保存，确保只删除实际检查过的旧对象。统一审视 candidate、普通 payload、identity、最终入口等所有 checked-lock→path-delete 路径，不只修一个分支。移动旧目录前释放句柄的既有合法步骤保持独立。补两项上述真实 File.Replace 文件回归，要求替换被明确拒绝，或最新对象及内容被完整保留，不能吞异常后继续删除。

## 上轮修复及验证

固定 failed-ID、可信 owned/baseline 分类、单侧个人变化合回旧安装、双侧冲突独立可读副本与说明、首次失败安装的个人数据保留，以及断点重试路径已复核。原精确 late-personal 场景现在保留新 notes 与 JSON；普通目录/文件编辑后的旧 SHA 恢复缺陷也仍解除。新缺陷是原子替换在最后删除窗口绕过了对象稳定假设，不能据此否定前述已修复路径。

本轮执行 git diff C# 并直接审查新增源。独立 production/INSTALLER_QA helper `csc.exe /warnaserror+` 编译通过，原未修改纯文件 harness **117/117，通过且 registry_access=none**。独立证据：`.qa/installer-csharp-round5-4b388b6af7404ad8b42f22c03f64c365/evidence.json`、`file-tests.log`。owner 的 117 file-only/12 packaging 检查另见 `.qa/packaging-unit-85bb9ddf2ab8462390b0eb7df123e99f/evidence.json`。这些已有测试未包含持锁后的原子替换。

本机无 .NET SDK，第一轮 dotnet build/format 已尝试且不可执行，当前只记录真实 csc 构建证据。生产未定义 INSTALLER_FILE_TESTS，不包含本次文件 hook 的注入行为。

| 严重度 | 本轮未解决数量 |
|---|---:|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 0 |

统一修复并独立复审前不解除源码阻断。实际安装/升级/卸载和登记失败仍未由本审查验收；Windows 10、安卓真机及真实短信继续是约定未验证范围。
