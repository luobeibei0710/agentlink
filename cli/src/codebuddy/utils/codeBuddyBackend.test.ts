import { describe, expect, it } from 'vitest'
import { createCodeBuddyBackend, resolveCodeBuddyAcpCommand } from './codeBuddyBackend'
import { AcpMessageHandler } from '@/agent/backends/acp/AcpMessageHandler'

describe('resolveCodeBuddyAcpCommand', () => {
    it('preserves repeated characters from CodeBuddy delta chunks', () => {
        const backend = createCodeBuddyBackend({})
        const options = (backend as unknown as { options: { textChunkMode: 'delta' } }).options
        const messages: unknown[] = []
        const handler = new AcpMessageHandler(message => messages.push(message), options)
        for (const text of ['FLU', 'T', 'T', 'ER']) {
            handler.handleUpdate({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } })
        }
        handler.drainBuffers()
        expect(messages).toEqual([{ type: 'text', text: 'FLUTTER' }])
    })
    it('uses the installed CLI ACP entrypoint with standard permissions exactly', () => {
        expect(resolveCodeBuddyAcpCommand({})).toEqual({
            command: 'codebuddy',
            args: ['--acp', '--agent', 'cli', '--permission-mode', 'default']
        })
    })

    it('supports an executable override and safe JSON extra arguments', () => {
        expect(resolveCodeBuddyAcpCommand({
            HAPI_CODEBUDDY_ACP_COMMAND: '/opt/codebuddy',
            HAPI_CODEBUDDY_ACP_ARGS_JSON: '["--debug", "api"]'
        })).toEqual({
            command: '/opt/codebuddy',
            args: ['--acp', '--agent', 'cli', '--permission-mode', 'default', '--debug', 'api']
        })
    })

    it('rejects malformed args and every attempt to override transport or permission safety', () => {
        expect(() => resolveCodeBuddyAcpCommand({ HAPI_CODEBUDDY_ACP_ARGS_JSON: 'not-json' }))
            .toThrow('JSON array of strings')
        for (const args of [
            ['--permission-mode', 'auto'],
            ['--permission-mode=bypassPermissions'],
            ['--dangerously-skip-permissions'],
            ['-y'],
            ['--agent', 'custom'],
            ['--acp-transport', 'streamable-http']
        ]) {
            expect(() => resolveCodeBuddyAcpCommand({
                HAPI_CODEBUDDY_ACP_ARGS_JSON: JSON.stringify(args)
            })).toThrow('cannot override')
        }
    })
})
