import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {configurationHash, verifyAcceptance} from '../scripts/check-native-acceptance.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const contract = JSON.parse(fs.readFileSync(path.join(root, 'docs/native-acceptance.json'), 'utf8'));

test('acceptance requires real, independent evidence and recomputes every measured percentile', () => {
  fs.mkdirSync(path.join(root, '.qa'), {recursive: true});
  const directory = fs.mkdtempSync(path.join(root, '.qa', 'acceptance-unit-fixture-'));
  const write = (name, value) => {
    const file = path.join(directory, name);
    fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
    return file;
  };
  try {
    const apk = write('synthetic.apk', 'synthetic unit fixture; never a delivery artifact');
    const exe = write('synthetic.exe', 'synthetic unit fixture; never a delivery artifact');
    const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    const sourceManifests = {apk: write('apk-manifest.json', {sha256: hash(apk)}), exe: write('exe-manifest.json', {sha256: hash(exe)})};
    const log = write('test.log', 'synthetic check evidence');
    const image = write('test.png', 'synthetic screenshot fixture');
    const configuration = {windows: {os: 'unit', cpu: 'unit', ramMB: 1}, android: {avd: 'unit', api: 26, ramMB: 1}};
    const config = write('configuration.json', configuration);
    const report = {status: 'candidate', unresolved: [], rounds: [0, 1, 2].map(index => {
      const roundId = `unit-${index}`;
      const startedAt = new Date(Date.now() - (4 - index) * 60000).toISOString();
      const finishedAt = new Date(Date.parse(startedAt) + 1000).toISOString();
      const executionLog = write(`${roundId}-checks.log`, `synthetic unit execution ${roundId}; never acceptance evidence`);
      const executionEvidence = write(`${roundId}-execution.json`, {
        roundId, buildId: 'synthetic-only', checkIds: contract.requiredChecks.filter(key => !contract.staticChecks.includes(key)),
        startedAt: new Date(Date.parse(startedAt) + 100).toISOString(), finishedAt: new Date(Date.parse(startedAt) + 800).toISOString(),
        command: 'synthetic unit fixture; not executed software', exitCode: 0, status: 'pass', log: executionLog, artifacts: [executionLog],
      });
      const round = {roundId, startedAt, finishedAt, buildId: 'synthetic-only', mode: 'release', defects: [],
        checks: Object.fromEntries(contract.requiredChecks.map(key => [key, contract.staticChecks.includes(key) ? {
          status: 'pass', evidence: [log], staticEvidence: write(`static-${key}.json`, {
            checkId: key, status: 'pass', buildId: 'synthetic-only', buildHashes: {apk: hash(apk), exe: hash(exe)},
            artifacts: [{path: log, sha256: hash(log)}],
            sourceManifests: Object.fromEntries(Object.entries(sourceManifests).map(([kind, file]) => [kind, {path: file, sha256: hash(file)}])),
          }),
        } : {status: 'pass', evidence: [executionLog], executionEvidence}])), metrics: {},
        evidence: {packages: {apk, exe}, buildHashes: {apk: hash(apk), exe: hash(exe)}, sourceManifests, screenshots: [image], logs: [log], fixedConfiguration: config, uncovered: []}};
      round.evidence.roundLog = write(`${roundId}.json`, {roundId, startedAt, finishedAt, buildId: round.buildId, checks: round.checks});
      for (const metric of Object.keys(contract.metrics)) {
        const samples = Array(20).fill(10);
        const rawEvidence = write(`${roundId}-${metric}.json`, {metric, roundId, buildId: round.buildId, mode: round.mode, configurationSha256: configurationHash(configuration), samples});
        round.metrics[metric] = {mode: round.mode, samples: samples.length, value: metric.endsWith('ScrollFramesOver50msRatio') ? 0 : 10, evidence: [rawEvidence], rawEvidence};
      }
      return round;
    })};
    assert.equal(verifyAcceptance(report).accepted, true);
    const rejected = mutate => {
      const copy = structuredClone(report);
      mutate(copy);
      assert.equal(verifyAcceptance(copy).accepted, false);
    };
    rejected(r => { r.rounds[1] = structuredClone(r.rounds[0]); });
    rejected(r => { r.rounds[1].startedAt = r.rounds[0].startedAt; });
    rejected(r => { r.rounds[0].evidence.logs = [path.join(directory, 'missing.log')]; });
    rejected(r => { r.rounds[0].evidence.screenshots = []; });
    rejected(r => { r.rounds[0].evidence.fixedConfiguration = {}; });
    rejected(r => { r.rounds[0].evidence.fixedConfiguration = write('invalid-configuration.json', {windows: {os: 42, cpu: [], ramMB: 'not-measured'}, android: {avd: [], api: 'unavailable', ramMB: 'not-measured'}}); });
    rejected(r => { r.rounds[1].evidence.fixedConfiguration = write('changed-configuration.json', {...configuration, android: {...configuration.android, api: 37}}); });
    rejected(r => { r.rounds[0].evidence.fixedConfiguration = write('negative-configuration.json', {...configuration, windows: {...configuration.windows, ramMB: -1}}); });
    const reordered = write('reordered-configuration.json', {android: {ramMB: 1, api: 26, avd: 'unit'}, windows: {ramMB: 1, cpu: 'unit', os: 'unit'}});
    const sameConfiguration = structuredClone(report);
    sameConfiguration.rounds[1].evidence.fixedConfiguration = reordered;
    assert.equal(verifyAcceptance(sameConfiguration).accepted, true);
    rejected(r => { r.rounds[0].metrics.windowsSave100kP95Ms.rawEvidence = write('wrong-config-hash.json', {metric: 'windowsSave100kP95Ms', roundId: 'unit-0', buildId: 'synthetic-only', mode: 'release', configurationSha256: 'f'.repeat(64), samples: Array(20).fill(10)}); });
    rejected(r => { r.rounds[0].metrics.windowsSave100kP95Ms.samples = 'not-measured'; });
    rejected(r => { delete r.rounds[0].metrics.androidSave100kP95Ms; });
    rejected(r => { delete r.rounds[0].metrics.androidScrollFramesOver50msRatio; });
    const profile = structuredClone(report);
    for (const round of profile.rounds) {
      for (const metric of Object.keys(contract.metrics).filter(key => !key.includes('ColdStart'))) {
        const evidence = write(`${round.roundId}-profile-${metric}.json`, {
          metric, roundId: round.roundId, buildId: round.buildId, mode: 'profile',
          configurationSha256: configurationHash(configuration), samples: Array(20).fill(10),
        });
        round.metrics[metric] = {...round.metrics[metric], mode: 'profile', evidence: [evidence], rawEvidence: evidence};
      }
    }
    assert.equal(verifyAcceptance(profile).accepted, true);
    const changedMode = structuredClone(profile);
    changedMode.rounds[1].metrics.windowsSave100kP95Ms = structuredClone(report.rounds[1].metrics.windowsSave100kP95Ms);
    assert.equal(verifyAcceptance(changedMode).accepted, false);
    rejected(r => { r.rounds[0].metrics.windowsSave100kP95Ms.value = 1; });
    rejected(r => { r.rounds[0].evidence.buildHashes.apk = 'f'.repeat(64); });
    rejected(r => { r.rounds[0].evidence.uncovered = ['android-api37']; });
    rejected(r => { r.rounds[0].checks['android-api26'].status = 'pending'; });
    rejected(r => { r.rounds[0].defects = ['a regression']; });
    const allFail = structuredClone(report);
    allFail.rounds.forEach(round => { round.defects = ['a regression']; });
    assert.equal(verifyAcceptance(allFail).cleanRounds, 0);
    const failedFirst = structuredClone(report);
    failedFirst.rounds[0].defects = ['a regression'];
    assert.equal(verifyAcceptance(failedFirst).cleanRounds, 2);
    const rewriteRoundLog = round => { round.evidence.roundLog = write(`${round.roundId}-changed-log.json`, {roundId: round.roundId, startedAt: round.startedAt, finishedAt: round.finishedAt, buildId: round.buildId, checks: round.checks}); };
    for (const key of contract.staticChecks) {
      for (const mutation of [
        approval => { approval.buildId = 'previous-candidate'; },
        approval => { approval.buildHashes.apk = 'f'.repeat(64); },
        approval => { approval.sourceManifests.exe.sha256 = 'f'.repeat(64); },
        approval => { approval.artifacts[0].sha256 = 'f'.repeat(64); },
      ]) rejected(r => {
        const check = r.rounds[0].checks[key];
        const approval = JSON.parse(fs.readFileSync(check.staticEvidence, 'utf8'));
        mutation(approval);
        check.staticEvidence = write(`invalid-static-${key}.json`, approval);
        rewriteRoundLog(r.rounds[0]);
      });
    }
    const emptyBuild = structuredClone(report);
    emptyBuild.rounds.forEach(round => { round.buildId = ''; });
    assert.equal(verifyAcceptance(emptyBuild).cleanRounds, 0);
    rejected(r => {
      r.rounds[1].checks['android-api26'] = structuredClone(r.rounds[0].checks['android-api26']);
      rewriteRoundLog(r.rounds[1]);
    });
    for (const [field, value] of [['roundId', 'different'], ['buildId', 'different'], ['exitCode', 1], ['checkIds', []], ['command', ''], ['finishedAt', report.rounds[0].startedAt]]) {
      rejected(r => {
        const check = r.rounds[0].checks['android-api26'];
        const execution = JSON.parse(fs.readFileSync(check.executionEvidence, 'utf8'));
        check.executionEvidence = write(`bad-execution-${field}.json`, {...execution, [field]: value});
        rewriteRoundLog(r.rounds[0]);
      });
    }
    rejected(r => {
      const check = r.rounds[1].checks['android-api26'];
      const execution = JSON.parse(fs.readFileSync(check.executionEvidence, 'utf8'));
      const repeatedLog = write('reused-dynamic-log-copy.log', fs.readFileSync(r.rounds[0].checks['android-api26'].evidence[0], 'utf8'));
      check.evidence = [repeatedLog];
      check.executionEvidence = write('reused-execution-log.json', {...execution, log: repeatedLog, artifacts: [repeatedLog]});
      rewriteRoundLog(r.rounds[1]);
    });
    rejected(r => { r.rounds[0].metrics.windowsScrollFramesOver50msRatio.rawEvidence = log; });
    write('unit-0-windowsSave100kP95Ms.json', {metric: 'windowsSave100kP95Ms', roundId: 'unit-0', buildId: 'synthetic-only', mode: 'release', configurationSha256: configurationHash(configuration), samples: Array(20).fill(350)});
    assert.equal(verifyAcceptance(report).accepted, false);
  } finally {
    const target = fs.realpathSync(directory);
    assert.equal(path.dirname(target), fs.realpathSync(path.join(root, '.qa')));
    assert.match(path.basename(target), /^acceptance-unit-fixture-/);
    fs.rmSync(target, {recursive: true});
  }
});

test('empty or malformed reports never pass acceptance', () => {
  for (const value of [null, {}, [], {status: 'candidate', unresolved: [], rounds: [null, null, null]}]) {
    assert.equal(verifyAcceptance(value).accepted, false);
  }
});
