import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const contract = JSON.parse(fs.readFileSync(path.join(root, 'docs/native-acceptance.json'), 'utf8'));
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const normalized = value => Array.isArray(value) ? value.map(normalized) : object(value) ? Object.fromEntries(Object.keys(value).sort().map(key => [key, normalized(value[key])])) : value;
export const configurationHash = config => crypto.createHash('sha256').update(JSON.stringify(normalized(config))).digest('hex');
const textValue = value => typeof value === 'string' && value.trim().length > 0;
const positiveInteger = value => Number.isSafeInteger(value) && value > 0;

export function verifyAcceptance(report) {
  const failures = [];
  const fail = message => failures.push(message);
  const evidenceFile = value => {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
      const file = fs.realpathSync(path.resolve(root, value));
      const relative = path.relative(root, file);
      if (relative.startsWith('..') || path.isAbsolute(relative) || !fs.statSync(file).isFile() || fs.statSync(file).size === 0) return null;
      return file;
    } catch { return null; }
  };
  const files = value => Array.isArray(value) && value.length > 0 && value.every(evidenceFile);
  const readJson = value => {
    const file = evidenceFile(value);
    if (!file) return null;
    try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch { return null; }
  };
  const rounds = Array.isArray(report?.rounds) ? report.rounds : [];
  const last = rounds.slice(-contract.requiredCleanRounds);
  if (last.length !== contract.requiredCleanRounds) fail(`完整干净轮次不足 ${contract.requiredCleanRounds}`);
  if (!Array.isArray(report?.unresolved) || report.unresolved.length) fail('未解决问题列表缺失或仍有问题');
  if (report?.status !== 'candidate') fail('尚无完整候选版本');
  if (new Set(last.map(r => r?.buildId)).size !== 1 || typeof last[0]?.buildId !== 'string' || !last[0].buildId.trim()) fail('三轮并非同一构建');
  const roundIds = new Set();
  const roundLogs = new Set();
  const executionFiles = new Map();
  const executionArtifacts = new Map();
  const acceptedRounds = [];
  const measurementModes = new Map();
  let fixedConfigurationHash;
  let previousEnd = -Infinity;
  for (const [index, round] of last.entries()) {
    const failuresBeforeRound = failures.length;
    const tag = `第 ${index + 1} 个末轮`;
    if (!object(round)) { fail(`${tag} 格式无效`); acceptedRounds.push(false); continue; }
    if (typeof round.roundId !== 'string' || !/^[A-Za-z0-9_-]+$/.test(round.roundId) || roundIds.has(round.roundId)) fail(`${tag} 轮次编号缺失或重复`);
    roundIds.add(round.roundId);
    const start = typeof round.startedAt === 'string' ? Date.parse(round.startedAt) : NaN;
    const end = typeof round.finishedAt === 'string' ? Date.parse(round.finishedAt) : NaN;
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || start < previousEnd || end > Date.now()) fail(`${tag} 实测时间缺失、重叠或无效`);
    previousEnd = end;
    if (!['release', 'profile'].includes(round.mode)) fail(`${tag} 不是 release/profile`);
    if (!Array.isArray(round.defects) || round.defects.length) fail(`${tag} 缺少问题列表或发现问题`);
    for (const key of contract.requiredChecks) {
      const check = round.checks?.[key];
      if (check?.status !== 'pass' || !files(check.evidence)) fail(`${tag} ${key} 缺少真实通过证据`);
      if (contract.staticChecks.includes(key)) {
        const approval = readJson(check?.staticEvidence);
        const artifacts = Array.isArray(approval?.artifacts) ? approval.artifacts : [];
        const validArtifacts = files(check?.evidence) && check.evidence.every(value => {
          const file = evidenceFile(value);
          return file && artifacts.some(item => evidenceFile(item?.path) === file && item.sha256 === sha256(file));
        });
        const validSources = ['apk', 'exe'].every(kind => {
          const expectedManifest = evidenceFile(round.evidence?.sourceManifests?.[kind]);
          const record = approval?.sourceManifests?.[kind];
          const provenance = readJson(record?.path);
          return expectedManifest && evidenceFile(record?.path) === expectedManifest && record.sha256 === sha256(expectedManifest) && provenance?.sha256 === round.evidence?.buildHashes?.[kind];
        });
        if (!object(approval) || approval.checkId !== key || approval.status !== 'pass' || approval.buildId !== round.buildId ||
          !['apk', 'exe'].every(kind => approval.buildHashes?.[kind] === round.evidence?.buildHashes?.[kind]) || !validArtifacts || !validSources) {
          fail(`${tag} ${key} 静态审查证据未绑定当前候选和源码`);
        }
        continue;
      }
      const executionFile = evidenceFile(check?.executionEvidence);
      const execution = readJson(check?.executionEvidence);
      const executionStart = typeof execution?.startedAt === 'string' ? Date.parse(execution.startedAt) : NaN;
      const executionEnd = typeof execution?.finishedAt === 'string' ? Date.parse(execution.finishedAt) : NaN;
      const evidencePaths = Array.isArray(check?.evidence) ? check.evidence.map(evidenceFile) : [];
      const artifactPaths = Array.isArray(execution?.artifacts) ? execution.artifacts.map(evidenceFile) : [];
      const executionLog = evidenceFile(execution?.log);
      const validExecution = executionFile && object(execution) && execution.roundId === round.roundId && execution.buildId === round.buildId &&
        Array.isArray(execution.checkIds) && execution.checkIds.includes(key) && textValue(execution.command) && execution.exitCode === 0 && execution.status === 'pass' &&
        Number.isFinite(executionStart) && Number.isFinite(executionEnd) && executionStart >= start && executionEnd > executionStart && executionEnd <= end &&
        files(execution.artifacts) && executionLog && artifactPaths.includes(executionLog) && evidencePaths.includes(executionLog) && evidencePaths.length > 0 && evidencePaths.every(file => file && artifactPaths.includes(file));
      if (!validExecution) { fail(`${tag} ${key} 缺少绑定本轮执行的功能证据`); continue; }
      const seenFiles = executionFiles.get(key) ?? new Set();
      const seenArtifacts = executionArtifacts.get(key) ?? new Set();
      const artifactHashes = [sha256(executionLog)];
      if (seenFiles.has(executionFile) || artifactHashes.some(hash => seenArtifacts.has(hash))) fail(`${tag} ${key} 复用了之前轮次的执行证据`);
      seenFiles.add(executionFile);
      artifactHashes.forEach(hash => seenArtifacts.add(hash));
      executionFiles.set(key, seenFiles);
      executionArtifacts.set(key, seenArtifacts);
    }
    const config = readJson(round.evidence?.fixedConfiguration);
    const validConfiguration = object(config) && object(config.windows) && object(config.android) && textValue(config.windows.os) && textValue(config.windows.cpu) && positiveInteger(config.windows.ramMB) && textValue(config.android.avd) && positiveInteger(config.android.api) && config.android.api >= 26 && positiveInteger(config.android.ramMB);
    const configHash = validConfiguration ? configurationHash(config) : null;
    if (!validConfiguration) fail(`${tag} 缺少有效固定设备配置文件`);
    if (configHash) {
      if (fixedConfigurationHash && configHash !== fixedConfigurationHash) fail(`${tag} 使用了不同的固定设备配置`);
      fixedConfigurationHash ??= configHash;
    }
    for (const [key, threshold] of Object.entries(contract.metrics)) {
      const metric = round.metrics?.[key];
      const raw = readJson(metric?.rawEvidence);
      const samples = raw?.samples;
      const valid = object(metric) && Number.isFinite(metric.value) && metric.value >= 0 && Number.isSafeInteger(metric.samples) && metric.samples >= 20 && files(metric.evidence) &&
        object(raw) && raw.metric === key && raw.roundId === round.roundId && raw.buildId === round.buildId && ['release', 'profile'].includes(raw.mode) && metric.mode === raw.mode && configHash && raw.configurationSha256 === configHash && Array.isArray(samples) && samples.length === metric.samples && samples.every(n => Number.isFinite(n) && n >= 0);
      if (!valid) { fail(`${tag} ${key} 缺少有效原始实测样本`); continue; }
      if (measurementModes.has(key) && measurementModes.get(key) !== raw.mode) fail(`${tag} ${key} 改变了测量模式`);
      measurementModes.set(key, raw.mode);
      const sorted = [...samples].sort((a, b) => a - b);
      const measured = key.endsWith('ScrollFramesOver50msRatio') ? samples.filter(n => n > 50).length / samples.length : sorted[Math.ceil(sorted.length * 0.95) - 1];
      if (Math.abs(measured - metric.value) > 1e-9 || (threshold.maximum !== undefined && measured > threshold.maximum) || (threshold.exclusiveMaximum !== undefined && measured >= threshold.exclusiveMaximum)) fail(`${tag} ${key} 摘要与实测不一致或未达标`);
    }
    if (!files(round.evidence?.screenshots) || !files(round.evidence?.logs)) fail(`${tag} 截图或日志缺失`);
    const logFile = evidenceFile(round.evidence?.roundLog);
    const log = readJson(round.evidence?.roundLog);
    if (!logFile || roundLogs.has(logFile) || log?.roundId !== round.roundId || log?.buildId !== round.buildId || log?.startedAt !== round.startedAt || log?.finishedAt !== round.finishedAt) fail(`${tag} 缺少独立执行日志或标识不一致`);
    if (!object(log?.checks) || contract.requiredChecks.some(key => JSON.stringify(log.checks[key]) !== JSON.stringify(round.checks?.[key]))) fail(`${tag} 执行日志与功能检查清单不一致`);
    roundLogs.add(logFile);
    const hashes = round.evidence?.buildHashes;
    for (const kind of ['apk', 'exe']) {
      const file = evidenceFile(round.evidence?.packages?.[kind]);
      if (!file || typeof hashes?.[kind] !== 'string' || !/^[a-f0-9]{64}$/.test(hashes[kind]) || sha256(file) !== hashes[kind]) fail(`${tag} ${kind} 安装包不存在或 SHA-256 不符`);
      if (hashes?.[kind] !== last[0]?.evidence?.buildHashes?.[kind]) fail(`${tag} ${kind} 安装包改变`);
    }
    const uncovered = round.evidence?.uncovered;
    if (!Array.isArray(uncovered) || uncovered.some(key => !contract.excluded.includes(key))) fail(`${tag} 存在计划内未覆盖项目或范围声明缺失`);
    acceptedRounds.push(failures.length === failuresBeforeRound);
  }
  let cleanRounds = 0;
  if (report?.status === 'candidate' && Array.isArray(report.unresolved) && !report.unresolved.length && textValue(last[0]?.buildId) && new Set(last.map(r => r?.buildId)).size === 1) {
    for (const accepted of [...acceptedRounds].reverse()) {
      if (!accepted) break;
      cleanRounds++;
    }
  }
  return {accepted: failures.length === 0, cleanRounds, failures, excluded: contract.excluded};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) { process.stderr.write('Usage: node scripts/check-native-acceptance.mjs <rounds.json>\n'); process.exitCode = 2; }
  else {
    try {
      const result = verifyAcceptance(JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), 'utf8').replace(/^\uFEFF/, '')));
      process.stdout.write(JSON.stringify(result, null, 2) + '\n');
      if (!result.accepted) process.exitCode = 1;
    } catch (error) { process.stderr.write(`验收报告读取失败：${error.message}\n`); process.exitCode = 1; }
  }
}
