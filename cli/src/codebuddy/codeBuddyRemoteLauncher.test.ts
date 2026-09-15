import { afterEach, describe, expect, it, vi } from 'vitest'
import { MessageQueue2 } from '@/utils/MessageQueue2'
import type { CodeBuddyMode } from './types'

const harness = vi.hoisted(() => ({
    backend: null as Record<string, ReturnType<typeof vi.fn>> | null,
    loadSupported: true,
    newSessionConfig: null as unknown,
    loadSessionConfig: null as unknown,
    prompts: [] as unknown[][],
    /** prompt 执行期间的钩子：此时 backend 仍挂着，可触发 Hub 下发的配置变更。 */
    onPrompt: null as (() => Promise<void>) | null
}))

vi.mock('./utils/codeBuddyBackend', () => ({
    createCodeBuddyBackend: vi.fn(() => {
        const backend = {
            initialize: vi.fn(async () => {}),
            supportsLoadSession: vi.fn(() => harness.loadSupported),
            newSession: vi.fn(async (config: unknown) => {
                harness.newSessionConfig = config
                return 'codebuddy-new-1'
            }),
            loadSession: vi.fn(async (config: unknown) => {
                harness.loadSessionConfig = config
                return 'codebuddy-loaded-1'
            }),
            prompt: vi.fn(async (_sessionId: string, content: unknown[], onUpdate: (message: unknown) => void) => {
                harness.prompts.push(content)
                await harness.onPrompt?.()
                onUpdate({ type: 'reasoning', text: 'thinking' })
                onUpdate({ type: 'tool_call', id: 'tool-1', name: 'Read', input: { path: '/tmp/a' } })
                onUpdate({ type: 'tool_result', id: 'tool-1', output: 'ok' })
                onUpdate({ type: 'text', text: 'answer' })
            }),
            cancelPrompt: vi.fn(async () => {}),
            onStderrError: vi.fn(),
            onPermissionRequest: vi.fn(),
            setConfigOption: vi.fn(async () => {}),
            disconnect: vi.fn(async () => {})
        }
        harness.backend = backend
        return backend
    })
}))

vi.mock('@/modules/common/permission/AcpPermissionHandler', () => ({
    AcpPermissionHandler: class {
        async cancelAll(): Promise<void> {}
    }
}))

vi.mock('@/ui/ink/RemoteModeDisplay', () => ({ RemoteModeDisplay: () => null }))
vi.mock('@/ui/logger', () => ({ logger: { debug: vi.fn(), warn: vi.fn() } }))

import { CodeBuddyRemoteLauncher } from './codeBuddyRemoteLauncher'

function createSession(sessionId: string | null, withPrompt = true) {
    const queue = new MessageQueue2<CodeBuddyMode>((mode) => JSON.stringify(mode))
    if (withPrompt) queue.push('first', 'codebuddy')
    queue.close()

    // 记录注册进来的 RPC handler，测试可直接触发权限切换。
    const handlers = new Map<string, (payload: unknown) => Promise<unknown>>()

    const session = {
        path: '/tmp/codebuddy-test',
        logPath: '/tmp/codebuddy-test/hapi.log',
        client: {
            rpcHandlerManager: {
                registerHandler: vi.fn(
                    (method: string, handler: (payload: unknown) => Promise<unknown>) => {
                        handlers.set(method, handler)
                    }
                )
            },
            flushMetadata: vi.fn(async () => true),
            emitSessionReady: vi.fn()
        },
        queue,
        sessionId,
        handlers,
        // launcher 通过这两个方法读写当前权限档位。
        permissionMode: 'default' as string | undefined,
        getPermissionMode: vi.fn(() => session.permissionMode),
        setPermissionMode: vi.fn((mode: string) => {
            session.permissionMode = mode
        }),
        onSessionFound: vi.fn((id: string) => { session.sessionId = id }),
        onThinkingChange: vi.fn(),
        sendAgentMessage: vi.fn(),
        sendSessionEvent: vi.fn()
    }
    return session
}

describe('CodeBuddyRemoteLauncher', () => {
    afterEach(() => {
        harness.backend = null
        harness.loadSupported = true
        harness.newSessionConfig = null
        harness.loadSessionConfig = null
        harness.prompts = []
        harness.onPrompt = null
    })

    it('creates an ACP session and forwards streamed text, reasoning, tool call, and tool result events', async () => {
        const session = createSession(null)
        const launcher = new CodeBuddyRemoteLauncher(session as never)

        await launcher.launch()

        expect(harness.backend?.newSession).toHaveBeenCalledWith({
            cwd: '/tmp/codebuddy-test',
            mcpServers: []
        })
        expect(session.onSessionFound).toHaveBeenCalledWith('codebuddy-new-1')
        expect(session.client.emitSessionReady).toHaveBeenCalledTimes(1)
        expect(session.client.flushMetadata).toHaveBeenCalledTimes(1)
        expect(harness.prompts).toEqual([[{ type: 'text', text: 'first' }]])
        expect(session.sendAgentMessage).toHaveBeenCalledTimes(4)
        expect(session.sendSessionEvent).toHaveBeenCalledWith({ type: 'ready' })
    })

    it('loads an existing native session only when ACP advertises load support', async () => {
        const session = createSession('native-session', false)
        await new CodeBuddyRemoteLauncher(session as never).launch()

        expect(harness.backend?.loadSession).toHaveBeenCalledWith({
            sessionId: 'native-session',
            cwd: '/tmp/codebuddy-test',
            mcpServers: []
        })
        expect(harness.backend?.newSession).not.toHaveBeenCalled()
        expect(session.onSessionFound).toHaveBeenCalledWith('codebuddy-loaded-1')
        expect(session.client.emitSessionReady).toHaveBeenCalledTimes(1)
    })

    it('refuses resume and never creates a replacement session when load is not advertised', async () => {
        harness.loadSupported = false
        const session = createSession('native-session', false)

        await expect(new CodeBuddyRemoteLauncher(session as never).launch())
            .rejects.toThrow('does not advertise session history resume')
        expect(harness.backend?.loadSession).not.toHaveBeenCalled()
        expect(harness.backend?.newSession).not.toHaveBeenCalled()
        expect(session.client.emitSessionReady).not.toHaveBeenCalled()
    })

    it('does not signal ready before native session metadata reaches Hub', async () => {
        const session = createSession(null, false)
        session.client.flushMetadata.mockResolvedValue(false)
        await expect(new CodeBuddyRemoteLauncher(session as never).launch())
            .rejects.toThrow('metadata was not acknowledged')
        expect(session.client.emitSessionReady).not.toHaveBeenCalled()
    })

    it('applies a non-default session permission mode to the ACP session on launch', async () => {
        // 恢复一个此前被设为 plan 的会话时，第一个 turn 就必须是 plan。
        const session = createSession(null)
        session.permissionMode = 'plan'

        await new CodeBuddyRemoteLauncher(session as never).launch()

        expect(harness.backend?.setConfigOption)
            .toHaveBeenCalledWith('codebuddy-new-1', 'mode', 'plan')
    })

    it('switches the ACP permission mode when the Hub sends session config', async () => {
        const session = createSession(null)
        let reply: unknown
        harness.onPrompt = async () => {
            const handler = session.handlers.get('set-session-config')
            expect(handler).toBeDefined()
            reply = await handler!({ permissionMode: 'bypassPermissions' })
        }

        await new CodeBuddyRemoteLauncher(session as never).launch()

        expect(harness.backend?.setConfigOption)
            .toHaveBeenCalledWith('codebuddy-new-1', 'mode', 'bypassPermissions')
        expect(session.permissionMode).toBe('bypassPermissions')
        expect(reply).toMatchObject({ applied: { permissionMode: 'bypassPermissions' } })
    })
})
