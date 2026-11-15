import { afterEach, describe, expect, it, vi } from 'vitest'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { ApiSessionClient } from '@/api/apiSession'
import { startHappyServer } from './startHappyServer'

type Outcome = { isError?: boolean; structuredContent?: Record<string, unknown>; content?: Array<{ text?: string }> }
let stop: (() => void) | undefined
let mcp: Client | undefined
afterEach(async () => { await mcp?.close(); stop?.(); mcp = undefined; stop = undefined })

function session(locked = false) {
    let metadata = { path: '/tmp', host: 'test', name: 'User title', titleLocked: locked, tags: ['UserTag'] }
    const client = {
        getMetadata: vi.fn(() => metadata),
        refreshMetadata: vi.fn(async () => true), flushMetadata: vi.fn(async () => true),
        updateMetadata: vi.fn((update: (old: typeof metadata) => typeof metadata) => { metadata = update(metadata) }),
        getSessionTagsContext: vi.fn(async () => ({ tags: ['UserTag'], availableTags: ['UserTag', 'Networking'], titleLocked: locked, truncated: false })),
        appendSessionTags: vi.fn(async (tags: string[]) => ({ tags: ['UserTag', ...tags], added: tags, skipped: [] as string[], limitReached: false })),
    }
    return client
}
async function connect(client: ReturnType<typeof session>, options?: Parameters<typeof startHappyServer>[1]) {
    const server = await startHappyServer(client as unknown as ApiSessionClient, options)
    stop = server.stop
    mcp = new Client({ name: 'hapi-tags-test', version: '1' })
    await mcp.connect(new StreamableHTTPClientTransport(new URL(server.url)))
    client.updateMetadata.mockClear()
    return mcp
}

describe('session tag MCP contract', () => {
    it('advertises append-only tags and read-only vocabulary independently of native title support', async () => {
        const client = session(true)
        const api = await connect(client, { enableChangeTitle: false })
        const tools = (await api.listTools()).tools
        expect(tools.some((tool) => tool.name === 'change_title')).toBe(false)
        expect(tools.find((tool) => tool.name === 'list_tags')?.annotations?.readOnlyHint).toBe(true)
        expect(tools.find((tool) => tool.name === 'add_tags')?.inputSchema.properties).toMatchObject({ tags: { minItems: 1, maxItems: 3 } })
        const listed = await api.callTool({ name: 'list_tags', arguments: {} }) as Outcome
        expect(listed.structuredContent).toEqual(await client.getSessionTagsContext())
        expect(client.appendSessionTags).not.toHaveBeenCalled()
        expect(client.updateMetadata).not.toHaveBeenCalled()
    })

    it('appends normalized tags while preserving a locked name', async () => {
        const client = session(true)
        const api = await connect(client)
        const result = await api.callTool({ name: 'change_title', arguments: { title: 'Agent name', tags: [' Networking ', 'networking'] } }) as Outcome
        expect(result.isError).toBe(false)
        expect(result.structuredContent).toMatchObject({ success: true, titleChanged: false, titleLocked: true, tags: ['UserTag', 'Networking'], tagsAdded: ['Networking'], tagsSkipped: [] })
        expect(client.getMetadata().name).toBe('User title')
        expect(client.updateMetadata).not.toHaveBeenCalled()
        expect(client.appendSessionTags).toHaveBeenCalledExactlyOnceWith(['Networking'])
    })

    it('tags-only works when title is locked without invoking title callbacks', async () => {
        const client = session(true)
        const onChangeTitle = vi.fn()
        const api = await connect(client, { onChangeTitle })
        const result = await api.callTool({ name: 'add_tags', arguments: { tags: ['Networking'] } }) as Outcome
        expect(result.structuredContent).toMatchObject({ titleChanged: false, titleLocked: true, tagsAdded: ['Networking'] })
        expect(onChangeTitle).not.toHaveBeenCalled()
        expect(client.refreshMetadata).not.toHaveBeenCalled()
    })

    it('keeps title-only calls functional without tag API support', async () => {
        const client = session()
        client.appendSessionTags.mockRejectedValue(new Error('Old Hub'))
        const api = await connect(client)
        const result = await api.callTool({ name: 'change_title', arguments: { title: 'New topic' } }) as Outcome
        expect(result.isError).toBe(false)
        expect(result.structuredContent).toMatchObject({ titleChanged: true, titleLocked: false, tagsAdded: [] })
        expect(client.getMetadata().name).toBe('New topic')
        expect(client.appendSessionTags).not.toHaveBeenCalled()
        expect(client.getSessionTagsContext).not.toHaveBeenCalled()
    })

    it('reports a partial title success when a tag append cannot be confirmed', async () => {
        const client = session()
        client.appendSessionTags.mockRejectedValue(new Error('Session tags are unavailable on this Hub'))
        const api = await connect(client)
        const result = await api.callTool({ name: 'change_title', arguments: { title: 'New topic', tags: ['Networking'] } }) as Outcome
        expect(result.isError).toBe(true)
        expect(result.structuredContent).toMatchObject({ success: false, titleChanged: true, tagsAdded: [], tagsError: 'Session tags are unavailable on this Hub' })
        expect(client.getMetadata().name).toBe('New topic')
    })

    it('reports tag limits and skips without claiming additions', async () => {
        const client = session()
        client.appendSessionTags.mockResolvedValue({ tags: ['UserTag'], added: [], skipped: ['Networking'], limitReached: true })
        const api = await connect(client)
        const result = await api.callTool({ name: 'add_tags', arguments: { tags: ['Networking'] } }) as Outcome
        expect(result.structuredContent).toMatchObject({ tagsAdded: [], tagsSkipped: ['Networking'], limitReached: true })
    })

    it.each([
        {}, { tags: [] }, { tags: ['a', 'b', 'c', 'd'] }, { tags: ['x'.repeat(65)] }, { tags: [' '] },
        { title: 'Rename', tags: [] }, { title: '  ', tags: ['valid'] }, { tags: ['a'], namespace: 'other' },
    ])('rejects invalid arguments without title or tag writes: %j', async (args) => {
        const client = session()
        const api = await connect(client)
        const result = await api.callTool({ name: 'change_title', arguments: args }) as Outcome
        expect(result.isError).toBe(true)
        expect(client.updateMetadata).not.toHaveBeenCalled()
        expect(client.appendSessionTags).not.toHaveBeenCalled()
    })

    it.each(['change_title', 'add_tags'])('defers %s without touching parent metadata or tags, even with a lock', async (name) => {
        const client = session(true)
        const api = await connect(client, { emitTitleSummary: false })
        const args = name === 'change_title' ? { title: 'Child name', tags: ['Networking'] } : { tags: ['Networking'] }
        const result = await api.callTool({ name, arguments: args }) as Outcome
        expect(result.isError).toBe(false)
        expect(result.structuredContent).toMatchObject({ success: true, deferred: true, titleChanged: false, titleLocked: null, tagsAdded: [] })
        expect(result.content?.[0].text).toContain('"success":true,"deferred":true')
        expect(client.refreshMetadata).not.toHaveBeenCalled()
        expect(client.getSessionTagsContext).not.toHaveBeenCalled()
        expect(client.appendSessionTags).not.toHaveBeenCalled()
        expect(client.updateMetadata).not.toHaveBeenCalled()
    })

    it('reports unsupported tag APIs explicitly without metadata fallback', async () => {
        const client = session()
        client.getSessionTagsContext.mockRejectedValue(new Error('Session tags are unavailable on this Hub or session; upgrade the Hub'))
        const api = await connect(client)
        const result = await api.callTool({ name: 'add_tags', arguments: { tags: ['Networking'] } }) as Outcome
        expect(result.isError).toBe(true)
        expect(result.content?.[0].text).toContain('Session tags are unavailable')
        expect(client.appendSessionTags).not.toHaveBeenCalled()
        expect(client.updateMetadata).not.toHaveBeenCalled()
    })
})
