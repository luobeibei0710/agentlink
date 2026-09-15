#!/usr/bin/env node
/** Full local Hub -> Runner -> real CodeBuddy/Codex test; no phone or mock agent. */
import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const bun = process.env.HAPI_BUN_BIN || 'bun';
const scratch = await mkdtemp(join(tmpdir(), 'agentlink-live-'));
const project = join(scratch, 'project');
await mkdir(join(project, '.codebuddy'), { recursive: true });
await writeFile(join(project, '.codebuddy/settings.json'), JSON.stringify({ disableAllHooks: true, permissions: { defaultMode: 'default', ask: ['Write', 'Edit', 'Bash'] } }));
const port = await new Promise(resolvePort => { const server = createServer(); server.listen(0, '127.0.0.1', () => { const value = server.address().port; server.close(() => resolvePort(value)); }); });
const url = `http://127.0.0.1:${port}`;
const token = randomBytes(32).toString('base64url');
const env = { ...process.env, HAPI_HOME: join(scratch, 'hapi'), HAPI_API_URL: url, HAPI_LISTEN_HOST: '127.0.0.1', HAPI_LISTEN_PORT: String(port), CLI_API_TOKEN: token, TELEGRAM_NOTIFICATION: 'false', SERVERCHAN_NOTIFICATION: 'false', HAPI_ANDROID_PUSH: 'off', HAPI_IOS_PUSH: 'off' };
const children = [];
const sessions = [];
const checks = [];
let jwt;
function launch(args, label) {
    const child = spawn(bun, [join(root, 'cli/src/index.ts'), ...args], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
    child.summary = '';
    for (const stream of [child.stdout, child.stderr]) stream.on('data', data => { child.summary = (child.summary + data.toString()).slice(-5000); });
    child.label = label;
    children.push(child);
    return child;
}
async function waitFor(check, label, ms = 90000) {
    const until = Date.now() + ms;
    let lastError;
    while (Date.now() < until) {
        try { const value = await check(); if (value) return value; } catch (error) { lastError = error; }
        await new Promise(resolveDelay => setTimeout(resolveDelay, 600));
    }
    throw new Error(`${label} timed out${lastError ? `: ${lastError.message}` : ''}`);
}
async function api(path, method = 'GET', body, expected = 200) {
    const response = await fetch(url + path, { method, headers: { 'Content-Type': 'application/json', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(95000) });
    const data = await response.json();
    assert.equal(response.status, expected, `${method} ${path}: ${JSON.stringify(data).slice(0,300)}`);
    return data;
}
const detail = async id => (await api(`/api/sessions/${encodeURIComponent(id)}`)).session;
const messages = async id => (await api(`/api/sessions/${encodeURIComponent(id)}/messages?limit=200`)).messages;
const agentText = message => message.content?.role === 'agent' ? JSON.stringify(message.content.content) : '';
const exists = path => stat(path).then(() => true, () => false);
function passed(name) { checks.push(name); console.log(`PASS ${name}`); }
async function send(id, text, localId = randomUUID()) { await api(`/api/sessions/${id}/messages`, 'POST', { text, localId }); return localId; }
async function pending(id) {
    return waitFor(async () => {
        const session = await detail(id);
        const entries = Object.entries(session.agentState?.requests ?? {});
        return entries.length ? entries[0] : null;
    }, 'pending tool permission');
}
let failed;
try {
    launch(['hub', '--host', '127.0.0.1', '--port', String(port)], 'hub');
    const health = await waitFor(async () => { try { return await (await fetch(url + '/health', { signal: AbortSignal.timeout(1000) })).json(); } catch { return null; } }, 'hub startup', 25000);
    assert.equal(health.status, 'ok');
    assert.ok(Number.isInteger(health.protocolVersion));
    const denied = await fetch(url + '/api/sessions');
    assert.equal(denied.status, 401);
    jwt = (await api('/api/auth', 'POST', { accessToken: token })).token;
    assert.ok(jwt);
    passed('real hub health / auth / unauthorized isolation');
    launch(['runner', 'start-sync', '--workspace-root', project], 'runner');
    const machine = await waitFor(async () => (await api('/api/machines')).machines.find(value => value.active), 'runner registration', 35000);
    const availability = await waitFor(async () => {
        const value = await api(`/api/machines/${machine.id}/agent-availability`);
        return Array.isArray(value.agents) ? value : null;
    }, 'runner availability RPC registration', 30000);
    console.log(`INFO agent availability keys: ${Object.keys(availability).join(',')}`);
    passed('real runner registered');
    const result = await api(`/api/machines/${machine.id}/spawn`, 'POST', { directory: project, agent: 'codebuddy', permissionMode: 'default', startingMode: 'remote' });
    assert.equal(result.type, 'success', JSON.stringify(result));
    const id = result.sessionId;
    sessions.push(id);
    await waitFor(async () => (await detail(id)).metadata?.codebuddySessionId, 'CodeBuddy ACP session metadata');
    const messageId = await send(id, 'No tools. Reply exactly AGENTLINK_HUB_CODEBUDDY_READY.');
    await waitFor(async () => (await messages(id)).some(message => agentText(message).includes('AGENTLINK_HUB_CODEBUDDY_READY')), 'CodeBuddy real reply');
    await send(id, 'No tools. Reply exactly AGENTLINK_HUB_CODEBUDDY_READY.', messageId);
    assert.equal((await messages(id)).filter(message => message.localId === messageId).length, 1);
    passed('CodeBuddy spawn / real chat / stable localId deduplication');
    await api(`/api/sessions/${id}`, 'PATCH', { name: 'AgentLink 联调 CodeBuddy' });
    assert.equal((await detail(id)).metadata?.name, 'AgentLink 联调 CodeBuddy');
    assert.equal((await detail(id)).metadata?.flavor, 'codebuddy');
    passed('title rename persisted with correct provider');
    if (process.env.AGENTLINK_DART_BIN) {
        await new Promise((resolveProbe, rejectProbe) => {
            const probe = spawn(process.env.AGENTLINK_DART_BIN, ['--packages=' + join(root, 'flutter/.dart_tool/package_config.json'), join(root, 'scripts/dev/flutter-hapi-live.dart')], {
                cwd: root, env: { ...process.env, AGENTLINK_TEST_HUB: url, AGENTLINK_TEST_TOKEN: token, AGENTLINK_TEST_SESSION: id }, stdio: ['ignore', 'pipe', 'pipe'],
            });
            let output = '';
            for (const stream of [probe.stdout, probe.stderr]) stream.on('data', data => { output = (output + data.toString()).slice(-5000); });
            probe.on('error', rejectProbe);
            probe.on('exit', code => code === 0 ? resolveProbe() : rejectProbe(new Error('Flutter live protocol probe: ' + output.replaceAll(token, '[redacted]'))));
        });
        passed('Flutter actual HTTP client / auth / send / real CodeBuddy reply decoding');
    }
    for (const decision of ['deny', 'approve', 'abort']) {
        const file = join(project, `${decision}-marker.txt`);
        await send(id, `This is a permission test. Use Write exactly once to create ${file} containing AGENTLINK_OK. Do not use any other tool or path. If denied or cancelled, stop and do not retry.`);
        const [requestId, request] = await pending(id);
        assert.ok(JSON.stringify(request).includes(file), 'Permission must identify the intended scratch operation');
        if (decision === 'abort') await api(`/api/sessions/${id}/abort`, 'POST', {});
        else await api(`/api/sessions/${id}/permissions/${encodeURIComponent(requestId)}/${decision}`, 'POST', { decision: decision === 'approve' ? 'approved' : 'denied' });
        await waitFor(async () => !(await detail(id)).agentState?.requests?.[requestId], 'permission resolution');
        if (decision === 'approve') await waitFor(() => exists(file), 'approved file creation');
        else assert.equal(await exists(file), false, 'Denied/aborted operation must not execute');
        await api(`/api/sessions/${id}/permissions/${encodeURIComponent(requestId)}/approve`, 'POST', { decision: 'approved' }, 404);
        passed(`CodeBuddy ${decision} / real filesystem outcome / stale approval rejected`);
    }
    await api(`/api/sessions/${id}/archive`, 'POST', {});
    await waitFor(async () => !(await detail(id)).active, 'archive session');
    const reopened = await api(`/api/sessions/${id}/resume`, 'POST', {});
    assert.equal(reopened.type, 'success');
    if (reopened.sessionId !== id) sessions.push(reopened.sessionId);
    await send(reopened.sessionId, 'No tools. Reply exactly AGENTLINK_CODEBUDDY_RESUMED.');
    await waitFor(async () => (await messages(reopened.sessionId)).some(message => agentText(message).includes('AGENTLINK_CODEBUDDY_RESUMED')), 'resumed CodeBuddy reply');
    passed('CodeBuddy archive / resume / subsequent real reply');
    const codex = await api(`/api/machines/${machine.id}/spawn`, 'POST', { directory: project, agent: 'codex', permissionMode: 'default', startingMode: 'remote' });
    assert.equal(codex.type, 'success', JSON.stringify(codex));
    sessions.push(codex.sessionId);
    await send(codex.sessionId, 'Do not use any tools. Reply exactly AGENTLINK_HUB_CODEX_READY.');
    await waitFor(async () => (await messages(codex.sessionId)).some(message => agentText(message).includes('AGENTLINK_HUB_CODEX_READY')), 'Codex real reply');
    assert.equal((await detail(codex.sessionId)).metadata.flavor, 'codex');
    assert.equal((await messages(codex.sessionId)).some(message => agentText(message).includes('AGENTLINK_CODEBUDDY_RESUMED')), false);
    passed('Codex real reply / provider session isolation');
} catch (error) {
    failed = error;
    console.error(`FAIL ${error.message.replaceAll(token, '[redacted]').replaceAll(jwt ?? '___', '[redacted]')}`);
    for (const child of children) {
        const errors = child.summary.split('\n').filter(line => /error|failed|exception|not found/i.test(line));
        console.error(`${child.label} diagnostics: ${errors.slice(-6).join('\n').replaceAll(token, '[redacted]').replaceAll(jwt ?? '___', '[redacted]')}`);
    }
} finally {
    for (const id of sessions) { try { await api(`/api/sessions/${id}/archive`, 'POST', {}); } catch {} }
    for (const child of children.reverse()) child.kill('SIGTERM');
    await new Promise(resolveDelay => setTimeout(resolveDelay, 1200));
    for (const child of children) if (child.exitCode === null) child.kill('SIGKILL');
    // A failed run preserves only its isolated test home for local diagnosis.
    if (!failed) await rm(scratch, { recursive: true, force: true });
    else console.error(`Scratch diagnostics: ${scratch}`);
    console.log(JSON.stringify({ passed: !failed, checks, phoneTested: false }));
    process.exitCode = failed ? 1 : 0;
}
