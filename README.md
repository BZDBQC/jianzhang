# 简账

面向 Android 和 Windows 的个人记账应用。打开即可使用，账单先保存在当前设备。需要云端保存时再登录，并手动同步；云端账本按账户隔离。

## 下载与安装

- Android 8.0 及以上：[jianzhang-2.0.0.apk](https://github.com/BZDBQC/jianzhang/releases/download/v2.0.0/jianzhang-2.0.0.apk)
- Windows 10/11 64 位：[Jianzhang-2.0.0-x64-setup-r20.exe](https://github.com/BZDBQC/jianzhang/releases/download/v2.0.0/Jianzhang-2.0.0-x64-setup-r20.exe)
- 浏览器入口：<https://jianzhang-ledger-rm.raowx9744.chatgpt.site>
- 全部安装包与 SHA-256：[Releases](https://github.com/BZDBQC/jianzhang/releases)

2.0.0 为候选版本：Windows 安装器 47/47 用例通过，Android 模拟器界面与性能回归通过；Windows 10 实机、Android 真机及完整 API 矩阵尚未验收，详见 [R20 交付与检查报告](docs/native-final-r20-report.md)。

首次打开是空白本机账本，无需注册或登录。Android 与 Windows 2.0 客户端是 Flutter 独立应用，账本保存在本机 SQLite；浏览器入口使用本机 IndexedDB。不同设备、浏览器或浏览器配置文件的数据独立，清理站点数据前请导出备份。浏览器入口首次加载需要网络，加载完成后可断网记账。使用说明见 [简账 2.0 使用与迁移说明](docs/native-user-guide.md)。

在“设置与备份”选择“登录并同步”。支持手机号验证码登录，短信服务目前按要求留空，接入前明确提示未配置；原有 ChatGPT 云端账户仍可登录。登录不会自动上传；每次同步需选择使用本机账本、云端账本或该账户在此设备的缓存副本。同步前保留最近 10 份完整备份，不自动合并数据。短信配置见 [短信登录配置](docs/短信登录配置.md)。

## 已实现

- 支出、收入、转账，金额、日期时间、账户、二级分类、备注与手续费。
- 账单详情、修改、删除、复制、保存并继续。
- 大类与小类增删改、排序；删除已使用分类必须迁移账单。
- 账户初始余额、动态余额、停用与历史流水。
- 金额等于、大于、小于、区间，以及分类、备注、时间、账户组合筛选；常用筛选保存在当前设备。
- 月度、年度、自定义周期的收支趋势、分类占比及大小类排行，可下钻至账单。
- 月度总预算与大类预算，使用进度、超支及站内阈值提醒。
- CSV、真实 XLSX 表格导出，JSON 完整备份及校验后恢复。
- 安卓触控布局、Windows 桌面布局及可安装网页应用支持。

转账本金只改变余额。手续费作为单独的支出参与统计与预算。统计下钻包含相关手续费账单；导出中保留转账本金和手续费两个字段。

## 目录

| 路径 | 内容 |
| --- | --- |
| `app/`、`lib/`、`components/` | 网页端（React 19 + Vinext + Cloudflare D1） |
| `clients/flutter/` | Flutter 客户端（Android / Windows 2.0） |
| `drizzle/` | D1 数据库迁移 |
| `scripts/` | 构建、原生工具链与校验脚本 |
| `docs/` | 使用说明、架构与验收记录 |
| `tests/` | Node 自动化测试 |

## 开发与检查

网页使用 React 19、TypeScript、Vinext、Cloudflare D1、Recharts 和 Shadcn 组件；2.0 客户端使用 Flutter、Drift/SQLite 与 Riverpod。本机写入在数据库事务中检查版本号；云端数据分块保存，使用修订号及事务防止不同设备互相覆盖。本机操作成功后即持久保存，云端连接失败不会阻止记账。

```powershell
npm run install:ci
npm run dev
npm run build
npm run lint
node --test tests/*.test.mjs
node node_modules/typescript/bin/tsc --noEmit
```

本地预览的 ChatGPT 登录由 starter 提供模拟账户，手机号测试使用独立内存数据库与测试发送器，生产未提供伪验证码或测试短信入口。开发环境首次使用云端功能需将 `drizzle/` 内 SQL 应用到本地 D1；生产发布流程自动应用迁移。Flutter 客户端源码位于 `clients/flutter/`，构建与打包脚本位于 `scripts/native-toolchain/`；1.0.x 启动器源码（`native/`）与 `releases/` 安装产物未纳入本仓库。

金额以整数分计算。完整账本最多支持 20,000 笔记录、100 个账户和 8 MB 序列化数据，超出时会保留原数据并提示。建议定期导出完整备份。

详细操作见 `docs/使用说明.md`；数据模型和验收记录见 `docs/架构与验收.md`；持续测试与改进见 [迭代记录](docs/迭代记录.md)。
