import { AcpSdkBackend } from '@/agent/backends/acp'

type CodeBuddyAcpEnvironment = Record<string, string | undefined>

const SAFE_BASE_ARGS = ['--acp', '--agent', 'cli', '--permission-mode', 'default'] as const
const PROTECTED_OPTIONS = [
    '--acp',
    '--acp-transport',
    '--agent',
    '--permission-mode',
    '--dangerously-skip-permissions',
    '-y'
] as const

function filterEnv(env: NodeJS.ProcessEnv): Record<string, string> {
    return Object.fromEntries(
        Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined)
    )
}

function parseExtraArgs(raw: string): string[] {
    let value: unknown
    try {
        value = JSON.parse(raw)
    } catch {
        throw new Error('HAPI_CODEBUDDY_ACP_ARGS_JSON must be a JSON array of strings')
    }
    if (!Array.isArray(value) || value.some((arg) => typeof arg !== 'string')) {
        throw new Error('HAPI_CODEBUDDY_ACP_ARGS_JSON must be a JSON array of strings')
    }

    for (const arg of value) {
        const protectedOption = PROTECTED_OPTIONS.find(
            (option) => arg === option || arg.startsWith(`${option}=`)
        )
        if (protectedOption) {
            throw new Error(`HAPI_CODEBUDDY_ACP_ARGS_JSON cannot override ${protectedOption}`)
        }
    }
    return value
}

export function resolveCodeBuddyAcpCommand(env: CodeBuddyAcpEnvironment = process.env): {
    command: string
    args: string[]
} {
    const command = env.HAPI_CODEBUDDY_ACP_COMMAND?.trim() || 'codebuddy'
    const extraArgs = env.HAPI_CODEBUDDY_ACP_ARGS_JSON?.trim()
        ? parseExtraArgs(env.HAPI_CODEBUDDY_ACP_ARGS_JSON.trim())
        : []
    return { command, args: [...SAFE_BASE_ARGS, ...extraArgs] }
}

export function createCodeBuddyBackend(env: NodeJS.ProcessEnv = process.env): AcpSdkBackend {
    const { command, args } = resolveCodeBuddyAcpCommand(env)
    return new AcpSdkBackend({
        command,
        args,
        env: filterEnv(env),
        flavor: 'codebuddy',
        // ACP chunks are deltas; overlap removal corrupts repeated characters
        // (for example FLUTTER became FLUTER in the live client probe).
        textChunkMode: 'delta'
    })
}
