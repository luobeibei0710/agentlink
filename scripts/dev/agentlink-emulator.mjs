#!/usr/bin/env node
// Integration QA on an explicitly chosen disposable Android emulator only.
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const device = process.env.AGENTLINK_EMULATOR || 'emulator-5580';
if (!device.startsWith('emulator-')) throw new Error('This script is for the disposable emulator; physical testing belongs to the user');
const cleanup = process.argv.includes('--cleanup');
const url = cleanup ? 'http://127.0.0.1:3106' : process.env.AGENTLINK_QA_HUB;
if (!cleanup && !url?.startsWith('https://')) throw new Error('AGENTLINK_QA_HUB must be a trusted HTTPS Hub');
const settings = JSON.parse(await readFile(process.env.AGENTLINK_QA_SETTINGS || '/tmp/agentlink-emulator-host/settings.json', 'utf8'));
const accessToken = settings.cliApiToken;
if (typeof accessToken !== 'string') throw new Error('Missing test Hub access token');
let jwt;
async function api(path, method = 'GET', body) {
  const response = await fetch(url + path, { method, headers: { 'Content-Type': 'application/json', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(95000) });
  const value = await response.json();
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return value;
}
jwt = (await api('/api/auth', 'POST', { accessToken })).token;
if (cleanup) {
  const ids = process.argv.slice(process.argv.indexOf('--cleanup') + 1);
  for (const id of ids) {
    if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error('Invalid explicit QA session id');
    await api(`/api/sessions/${id}/archive`, 'POST', {});
  }
  console.log(`Archived ${ids.length} explicitly selected QA sessions`);
}
if (process.argv.includes('--approval')) {
  const project = resolve(root, 'artifacts/agentlink/workspace');
  await mkdir(resolve(project, '.codebuddy'), { recursive: true });
  await writeFile(resolve(project, '.codebuddy/settings.json'), JSON.stringify({ disableAllHooks: true, permissions: { defaultMode: 'default', ask: ['Write', 'Edit', 'Bash'] } }));
  const machine = (await api('/api/machines')).machines.find(m => m.active);
  const session = await api(`/api/machines/${machine.id}/spawn`, 'POST', { agent: 'codebuddy', directory: project, startingMode: 'remote', permissionMode: 'default' });
  if (session.type !== 'success') throw new Error('Spawn failed');
  const marker = resolve(project, 'emulator-approved.txt');
  await api(`/api/sessions/${session.sessionId}`, 'PATCH', { name: '手机审批验证' });
  await api(`/api/sessions/${session.sessionId}/messages`, 'POST', { text: `Use Write exactly once to create ${marker} containing AGENTLINK_OK. Do not use any other tool or path. If denied, stop immediately.`, localId: `emulator-approval-${Date.now()}` });
  console.log(`Approval QA session ${session.sessionId}; marker ${marker}`);
}
if (process.argv.includes('--seed')) {
  const machine = (await api('/api/machines')).machines.find(m => m.active);
  if (!machine) throw new Error('No active test runner');
  for (const agent of ['codex', 'codebuddy']) {
    const session = await api(`/api/machines/${machine.id}/spawn`, 'POST', { agent, directory: root, startingMode: 'remote', permissionMode: 'default' });
    if (session.type !== 'success') throw new Error('Spawn failed');
    await api(`/api/sessions/${session.sessionId}`, 'PATCH', { name: `${agent === 'codex' ? 'Codex' : 'CodeBuddy'} 手机联调` });
    await api(`/api/sessions/${session.sessionId}/messages`, 'POST', { text: 'Do not use tools. Reply exactly: AGENTLINK_EMULATOR_READY', localId: `emulator-${agent}-${Date.now()}` });
    console.log(`Seeded ${agent} test session ${session.sessionId}`);
  }
}
if (process.argv.includes('--link')) {
  const link = `hapicompanion://bind?hub=${encodeURIComponent(url)}&code=${encodeURIComponent(accessToken)}`;
  // 依次看 ADB / ANDROID_HOME / ANDROID_SDK_ROOT，最后退回 macOS 上的默认安装位置。
  // 这里原先写死了一个绝对路径，只在开发者本机成立，别人跑就找不到 adb。
  const adb = process.env.ADB
    ?? resolve(
      process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT ?? resolve(homedir(), 'Library/Android/sdk'),
      'platform-tools/adb'
    );
  const result = spawnSync(adb, ['-s', device, 'shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', `'${link}'`, 'app.agentlink.companion'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('Emulator could not open pairing link');
  console.log('Pairing link delivered to disposable emulator; token omitted');
}
