import { describe, expect, it } from 'vitest'
import { parseCodeBuddyCommandOptions } from './codebuddy'

describe('parseCodeBuddyCommandOptions', () => {
    it('accepts the runner lifecycle, native resume id, and standard permission mode', () => {
        expect(parseCodeBuddyCommandOptions([
            '--resume', 'native-session',
            '--hapi-starting-mode', 'remote',
            '--started-by', 'runner',
            '--existing-session-id', 'hapi-session',
            '--permission-mode', 'default'
        ])).toEqual({
            startingMode: 'remote',
            startedBy: 'runner',
            existingSessionId: 'hapi-session',
            resumeSessionId: 'native-session',
            permissionMode: 'default'
        })
    })

    it('accepts every permission mode the ACP server advertises', () => {
        for (const mode of [
            'default',
            'acceptEdits',
            'plan',
            'auto',
            'dontAsk',
            'bypassPermissions',
            'fullAccess',
            'delegate'
        ]) {
            expect(parseCodeBuddyCommandOptions(['--permission-mode', mode]))
                .toMatchObject({ permissionMode: mode })
        }
    })

    it('fails closed on bypass, unknown mode, local, missing-value, and unknown options', () => {
        expect(() => parseCodeBuddyCommandOptions(['--yolo'])).toThrow('bypass is disabled')
        // 白名单之外的档位（例如 Codex 专属的 yolo / read-only）必须被拒绝
        expect(() => parseCodeBuddyCommandOptions(['--permission-mode', 'yolo'])).toThrow('Unsupported')
        expect(() => parseCodeBuddyCommandOptions(['--permission-mode', 'read-only'])).toThrow('Unsupported')
        expect(() => parseCodeBuddyCommandOptions(['--hapi-starting-mode', 'local'])).toThrow('remote mode')
        expect(() => parseCodeBuddyCommandOptions(['--resume'])).toThrow('Missing --resume value')
        expect(() => parseCodeBuddyCommandOptions(['--mystery'])).toThrow('Unknown CodeBuddy option')
    })
})

