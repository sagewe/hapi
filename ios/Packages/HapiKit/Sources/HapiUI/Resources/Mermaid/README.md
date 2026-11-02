# Offline Mermaid resource

Engine: Mermaid 11.14.0, matching this checkout's web bun.lock.

Classic-script bundle source (includes its bundled dependency notices):
https://github.com/tiann/hapi/blob/b1309767229e129cba530cd05de41b628949c1c0/android/app/src/main/assets/mermaid/mermaid.min.js

SHA-256: `217b66ef4279c33c141b4afe22effad10a91c02558dc70917be2c0981e78ed87`

This is the self-contained bundle proposed in upstream Android PR #2161.
It exports `globalThis.mermaid` and requires no module server, CDN or runtime
imports. The upstream MIT license is in LICENSE, retrieved from
https://github.com/mermaid-js/mermaid/blob/develop/LICENSE on 2026-11-02.
Keep the bundle, notices and provenance together when updating. Run the
app-hosted MermaidRenderingTests after an engine or WebKit wrapper update.
