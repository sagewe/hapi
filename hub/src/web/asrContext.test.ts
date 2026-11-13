import { describe, expect, test } from 'bun:test'
import type { SyncEngine } from '../sync/syncEngine'
import type { Store } from '../store'
import { extractAsrVocabulary, resolveAsrContext, encodeAsrContext } from './asrContext'

describe('ASR context', () => {
    test('extracts vocabulary without credentials, URLs, full paths or code blocks', () => {
        const ctx = extractAsrVocabulary([
            '修复 DotsHoldDictation.swift 与 MyDots\nAPI_KEY=sk-private-test\nBearer abcdef\n```\nHiddenCode\n```\nhttps://private.example/secret /Users/sage/private/file.ts\n/Users/sage/project/UsefulModule.ts'
        ])
        expect(ctx.keywords).toContain('DotsHoldDictation.swift')
        expect(ctx.keywords).toContain('MyDots')
        expect(JSON.stringify(ctx)).not.toMatch(/private|HiddenCode|abcdef|Users/)
        expect(ctx.keywords).toContain('UsefulModule.ts')
        expect(extractAsrVocabulary(Array.from({length: 200}, (_, i) => `Module${i}`)).keywords).toHaveLength(40)
    })
    test('freezes one recording, isolates sessions and checks access before cache lookup', () => {
        let name = 'InitialProject'
        let allowed = true
        const engine = {
            resolveSessionAccess: (id: string, namespace: string) => allowed && namespace === 'owner'
                ? { ok: true, sessionId: id, session: { metadata: { name, path: '/home/project' } } }
                : { ok: false, reason: 'access-denied' }
        } as unknown as SyncEngine
        const store = { messages: { getMessages: () => [] } } as unknown as Store
        const first = resolveAsrContext(engine, store, 'owner', 'session-a', 'OriginalDraft', 'recording-test')
        name = 'ChangedProject'
        const fallback = resolveAsrContext(engine, store, 'owner', 'session-a', 'ChangedDraft', 'recording-test')
        expect(fallback).toEqual(first)
        const second = resolveAsrContext(engine, store, 'owner', 'session-b', '', 'recording-test')
        expect(second.keywords).toContain('ChangedProject')
        expect(second.keywords).not.toContain('OriginalDraft')
        allowed = false
        expect(() => resolveAsrContext(engine, store, 'owner', 'session-a', '', 'recording-test')).toThrow()
        expect(JSON.parse(Buffer.from(encodeAsrContext(first), 'base64').toString())).toEqual(first)
    })
    test('no session remains usable without reading history', () => {
        expect(resolveAsrContext(null, undefined, 'owner', undefined)).toEqual({ keywords: [] })
    })
})
