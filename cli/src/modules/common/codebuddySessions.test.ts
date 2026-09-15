import { afterEach, describe, expect, it } from 'vitest'
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { AGENT_MESSAGE_PAYLOAD_TYPE } from '@hapi/protocol'
import {
    listLocalCodeBuddySessionSummaries,
    listLocalCodeBuddySessionsWithMessages,
    listLocalCodeBuddySessionsWithMessagesByIds
} from './codebuddySessions'

/** 在临时 CodeBuddy home 下写入一个会话文件，返回其路径。 */
function writeSession(root: string, project: string, sessionId: string, records: unknown[]): string {
    const dir = join(root, 'projects', project)
    mkdirSync(dir, { recursive: true })
    const file = join(dir, `${sessionId}.jsonl`)
    writeFileSync(file, records.map((record) => JSON.stringify(record)).join('\n'))
    return file
}

describe('listLocalCodeBuddySessionSummaries', () => {
    const originalHome = process.env.CODEBUDDY_HOME

    afterEach(() => {
        if (originalHome === undefined) delete process.env.CODEBUDDY_HOME
        else process.env.CODEBUDDY_HOME = originalHome
    })

    it('prefers the summary record as the session title', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'session-1', [
            { id: 'r1', type: 'summary', summary: '修复登录页', cwd: '/Users/test/project', timestamp: 1 },
            { id: 'r2', type: 'message', role: 'user', content: [{ type: 'input_text', text: '原始提问' }], cwd: '/Users/test/project', timestamp: 2 }
        ])

        const sessions = listLocalCodeBuddySessionSummaries()

        expect(sessions).toHaveLength(1)
        expect(sessions[0]).toMatchObject({
            id: 'session-1',
            title: '修复登录页',
            cwd: '/Users/test/project',
            lastUserMessage: '原始提问'
        })
        rmSync(root, { recursive: true, force: true })
    })

    it('falls back to the first user message when no summary exists', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'session-2', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '帮我优化构建速度' }], cwd: '/Users/test/project', timestamp: 1 }
        ])

        expect(listLocalCodeBuddySessionSummaries()[0]?.title).toBe('帮我优化构建速度')
        rmSync(root, { recursive: true, force: true })
    })

    it('counts messages in summary mode without loading their bodies', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'session-count', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '问题' }], cwd: '/Users/test/project', timestamp: 1 },
            { id: 'r2', type: 'function_call', name: 'Read', callId: 'c1', arguments: '{}', cwd: '/Users/test/project', timestamp: 2 },
            { id: 'r3', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '回答' }], cwd: '/Users/test/project', timestamp: 3 }
        ])

        const sessions = listLocalCodeBuddySessionSummaries()

        expect(sessions[0]?.messageCount).toBe(3)
        expect(sessions[0]).not.toHaveProperty('messages')
        rmSync(root, { recursive: true, force: true })
    })

    it('ignores host-injected reminders when choosing a title', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'session-synthetic', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '<system-reminder data-role="tool-hint">内部提示' }], cwd: '/Users/test/project', timestamp: 1 },
            { id: 'r2', type: 'message', role: 'user', content: [{ type: 'input_text', text: '真正的提问' }], cwd: '/Users/test/project', timestamp: 2 }
        ])

        expect(listLocalCodeBuddySessionSummaries()[0]?.title).toBe('真正的提问')
        rmSync(root, { recursive: true, force: true })
    })

    it('skips empty session files and ephemeral workspaces', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        // 仅创建、没有对话内容的会话文件。
        writeSession(root, 'Users-test-project', 'empty-session', [])
        // 临时工作目录下的会话属于一次性运行，不应出现在历史列表。
        writeSession(root, 'private-var-folders-tmp', 'temp-session', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '测试' }], cwd: '/private/var/folders/xx/T/agentlink-acp-1', timestamp: 1 }
        ])
        writeSession(root, 'Users-test-project', 'real-session', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '真实会话' }], cwd: '/Users/test/project', timestamp: 1 }
        ])

        const sessions = listLocalCodeBuddySessionSummaries()

        expect(sessions.map((session) => session.id)).toEqual(['real-session'])
        rmSync(root, { recursive: true, force: true })
    })

    it('orders sessions by most recent modification time', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        const older = writeSession(root, 'Users-test-a', 'older', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '旧' }], cwd: '/Users/test/a', timestamp: 1 }
        ])
        const newer = writeSession(root, 'Users-test-b', 'newer', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '新' }], cwd: '/Users/test/b', timestamp: 1 }
        ])
        // 显式拉开修改时间，避免同秒写入导致排序不确定。
        const now = Date.now()
        utimesSync(older, new Date(now - 60_000), new Date(now - 60_000))
        utimesSync(newer, new Date(now), new Date(now))

        expect(listLocalCodeBuddySessionSummaries().map((session) => session.id)).toEqual(['newer', 'older'])
        rmSync(root, { recursive: true, force: true })
    })
})

describe('listLocalCodeBuddySessionsWithMessages', () => {
    const originalHome = process.env.CODEBUDDY_HOME

    afterEach(() => {
        if (originalHome === undefined) delete process.env.CODEBUDDY_HOME
        else process.env.CODEBUDDY_HOME = originalHome
    })

    it('converts conversation and tool records into importable messages', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'session-3', [
            { id: 'm1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '写一个文件' }], cwd: '/Users/test/project', timestamp: 100 },
            // reasoning 属于内部状态，不应进入历史对话。
            { id: 'm2', type: 'reasoning', content: [], rawContent: [{ type: 'reasoning_text', text: '思考中' }], cwd: '/Users/test/project', timestamp: 101 },
            { id: 'm3', type: 'function_call', name: 'Write', callId: 'call-1', arguments: '{"path":"a.txt"}', cwd: '/Users/test/project', timestamp: 102 },
            { id: 'm4', type: 'function_call_result', callId: 'call-1', output: 'ok', cwd: '/Users/test/project', timestamp: 103 },
            { id: 'm5', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '已完成' }], cwd: '/Users/test/project', timestamp: 104 }
        ])

        const sessions = listLocalCodeBuddySessionsWithMessages()
        const messages = sessions[0]?.messages ?? []

        expect(messages).toHaveLength(4)
        expect(messages[0]).toMatchObject({
            localId: 'm1',
            createdAt: 100,
            content: { role: 'user', content: { type: 'text', text: '写一个文件' } }
        })
        expect(messages[1]?.content).toMatchObject({
            role: 'agent',
            content: { type: AGENT_MESSAGE_PAYLOAD_TYPE, data: { type: 'tool-call', name: 'Write', callId: 'call-1', input: { path: 'a.txt' } } }
        })
        expect(messages[2]?.content).toMatchObject({
            role: 'agent',
            content: { type: AGENT_MESSAGE_PAYLOAD_TYPE, data: { type: 'tool-call-result', callId: 'call-1', output: 'ok' } }
        })
        expect(messages[3]?.content).toMatchObject({
            role: 'agent',
            content: { type: AGENT_MESSAGE_PAYLOAD_TYPE, data: { type: 'message', message: '已完成' } }
        })
        rmSync(root, { recursive: true, force: true })
    })

    it('loads full messages only for the requested session ids', () => {
        const root = mkdtempSync(join(tmpdir(), 'codebuddy-home-'))
        process.env.CODEBUDDY_HOME = root
        writeSession(root, 'Users-test-project', 'wanted', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '要的' }], cwd: '/Users/test/project', timestamp: 1 }
        ])
        writeSession(root, 'Users-test-project', 'other', [
            { id: 'r1', type: 'message', role: 'user', content: [{ type: 'input_text', text: '不要的' }], cwd: '/Users/test/project', timestamp: 2 }
        ])

        const sessions = listLocalCodeBuddySessionsWithMessagesByIds(new Set(['wanted']))

        expect(sessions.map((session) => session.id)).toEqual(['wanted'])
        expect(sessions[0]?.messages).toHaveLength(1)
        rmSync(root, { recursive: true, force: true })
    })
})
