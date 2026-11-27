/// <reference lib="webworker" />
import { precacheAndRoute } from 'workbox-precaching'
import { registerRoute } from 'workbox-routing'
import { CacheFirst, NetworkOnly } from 'workbox-strategies'
import { ExpirationPlugin } from 'workbox-expiration'
import {
    cleanupExpiredShareTransfers,
    ingestShareRequest,
    putShareTransfer,
} from './lib/shareTransfer'
import { shareTargetPathname } from './lib/sharePath'
import { cacheJavaScriptOnly } from './lib/swCachePolicy'

const sharePath = shareTargetPathname()

declare const self: ServiceWorkerGlobalScope & {
    __WB_MANIFEST: Array<string | { url: string; revision?: string }>
}

type PushPayload = {
    title: string
    body?: string
    icon?: string
    badge?: string
    tag?: string
    data?: {
        type?: string
        sessionId?: string
        url?: string
    }
}

precacheAndRoute(self.__WB_MANIFEST)

registerRoute(
    ({ url }) => url.origin === self.location.origin && /\/assets\/shiki-[^/]+\.js$/.test(url.pathname),
    new CacheFirst({
        cacheName: 'syntax-grammars',
        plugins: [
            cacheJavaScriptOnly,
            new ExpirationPlugin({ maxEntries: 64, maxAgeSeconds: 60 * 60 * 24 * 30 }),
        ],
    }),
)

// Never cache authenticated Reins v1 API responses in the shared service worker
// cache — responses are scoped by Bearer JWT namespace, so URL-keyed caching
// would leak across accounts/namespaces on timeout or offline fallback.
registerRoute(
    ({ url }) => url.pathname === '/v1/sessions'
        || /^\/v1\/sessions\/[^/]+$/.test(url.pathname)
        || url.pathname === '/v1/machines',
    new NetworkOnly()
)

registerRoute(
    /^https:\/\/telegram\.org\/.*/,
    new CacheFirst({
        cacheName: 'cdn-telegram',
        plugins: [
            new ExpirationPlugin({
                maxEntries: 5,
                maxAgeSeconds: 60 * 60 * 24 * 7
            })
        ]
    })
)

self.addEventListener('message', (event) => {
    if (event.data?.type === 'SKIP_WAITING') {
        self.skipWaiting()
    }
})

self.addEventListener('activate', (event) => {
    event.waitUntil(self.clients.claim())
})

self.addEventListener('push', (event) => {
    const payload = event.data?.json() as PushPayload | undefined
    if (!payload) {
        return
    }

    const title = payload.title || 'HAPI'
    const body = payload.body ?? ''
    const icon = payload.icon ?? '/pwa-192x192.png'
    const badge = payload.badge ?? '/pwa-64x64.png'
    const data = payload.data
    const tag = payload.tag

    event.waitUntil(
        self.registration.showNotification(title, {
            body,
            icon,
            badge,
            data,
            tag
        })
    )
})

self.addEventListener('notificationclick', (event) => {
    event.notification.close()
    const data = event.notification.data as { url?: string } | undefined
    const url = data?.url ?? '/'
    event.waitUntil(self.clients.openWindow(url))
})

// Web Share Target — manifest declares POST /share, Android Chrome posts a
// multipart form with title/text/url/files. Stash in IDB so the SPA route
// can read it after the 303 redirect (which converts POST -> GET).
self.addEventListener('fetch', (event) => {
    const request = event.request
    if (request.method !== 'POST') return
    const url = new URL(request.url)
    if (url.pathname !== sharePath) return

    event.respondWith(handleShareTarget(request))
})

async function handleShareTarget(request: Request): Promise<Response> {
    // Resolve to absolute URLs because Response.redirect throws on relative
    // input per the Fetch spec; Chrome currently tolerates relative paths
    // but the SW spec is explicit and the cost of resolving is one line.
    const origin = self.location.origin
    try {
        const { redirectTo } = await ingestShareRequest(request, { put: putShareTransfer })
        return Response.redirect(new URL(redirectTo, origin).toString(), 303)
    } catch (error) {
        // Surface a minimal page if IDB write fails — don't 5xx silently or
        // the user gets a Chrome error sheet instead of useful UI.
        console.error('share-target ingest failed', error)
        return Response.redirect(new URL(`${sharePath}?error=ingest`, origin).toString(), 303)
    }
}

// Best-effort GC for stale share transfers (TTL-only — never blocks
// anything else). 1h TTL is set in shareTransfer.ts.
self.addEventListener('activate', (event) => {
    event.waitUntil(
        cleanupExpiredShareTransfers().catch((error) => {
            console.warn('share-transfer cleanup failed', error)
        })
    )
})
