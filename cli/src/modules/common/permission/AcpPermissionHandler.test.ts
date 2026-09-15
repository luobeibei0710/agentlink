import { describe, expect, it } from 'vitest'
import type { PermissionRequest } from '@/agent/types'
import { mapAcpPermissionDecision } from './AcpPermissionHandler'

function request(options: PermissionRequest['options']): PermissionRequest {
    return {
        id: 'permission-1',
        sessionId: 'session-1',
        toolCallId: 'tool-1',
        options
    }
}

describe('mapAcpPermissionDecision', () => {
    it('maps explicit allow, deny, and abort decisions to matching ACP options', () => {
        const value = request([
            { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
            { optionId: 'allow-always', name: 'Allow always', kind: 'allow_always' },
            { optionId: 'reject-once', name: 'Reject once', kind: 'reject_once' }
        ])
        expect(mapAcpPermissionDecision(value, 'approved')).toEqual({
            outcome: 'selected', optionId: 'allow-once'
        })
        expect(mapAcpPermissionDecision(value, 'approved_for_session')).toEqual({
            outcome: 'selected', optionId: 'allow-always'
        })
        expect(mapAcpPermissionDecision(value, 'denied')).toEqual({
            outcome: 'selected', optionId: 'reject-once'
        })
        expect(mapAcpPermissionDecision(value, 'abort')).toEqual({ outcome: 'cancelled' })
    })

    it('fails closed when the agent supplies no option matching the requested decision', () => {
        expect(mapAcpPermissionDecision(request([
            { optionId: 'reject', name: 'Reject', kind: 'reject_once' }
        ]), 'approved')).toEqual({ outcome: 'cancelled' })
        expect(mapAcpPermissionDecision(request([
            { optionId: 'allow', name: 'Allow', kind: 'allow_once' }
        ]), 'denied')).toEqual({ outcome: 'cancelled' })
        expect(mapAcpPermissionDecision(request([
            { optionId: 'mystery', name: 'Mystery', kind: 'unknown' }
        ]), 'approved')).toEqual({ outcome: 'cancelled' })
    })
})
