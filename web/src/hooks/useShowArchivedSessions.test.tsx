import { act, renderHook } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'
import { getInitialShowArchivedSessions, useShowArchivedSessions } from './useShowArchivedSessions'

describe('archive display preference', () => {
    beforeEach(() => window.localStorage.clear())
    it('defaults false and ignores malformed storage', () => {
        expect(getInitialShowArchivedSessions()).toBe(false)
        localStorage.setItem('hapi-show-archived-sessions', 'invalid')
        expect(getInitialShowArchivedSessions()).toBe(false)
    })
    it('persists changes and follows other tabs', () => {
        const { result } = renderHook(useShowArchivedSessions)
        const other = renderHook(useShowArchivedSessions)
        act(() => result.current.setShowArchivedSessions(true))
        expect(getInitialShowArchivedSessions()).toBe(true)
        expect(other.result.current.showArchivedSessions).toBe(true)
        act(() => window.dispatchEvent(new StorageEvent('storage', { key: 'hapi-show-archived-sessions', newValue: null })))
        expect(result.current.showArchivedSessions).toBe(false)
        act(() => result.current.setShowArchivedSessions(false))
        expect(localStorage.getItem('hapi-show-archived-sessions')).toBeNull()
    })
})
