# 原生接口与验收脚本独立审查

日期：2026-10-05。审查只读源代码，未修改实现。当前结论：**Block（验收脚本存在 HIGH 问题）；原生鉴权与账本接口本身未发现 CRITICAL/HIGH。**

## 范围与检查

- 本地新增 `lib/native-api-core.ts`、`lib/native-auth.ts`、`lib/native-ledger-store.ts`、`app/api/native/v1/`、两份 native Node 测试、`scripts/check-native-acceptance.mjs`，以及 ESLint/TypeScript 配置差异。
- 先检查 staged/unstaged diff 和新增文件。未提供 PR，因此无法核验 PR 合并状态或远程 CI。
- `tsc --noEmit -p tsconfig.json` 通过。
- `eslint . --ext .ts,.tsx,.js,.jsx` 首次因扫描 `dist` 产物失败；主任务加入全局 `dist/**` 排除后重跑通过。新增排除仅工具、测试/构建产物，`strict` 未降低。
- `node --test tests/native-api.test.mjs tests/native-auth.test.mjs`：9 项通过，0 失败。

## 必须修复

### HIGH：验收脚本可把未测试报告判为通过

位置：`scripts/check-native-acceptance.mjs:19`、`:26`、`:31`、`:37`。

复现文件：`.sites-runtime/review-fabricated-rounds.json`。报告把同一轮内容复制三次；检查与性能 evidence 指向不存在文件；截图和日志为空数组；固定配置为空对象；性能样本数为字符串 `not-measured`，值为 0；安装包哈希为任意合法长度的十六进制字符串。运行脚本仍退出 0，输出 `accepted: true`。

影响：未完成的环境、性能和三轮回归可能被错误接受，提前结束持续优化。`samples` 的 truthy 与 `<20` 判断不能拒绝产生 NaN 比较的字符串；truthy/length 无法证明证据存在或轮次独立；哈希只校验格式没有核对真实包。

建议：严格校验报告结构、整数样本数和非空证据；验证受控证据路径存在及实际安装包 SHA-256；要求独立轮次标识和时间顺序；核对原始实测样本及其统计值，补上述拒绝场景回归测试。修复后需重新审查，当前禁止据此宣称已验收。

## 后端审查结果

- 原生接口只读取显式 Bearer，不接受 Cookie；带 Origin 的请求被拒绝，旧网页 Cookie/Origin 检查未改动。
- 请求要求 HTTPS，开发仅允许 HTTP loopback。JSON 类型、UTF-8、对象结构和真实流字节数受限制；超限流取消读取。云端限制包含完整上传 envelope，仍为 8,000,000 字节与 20,000 笔。
- SMS 配置留空时返回 503，无生产测试验证码。沿用原有 OTP 随机生成、时效、尝试次数、一次消费、发送限额；会话随机 256 bit、服务端哈希存储、30 天到期和注销撤销。返回 token 的响应为 `no-store`，不设置网页 Cookie。
- 账本 PUT 校验 `expectedUserId`、非负安全整数 revision 及旧 Ledger 合同；SQL 采用参数绑定。CAS 更新与分块删除/写入在一个批次内，以独立 write token 保护失利写者；账户隔离、409 后赢家保留、分块失败整体回滚及首次创建回滚均有测试。
- D1 批次的事务与整体回滚依据：[Cloudflare D1 官方说明](https://developers.cloudflare.com/d1/worker-api/d1-database/)。测试使用 SQLite 事务模拟，并非远程 D1 联调。
- 未发现新实现将令牌、短信验证码、完整账本或 SQL 故障信息写入日志或不受控错误响应。

## 验证边界

未执行 Flutter、原生安全存储、安装包、实际 Cloudflare 部署联调或真实短信服务验收；这份代码审查不能替代其验收证据。9 项专项测试覆盖接口核心与短信服务复用，未包含新账本 GET/PUT 路由完整部署环境的端到端调用。
