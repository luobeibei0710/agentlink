#!/usr/bin/env node
/** Live CodeBuddy protocol probe. Uses an isolated scratch directory and never logs credentials. */
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const mode = process.argv[2] ?? 'handshake';
if (!['handshake', 'chat', 'allow', 'deny'].includes(mode)) throw new Error('Expected handshake, chat, allow or deny');
const cwd = await mkdtemp(join(tmpdir(), 'agentlink-acp-'));
const marker = join(cwd, 'approved-marker.txt');
const pending = new Map();
const report = { mode, protocol: null, capabilities: null, updates: 0, permissionRequests: 0, decisions: [], passed: false };
const child = spawn(process.env.CODEBUDDY_BIN || 'codebuddy', [
    '--acp', '--agent', 'cli', '--permission-mode', 'default',
    '--settings', JSON.stringify({ disableAllHooks: true, permissions: { defaultMode: 'default', ask: ['Write', 'Edit', 'Bash'] } }),
], { cwd, stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
let nextId = 1;
let text = '';
let stderrBytes = 0;
const send = value => child.stdin.write(`${JSON.stringify(value)}\n`);
const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 90000);
    pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
    send({ jsonrpc: '2.0', id, method, params });
});
const lines = createInterface({ input: child.stdout });
lines.on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.method === 'session/request_permission' && message.id !== undefined) {
        report.permissionRequests++;
        const options = message.params?.options ?? [];
        const call = message.params?.toolCall ?? {};
        const targetsScratch = JSON.stringify(call).includes(marker);
        const kind = mode === 'allow' && targetsScratch ? 'allow_once' : 'reject_once';
        const option = options.find(value => value.kind === kind && typeof value.optionId === 'string');
        report.decisions.push({ requested: kind, selected: option?.kind ?? 'cancelled', scratchOperation: targetsScratch });
        send({ jsonrpc: '2.0', id: message.id, result: { outcome: option ? { outcome: 'selected', optionId: option.optionId } : { outcome: 'cancelled' } } });
    } else if (message.method === 'session/update') {
        report.updates++;
        const update = message.params?.update;
        if (update?.sessionUpdate === 'agent_message_chunk' && update.content?.type === 'text') text += update.content.text;
    } else if (message.method && message.id !== undefined) {
        send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Client capability not advertised' } });
    } else if (pending.has(message.id)) {
        const item = pending.get(message.id);
        pending.delete(message.id);
        message.error ? item.reject(new Error(`ACP error ${message.error.code}: ${String(message.error.message).slice(0,160)}`)) : item.resolve(message.result);
    }
});
child.stderr.on('data', data => { stderrBytes += data.length; });
child.on('error', error => { for (const item of pending.values()) item.reject(error); pending.clear(); });
child.on('exit', code => { for (const item of pending.values()) item.reject(new Error(`CodeBuddy exited ${code}`)); pending.clear(); });

try {
    const initialized = await rpc('initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false }, clientInfo: { name: 'agentlink-smoke', version: '0.1.0' } });
    report.protocol = initialized.protocolVersion;
    report.capabilities = initialized.agentCapabilities;
    const session = await rpc('session/new', { cwd, mcpServers: [] });
    report.sessionCreated = typeof session.sessionId === 'string';
    if (mode !== 'handshake') {
        const prompt = mode === 'chat'
            ? 'Do not invoke any tools. Reply with exactly AGENTLINK_CODEBUDDY_READY.'
            : `This is an isolated permission integration test. Use the Write tool exactly once to create ${marker} with content AGENTLINK_APPROVED. Do not use other tools or paths. If permission is denied, stop immediately and do not retry or use a different tool.`;
        const result = await rpc('session/prompt', { sessionId: session.sessionId, prompt: [{ type: 'text', text: prompt }] });
        report.stopReason = result.stopReason;
        report.replyReceived = text.length > 0;
        if (mode === 'chat') report.passed = text.includes('AGENTLINK_CODEBUDDY_READY');
        else {
            const exists = await stat(marker).then(() => true, () => false);
            report.markerExists = exists;
            report.passed = report.permissionRequests > 0 && (mode === 'deny'
                ? !exists && report.decisions.every(value => value.selected !== 'allow_once')
                : exists && (await readFile(marker, 'utf8')).includes('AGENTLINK_APPROVED') && report.decisions.some(value => value.selected === 'allow_once'));
        }
    } else report.passed = report.protocol === 1 && report.sessionCreated;
} catch (error) {
    report.error = error.message;
} finally {
    report.stderrBytes = stderrBytes;
    child.kill('SIGTERM');
    lines.close();
    const killTimer = setTimeout(() => child.kill('SIGKILL'), 2000);
    killTimer.unref();
    await rm(cwd, { recursive: true, force: true });
    console.log(JSON.stringify(report, null, 2));
    process.exitCode = report.passed ? 0 : 1;
}
