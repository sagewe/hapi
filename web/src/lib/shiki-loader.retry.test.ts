import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
    create: vi.fn(), load: vi.fn(), loaded: [] as string[],
}))
vi.mock('shiki/core', () => ({ createHighlighterCore: mocks.create }))
vi.mock('shiki/engine/javascript', () => ({ createJavaScriptRegexEngine: () => ({}) }))
vi.mock('@shikijs/langs/typescript', () => ({ default: [{ name: 'typescript' }] }))
vi.mock('@shikijs/themes/github-light', () => ({ default: { name: 'github-light' } }))
vi.mock('@shikijs/themes/github-dark', () => ({ default: { name: 'github-dark' } }))

beforeEach(() => {
    vi.resetModules()
    mocks.create.mockReset()
    mocks.load.mockReset()
    mocks.loaded.length = 0
    mocks.load.mockImplementation(async (grammar: Promise<unknown>) => {
        await grammar
        mocks.loaded.push('typescript')
    })
    mocks.create.mockResolvedValue({ getLoadedLanguages: () => mocks.loaded, loadLanguage: mocks.load })
})

describe('on-demand grammar retry and cache ownership', () => {
    it('does not initialize the core for unsupported or plain-text requests', async () => {
        const { getLanguageHighlighter } = await import('./shiki-loader')
        expect(await getLanguageHighlighter('text')).toBeNull()
        expect(await getLanguageHighlighter('unknown')).toBeNull()
        expect(mocks.create).not.toHaveBeenCalled()
        expect(mocks.load).not.toHaveBeenCalled()
    })

    it('retries failed core creation without poisoning future requests', async () => {
        mocks.create.mockRejectedValueOnce(new Error('theme chunk unavailable'))
        const { getLanguageHighlighter } = await import('./shiki-loader')
        await expect(getLanguageHighlighter('typescript')).rejects.toThrow('theme chunk unavailable')
        expect(await getLanguageHighlighter('typescript')).not.toBeNull()
        await getLanguageHighlighter('typescript')
        expect(mocks.create).toHaveBeenCalledTimes(2)
        expect(mocks.load).toHaveBeenCalledTimes(1)
    })

    it('shares one rejected grammar load and permits a later retry while reusing the core', async () => {
        mocks.load.mockRejectedValueOnce(new Error('grammar unavailable'))
        const { getLanguageHighlighter } = await import('./shiki-loader')
        const outcomes = await Promise.allSettled([
            getLanguageHighlighter('typescript'), getLanguageHighlighter('typescript'),
        ])
        expect(outcomes.map((outcome) => outcome.status)).toEqual(['rejected', 'rejected'])
        expect(mocks.load).toHaveBeenCalledTimes(1)
        const first = await getLanguageHighlighter('typescript')
        const second = await getLanguageHighlighter('typescript')
        expect(first).toBe(second)
        expect(mocks.create).toHaveBeenCalledTimes(1)
        expect(mocks.load).toHaveBeenCalledTimes(2)
    })
})
