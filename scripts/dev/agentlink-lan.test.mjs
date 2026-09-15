import assert from 'node:assert/strict';
import test from 'node:test';
import { collectLanCandidates, companionBindUrl, isRfc1918Address, parseHostArguments, resolveLanAddress } from './agentlink-lan.mjs';

const interfaces = {
    lo0: [{ address: '127.0.0.1', family: 'IPv4', internal: true }],
    en0: [{ address: '192.168.1.20', family: 'IPv4', internal: false }],
    utun4: [{ address: '10.8.0.2', family: 'IPv4', internal: false }],
};

test('recognizes only RFC1918 IPv4 addresses', () => {
    assert.equal(isRfc1918Address('10.0.0.1'), true);
    assert.equal(isRfc1918Address('172.31.255.255'), true);
    assert.equal(isRfc1918Address('172.32.0.1'), false);
    assert.equal(isRfc1918Address('192.168.0.1'), true);
    assert.equal(isRfc1918Address('169.254.1.1'), false);
});

test('selects one physical interface and does not auto-select VPN interfaces', () => {
    assert.deepEqual(resolveLanAddress(interfaces).selected, { name: 'en0', address: '192.168.1.20', virtual: false });
    assert.deepEqual(collectLanCandidates(interfaces), [
        { name: 'en0', address: '192.168.1.20', virtual: false },
        { name: 'utun4', address: '10.8.0.2', virtual: true },
    ]);
});

test('requires an explicit selection for multiple physical interfaces and validates it is assigned', () => {
    const multi = { ...interfaces, en1: [{ address: '192.168.2.20', family: 'IPv4', internal: false }] };
    assert.throws(() => resolveLanAddress(multi), /--lan-ip/);
    assert.equal(resolveLanAddress(multi, '192.168.2.20').selected.name, 'en1');
    assert.throws(() => resolveLanAddress(multi, '192.168.2.99'), /assigned to this computer/);
});

test('builds an encoded companion bind URL', () => {
    assert.equal(companionBindUrl('http://192.168.1.20:3106', 'a+b/c'), 'hapicompanion://bind?hub=http%3A%2F%2F192.168.1.20%3A3106&code=a%2Bb%2Fc');
});

test('keeps the original first-workspace invocation when no LAN IP flag is present', () => {
    assert.deepEqual(parseHostArguments(['/work/project']), { lan: false, lanIp: undefined, workspaceArgument: '/work/project' });
    assert.deepEqual(parseHostArguments(['/work/project', '--lan']), { lan: true, lanIp: undefined, workspaceArgument: '/work/project' });
    assert.deepEqual(parseHostArguments(['--lan', '--lan-ip', '192.168.1.20', '/work/project']), { lan: true, lanIp: '192.168.1.20', workspaceArgument: '/work/project' });
});
