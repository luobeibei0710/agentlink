import chalk from 'chalk'
import { CODEBUDDY_PERMISSION_MODES } from '@hapi/protocol'
import type { PermissionMode } from '@hapi/protocol/types'
import { initializeToken } from '@/ui/tokenInit'
import { maybeAutoStartServer } from '@/utils/autoStartServer'
import { authAndSetupMachineIfNeeded } from '@/ui/auth'
import type { CommandDefinition } from './types'

export type ParsedCodeBuddyCommandOptions = {
    startedBy?: 'runner' | 'terminal'
    startingMode: 'remote'
    permissionMode?: PermissionMode
    resumeSessionId?: string
    existingSessionId?: string
}

function readValue(args: string[], index: number, option: string): string {
    const value = args[index + 1]
    if (!value || value.startsWith('-')) throw new Error(`Missing ${option} value`)
    return value
}

/** Strict parser: wrapper-only flags are accepted and every other flag fails closed. */
export function parseCodeBuddyCommandOptions(commandArgs: string[]): ParsedCodeBuddyCommandOptions {
    const options: ParsedCodeBuddyCommandOptions = { startingMode: 'remote' }
    for (let index = 0; index < commandArgs.length; index += 1) {
        const arg = commandArgs[index]
        if (arg === '--started-by') {
            const value = readValue(commandArgs, index, arg)
            if (value !== 'runner' && value !== 'terminal') throw new Error('Invalid --started-by value')
            options.startedBy = value
            index += 1
        } else if (arg === '--hapi-starting-mode') {
            const value = readValue(commandArgs, index, arg)
            if (value !== 'remote') throw new Error('CodeBuddy only supports remote mode')
            index += 1
        } else if (arg === '--existing-session-id') {
            options.existingSessionId = readValue(commandArgs, index, arg)
            index += 1
        } else if (arg === '--resume') {
            options.resumeSessionId = readValue(commandArgs, index, arg)
            index += 1
        } else if (arg === '--permission-mode') {
            const value = readValue(commandArgs, index, arg)
            if (!(CODEBUDDY_PERMISSION_MODES as readonly string[]).includes(value)) {
                throw new Error(`Unsupported CodeBuddy permission mode: ${value}`)
            }
            options.permissionMode = value as PermissionMode
            index += 1
        } else if (arg === '--yolo' || arg === '-y' || arg === '--dangerously-skip-permissions') {
            throw new Error('CodeBuddy automatic permission bypass is disabled')
        } else {
            throw new Error(`Unknown CodeBuddy option: ${arg}`)
        }
    }
    return options
}

export const codeBuddyCommand: CommandDefinition = {
    name: 'codebuddy',
    requiresRuntimeAssets: true,
    run: async ({ commandArgs }) => {
        try {
            const options = parseCodeBuddyCommandOptions(commandArgs)
            await initializeToken()
            await maybeAutoStartServer()
            await authAndSetupMachineIfNeeded()

            const { runCodeBuddy } = await import('@/codebuddy/runCodeBuddy')
            await runCodeBuddy(options)
        } catch (error) {
            console.error(chalk.red('Error:'), error instanceof Error ? error.message : 'Unknown error')
            if (process.env.DEBUG) console.error(error)
            process.exit(1)
        }
    }
}

