import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createDeviceHost } from './agentlink-device-host.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const nonce = Buffer.alloc(32, 7).toString('base64url');
async function listen(server) { await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve)); return server.address().port; }
async function request(base, path, init = {}) { return fetch(base + path, { ...init, headers: { 'Content-Type': 'application/json', ...init.headers }, body: init.body === undefined ? undefined : JSON.stringify(init.body) }); }
function pinnedRequest(base, certificate, expectedFingerprint, path, init = {}) {
    const url = new URL(path, base); const raw = init.body === undefined ? undefined : JSON.stringify(init.body);
    return new Promise((resolve, reject) => {
        const request = httpsRequest(url, { method: init.method || 'GET', ca: certificate, headers: { 'Content-Type': 'application/json', ...init.headers, ...(raw ? { 'Content-Length': Buffer.byteLength(raw) } : {}) }, checkServerIdentity: (name, cert) => cert.fingerprint256.replaceAll(':', '').toLowerCase() === expectedFingerprint ? undefined : new Error('unexpected TLS certificate') }, response => {
            const chunks = []; response.on('data', chunk => chunks.push(chunk)); response.once('aborted', () => reject(new Error('response aborted'))); response.on('error', reject); response.on('end', () => { const text = Buffer.concat(chunks).toString('utf8'); resolve({ status: response.statusCode, json: async () => JSON.parse(text) }); });
        }); request.on('error', reject); if (raw) request.end(raw); else request.end();
    });
}

test('requires TLS-pinned device credentials and supports pairing lifecycle', async () => {
    const home = await mkdtemp(join(tmpdir(), 'agentlink-device-host-'));
    const upstream = createServer(async (req, res) => {
        if (req.url === '/api/auth') { let raw = ''; for await (const part of req) raw += part; assert.deepEqual(JSON.parse(raw), { accessToken: 'cli-secret' }); res.end(JSON.stringify({ token: 'hub-jwt' })); return; }
        if (req.url === '/api/partial') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('{"partial":'); setTimeout(() => res.destroy(), 10); return; }
        if (req.url === '/api/machines?cursor=next') assert.equal(req.headers.authorization, 'Bearer hub-jwt');
        res.end(JSON.stringify({ ok: true, path: req.url }));
    });
    const upstreamPort = await listen(upstream);
    let clock = 1_000;
    let host = await createDeviceHost({ bindAddress: '127.0.0.1', hapiHome: home, hubUrl: `http://127.0.0.1:${upstreamPort}`, cliApiToken: 'cli-secret', tlsPort: 0, discoveryPort: 0, adminPort: 0, now: () => clock });
    const tlsPort = host.addresses.tls.port; const adminPort = host.addresses.admin.port;
        const base = `https://127.0.0.1:${tlsPort}`;
    const certificate = await (await import('node:fs/promises')).readFile(join(home, 'device-link', 'device-link.cert.pem'));
    const pinnedFetch = (path, init = {}) => pinnedRequest(base, certificate, host.fingerprint, path, init);
    try {
        const info = await pinnedFetch('/link/info'); assert.equal(info.status, 200); assert.equal((await info.json()).fingerprint, host.fingerprint);
        const unauthorized = await pinnedFetch('/health'); assert.equal(unauthorized.status, 401);
        const page = await fetch(`http://127.0.0.1:${adminPort}/`); assert.equal(page.status, 200);
        const challenge = await (await pinnedFetch('/link/challenge', { method: 'POST' })).json();
        const expectedCommitment = hash(`agentlink-commit-v1\n${host.fingerprint}\n${'not-known'}\n${challenge.requestId}`);
        assert.notEqual(challenge.commitment, expectedCommitment);
        const pairing = await (await pinnedFetch('/link/requests', { method: 'POST', body: { requestId: challenge.requestId, clientNonce: nonce, deviceName: 'Test phone' } })).json();
        assert.equal(hash(`agentlink-commit-v1\n${host.fingerprint}\n${pairing.serverNonce}\n${challenge.requestId}`), challenge.commitment);
        assert.equal(pairing.sas, String(parseInt(hash(`agentlink-pair-v1\n${host.fingerprint}\n${pairing.serverNonce}\n${nonce}\n${challenge.requestId}`).slice(0, 8), 16) % 100_000_000).padStart(8, '0'));
        let poll = await pinnedFetch(`/link/requests/${challenge.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce } }); assert.equal((await poll.json()).status, 'pending');
        const denied = await request(`http://127.0.0.1:${adminPort}`, `/admin/requests/${challenge.requestId}/deny`, { method: 'POST', headers: { Host: `127.0.0.1:${adminPort}`, Origin: 'http://evil.example', 'x-agentlink-admin': host.adminUrl.split('#')[1] } }); assert.equal(denied.status, 403);
        const adminHeaders = { Host: `127.0.0.1:${adminPort}`, 'x-agentlink-admin': host.adminUrl.split('#')[1] };
        await request(`http://127.0.0.1:${adminPort}`, `/admin/requests/${challenge.requestId}/deny`, { method: 'POST', headers: adminHeaders });
        poll = await pinnedFetch(`/link/requests/${challenge.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce } }); assert.equal((await poll.json()).status, 'denied');
        const cancelled = await (await pinnedFetch('/link/challenge', { method: 'POST' })).json(); const nonce3 = Buffer.alloc(32, 9).toString('base64url');
        await pinnedFetch('/link/requests', { method: 'POST', body: { requestId: cancelled.requestId, clientNonce: nonce3, deviceName: 'Cancelled phone' } });
        const cancellation = await pinnedFetch(`/link/requests/${cancelled.requestId}/cancel`, { method: 'POST', body: { clientNonce: nonce3 } }); assert.deepEqual(await cancellation.json(), { status: 'denied' });
        await request(`http://127.0.0.1:${adminPort}`, `/admin/requests/${cancelled.requestId}/approve`, { method: 'POST', headers: adminHeaders });
        poll = await pinnedFetch(`/link/requests/${cancelled.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce3 } }); assert.equal((await poll.json()).status, 'denied');
        const second = await (await pinnedFetch('/link/challenge', { method: 'POST' })).json();
        const third = await (await pinnedFetch('/link/challenge', { method: 'POST' })).json(); const nonce2 = Buffer.alloc(32, 8).toString('base64url');
        await pinnedFetch('/link/requests', { method: 'POST', body: { requestId: second.requestId, clientNonce: nonce, deviceName: 'Test phone' } });
        await pinnedFetch('/link/requests', { method: 'POST', body: { requestId: third.requestId, clientNonce: nonce2, deviceName: 'Second phone' } });
        await Promise.all([request(`http://127.0.0.1:${adminPort}`, `/admin/requests/${second.requestId}/approve`, { method: 'POST', headers: adminHeaders }), request(`http://127.0.0.1:${adminPort}`, `/admin/requests/${third.requestId}/approve`, { method: 'POST', headers: adminHeaders })]);
        poll = await pinnedFetch(`/link/requests/${second.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce } }); const credential = await poll.json(); assert.equal(credential.status, 'approved'); assert.ok(credential.deviceToken);
        poll = await pinnedFetch(`/link/requests/${third.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce2 } }); const credential2 = await poll.json(); assert.equal(credential2.status, 'approved');
        const valid = await pinnedFetch('/api/auth', { method: 'POST', headers: { 'x-agentlink-device-token': credential.deviceToken } }); assert.equal(valid.status, 200); assert.deepEqual(await valid.json(), { token: 'hub-jwt' });
        const forwarded = await pinnedFetch('/api/machines?cursor=next', { headers: { 'x-agentlink-device-token': credential.deviceToken, Authorization: 'Bearer hub-jwt' } }); assert.equal(forwarded.status, 200); assert.deepEqual(await forwarded.json(), { ok: true, path: '/api/machines?cursor=next' });
        await assert.rejects(pinnedFetch('/api/partial', { headers: { 'x-agentlink-device-token': credential.deviceToken, Authorization: 'Bearer hub-jwt' } }), /aborted/);
        await host.close();
        host = await createDeviceHost({ bindAddress: '127.0.0.1', hapiHome: home, hubUrl: `http://127.0.0.1:${upstreamPort}`, cliApiToken: 'cli-secret', tlsPort, discoveryPort: 0, adminPort, now: () => clock });
        const restartedFirst = await pinnedFetch('/health', { headers: { 'x-agentlink-device-token': credential.deviceToken } }); assert.equal(restartedFirst.status, 200);
        const restartedSecond = await pinnedFetch('/health', { headers: { 'x-agentlink-device-token': credential2.deviceToken } }); assert.equal(restartedSecond.status, 200);
        const wrong = await pinnedFetch('/health', { headers: { 'x-agentlink-device-token': 'wrong' } }); assert.equal(wrong.status, 401);
        await request(`http://127.0.0.1:${adminPort}`, `/admin/devices/${credential.deviceId}/revoke`, { method: 'POST', headers: adminHeaders });
        const revoked = await pinnedFetch('/health', { headers: { 'x-agentlink-device-token': credential.deviceToken } }); assert.equal(revoked.status, 401);
        await host.close();
        host = await createDeviceHost({ bindAddress: '127.0.0.1', hapiHome: home, hubUrl: `http://127.0.0.1:${upstreamPort}`, cliApiToken: 'cli-secret', tlsPort, discoveryPort: 0, adminPort, now: () => clock });
        const revokedAfterRestart = await pinnedFetch('/health', { headers: { 'x-agentlink-device-token': credential.deviceToken } }); assert.equal(revokedAfterRestart.status, 401);
        const expires = await (await pinnedFetch('/link/challenge', { method: 'POST' })).json(); clock += 120_001;
        const expired = await pinnedFetch(`/link/requests/${expires.requestId}/poll`, { method: 'POST', body: { clientNonce: nonce } }); assert.equal((await expired.json()).status, 'expired');
    } finally { await host.close(); await new Promise(resolve => upstream.close(resolve)); await rm(home, { recursive: true, force: true }); }
});

test('closes already-bound sockets when a later startup bind fails', async () => {
    const home = await mkdtemp(join(tmpdir(), 'agentlink-device-host-bind-'));
    const blocked = createServer(); const adminPort = await listen(blocked);
    const reservation = createServer(); const tlsPort = await listen(reservation); await new Promise(resolve => reservation.close(resolve));
    try {
        await assert.rejects(createDeviceHost({ bindAddress: '127.0.0.1', hapiHome: home, hubUrl: 'http://127.0.0.1:1', cliApiToken: 'cli-secret', tlsPort, discoveryPort: 0, adminPort }));
        const probe = createServer(); await new Promise((resolve, reject) => probe.once('error', reject).listen(tlsPort, '127.0.0.1', resolve)); await new Promise(resolve => probe.close(resolve));
    } finally { await new Promise(resolve => blocked.close(resolve)); await rm(home, { recursive: true, force: true }); }
});
