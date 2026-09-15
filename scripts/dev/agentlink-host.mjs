#!/usr/bin/env node
/** Start the fork's Hub + Runner with isolated state. No global HAPI installation required. */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createDeviceHost } from './agentlink-device-host.mjs';
import { companionBindUrl, pairingHtml, parseHostArguments, resolveLanAddress } from './agentlink-lan.mjs';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const { lan, lanIp, workspaceArgument } = parseHostArguments(process.argv.slice(2));
const workspace = resolve(workspaceArgument ?? root);
const bun = process.env.HAPI_BUN_BIN || (process.versions.bun ? process.execPath : 'bun');
const port = process.env.AGENTLINK_PORT || '3106';
if (!existsSync(workspace)) throw new Error(`Workspace does not exist: ${workspace}`);
const lanSelection = lan ? resolveLanAddress(networkInterfaces(), lanIp) : undefined;
const hubHost = lan ? lanSelection.selected.address : '127.0.0.1';
const localApiUrl = `http://${hubHost}:${port}`;
const env = {
    ...process.env,
    HAPI_HOME: process.env.AGENTLINK_HOME || join(homedir(), '.agentlink'),
    HAPI_API_URL: localApiUrl,
    HAPI_LISTEN_HOST: hubHost, HAPI_LISTEN_PORT: port,
    HAPI_ANDROID_PUSH: 'off', HAPI_IOS_PUSH: 'off',
};
const children = [];
let stopping = false;
let deviceHost;
async function stop(code = 0) {
    if (stopping) return;
    stopping = true;
    if (deviceHost) await deviceHost.close();
    // Runner stop intentionally follows HAPI's behavior: existing Agent sessions remain available.
    for (const child of children.reverse()) child.kill('SIGTERM');
    await new Promise(done => setTimeout(done, 1200));
    for (const child of children) if (child.exitCode === null) child.kill('SIGKILL');
    process.exit(code);
}
function start(args) {
    const child = spawn(bun, [join(root, 'cli/src/index.ts'), ...args], { cwd: root, env, stdio: 'inherit' });
    children.push(child);
    child.once('error', error => { console.error(error.message); void stop(1); });
    child.once('exit', code => { if (!stopping) { console.error(`Service exited (${code}); shutting down host.`); void stop(code || 1); } });
    return child;
}

async function assertLocalPortAvailable() {
    const probe = createServer();
    try {
        await new Promise((resolve, reject) => {
            probe.once('error', reject);
            probe.listen({ host: hubHost, port: Number(port), exclusive: true }, resolve);
        });
    } catch (error) {
        if (error?.code === 'EADDRINUSE') {
            throw new Error(`Port ${port} is already in use on ${hubHost}. Stop the known AgentLink/HAPI host or choose AGENTLINK_PORT; this script will not stop an existing process.`);
        }
        throw error;
    } finally {
        if (probe.listening) await new Promise(resolve => probe.close(resolve));
    }
}

process.on('SIGINT', () => void stop());
process.on('SIGTERM', () => void stop());
console.log(`AgentLink workspace: ${workspace}\nState: ${env.HAPI_HOME}\nKeep this terminal running while using the phone.\nForeground notifications only; no background push is configured.`);
if (lanSelection) console.log(`LAN Hub: http://${lanSelection.selected.address}:${port} (${lanSelection.selected.name}); relay disabled.`);
await assertLocalPortAvailable();
start(['hub', '--host', hubHost, '--port', port, ...(lan ? ['--no-relay'] : (process.env.AGENTLINK_NO_RELAY === '1' ? ['--no-relay'] : ['--relay']))]);
let ready = false;
for (let attempt = 0; attempt < 90; attempt++) {
    try {
        const health = await fetch(`${localApiUrl}/health`, { signal: AbortSignal.timeout(1000) });
        if (health.ok) { ready = true; break; }
    } catch {}
    await new Promise(done => setTimeout(done, 1000));
}
if (!ready) { console.error('Hub did not become ready.'); await stop(1); }
const runnerStartedAt = Date.now();
// 历史会话按项目目录分散在用户主目录下，只开放单一工作目录会让 Codex/CodeBuddy 的
// 历史列表被 runner 的 workspace 白名单过滤为空。默认追加用户主目录；需要收紧或扩大
// 范围时用 AGENTLINK_WORKSPACE_ROOTS（逗号分隔，支持 ~ 前缀）覆盖默认值。
const configuredRoots = (process.env.AGENTLINK_WORKSPACE_ROOTS ?? '')
    .split(',')
    .map(value => value.trim())
    .filter(Boolean)
    .map(value => value === '~'
        ? homedir()
        : value.startsWith('~/')
            ? join(homedir(), value.slice(2))
            : value);
const runnerWorkspaceRoots = Array.from(new Set(
    configuredRoots.length > 0 ? configuredRoots : [workspace, homedir()]
));
const workspaceRootArgs = runnerWorkspaceRoots.flatMap(root => ['--workspace-root', root]);
const runner = !stopping ? start(['runner', 'start-sync', ...workspaceRootArgs]) : undefined;
console.log(`Runner workspace roots: ${runnerWorkspaceRoots.join(', ')}`);

async function waitForRunner() {
    const stateFile = join(env.HAPI_HOME, 'runner.state.json');
    for (let attempt = 0; attempt < 90; attempt++) {
        try {
            const state = JSON.parse(await readFile(stateFile, 'utf8'));
            const stateStartedAt = Date.parse(state.startTime);
            process.kill(state.pid, 0);
            if (
                state.pid === runner?.pid
                && Number.isInteger(state.httpPort)
                && state.startedWithApiUrl === localApiUrl
                && Number.isFinite(stateStartedAt)
                && stateStartedAt >= runnerStartedAt - 5_000
            ) return;
        } catch {}
        await new Promise(done => setTimeout(done, 1000));
    }
    throw new Error('Runner did not become ready.');
}

async function announceLanPairing() {
    await waitForRunner();
    const settings = JSON.parse(await readFile(join(env.HAPI_HOME, 'settings.json'), 'utf8'));
    if (typeof settings.cliApiToken !== 'string' || !settings.cliApiToken) throw new Error('Hub settings has no cliApiToken.');
    let authenticated = false;
    for (let attempt = 0; attempt < 90; attempt++) {
        try {
            const auth = await fetch(`${localApiUrl}/api/auth`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ accessToken: settings.cliApiToken }),
                signal: AbortSignal.timeout(1000),
            });
            if (!auth.ok) continue;
            const { token } = await auth.json();
            if (typeof token !== 'string') continue;
            const machines = await fetch(`${localApiUrl}/api/machines`, {
                headers: { Authorization: `Bearer ${token}` },
                signal: AbortSignal.timeout(1000),
            });
            const { machines: machineList } = await machines.json();
            if (
                machines.ok
                && typeof settings.machineId === 'string'
                && Array.isArray(machineList)
                && machineList.some(machine => (
                    machine.active
                    && machine.id === settings.machineId
                    && machine.runnerState?.pid === runner?.pid
                    && machine.runnerState.startedAt >= runnerStartedAt - 5_000
                ))
            ) {
                authenticated = true;
                break;
            }
        } catch {}
        await new Promise(done => setTimeout(done, 1000));
    }
    if (!authenticated) throw new Error('Runner did not register with the Hub.');
    deviceHost = await createDeviceHost({
        bindAddress: lanSelection.selected.address,
        netmask: (networkInterfaces()[lanSelection.selected.name] || []).find(address => address.address === lanSelection.selected.address)?.netmask,
        hapiHome: env.HAPI_HOME,
        hubUrl: localApiUrl,
        cliApiToken: settings.cliApiToken,
        name: settings.machineName || hostname(),
    });
    console.log(`\nAgentLink device pairing is ready at https://${lanSelection.selected.address}:${deviceHost.addresses.tls.port}.\nApprove a phone after comparing its 8-digit SAS: ${deviceHost.adminUrl}`);
    const managerFile = join(env.HAPI_HOME, 'device-manager.html');
    await writeFile(managerFile, `<!doctype html><meta charset="utf-8"><title>AgentLink 电脑管理</title><script>location.replace(${JSON.stringify(deviceHost.adminUrl)})</script>`, { mode: 0o600 });
    await chmod(managerFile, 0o600);
    if (process.env.AGENTLINK_OPEN_ADMIN === '1' && process.platform === 'darwin') {
        const opener = spawn('open', [deviceHost.adminUrl], { stdio: 'ignore', detached: true });
        opener.unref();
    }
    // Retain the original HTTP QR link as an explicit fallback for existing clients.
    const hubUrl = `http://${lanSelection.selected.address}:${port}`;
    const companionUrl = companionBindUrl(hubUrl, settings.cliApiToken);
    const require = createRequire(join(root, 'hub/package.json'));
    const QRCode = require('qrcode');
    const qrOptions = { errorCorrectionLevel: 'L', margin: 4 };
    const terminalQr = await QRCode.toString(companionUrl, { ...qrOptions, type: 'terminal', small: true });
    const qrDataUrl = await QRCode.toDataURL(companionUrl, { ...qrOptions, scale: 8 });
    await mkdir(env.HAPI_HOME, { recursive: true, mode: 0o700 });
    const htmlFile = join(env.HAPI_HOME, 'agentlink-lan-pairing.html');
    await writeFile(htmlFile, pairingHtml({ hubUrl, companionUrl, qrDataUrl }), { mode: 0o600 });
    await chmod(htmlFile, 0o600);
    console.log(`\nLegacy AgentLink LAN pairing QR (Hub: ${hubUrl}):\n${terminalQr}\nLocal pairing page (mode 0600): ${htmlFile}`);
}

if (lan && !stopping) {
    announceLanPairing().catch(async error => {
        console.error(error instanceof Error ? error.message : error);
        await stop(1);
    });
}
