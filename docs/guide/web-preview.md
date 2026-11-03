# Remote web previews

The iOS chat menu offers **Web Preview**, and HTTP links to `localhost`,
`127.0.0.1` or `[::1]` open on the current session's machine. The initial scope
is HTTP development servers on explicit ports 1024–65535. Other hosts are not
proxied, and HAPI does not start the development server for you.

The Hub resolves the authorized session's machine rather than accepting a
client-selected machine ID. That Runner must be online and upgraded. Configure
`HAPI_PREVIEW_RELAY_API` (relay hostname) and `HAPI_PREVIEW_RELAY_AUTH` on the
Runner through its secret provider; keep them out of command arguments and Git.
Preview is disabled until these settings are present. The existing tunwg runtime
binary is reused; no new tunnel implementation is required.

Each preview has a random credential and a fixed loopback target. iOS answers
HTTPS Basic authentication only for that preview origin. The gateway issues a
Secure/HttpOnly/SameSite=Strict cookie for resource, SSE and WebSocket requests;
WKWebView does not reliably reuse Basic credentials for WebSockets. Both the
preview Authorization header and reserved cookie are stripped before forwarding.
Cross-origin requests are rejected. Cookies and redirects referring to the local
target are adapted; external top-level navigations stay outside this first version.
Hardcoded localhost URLs in page JavaScript and third-party OAuth are not rewritten.

The Runner allows at most four previews including pending opens. Leases expire
after one hour or approximately ten minutes of inactivity. Closing the iOS view
requests immediate cleanup, while expiry handles disconnected clients. Runner
shutdown also closes preview processes and sockets; the development server itself
is never terminated. An in-flight iOS creation completes and closes its lease if
the view was dismissed while waiting.

Runner private state under `$HAPI_HOME/web-preview/` retains per-target tunwg keys,
certificates and gateway port numbers. Reopening a target can reuse its hostname
instead of requesting a new certificate every time. Access credentials are newly
generated in memory, not stored there. Protect this directory and exclude it from
Git. An occupied retained gateway port fails rather than replacing another service.

Native UI includes back/forward, refresh and retry, using a nonpersistent WebKit
store. The original URL path, query and fragment are preserved. Refresh reuses a
valid lease; an expired lease is recreated. Clipboard, camera and third-party login
flows have not been added or validated in this first integration.

## API

- `POST /api/sessions/:id/preview`: `{ "host": "localhost", "port": 5173 }`.
  Returns `id`, HTTPS `origin`, `username`, `password` and `expiresAt` (epoch ms).
  Responses are `Cache-Control: no-store`; never log or persist the credentials.
- `DELETE /api/sessions/:id/preview/:previewId`: closes that session's lease.
  The Runner verifies session ownership, including when identifiers are guessed.

## Verification

`cli/src/preview/PreviewManager.test.ts` checks loopback/port validation, HTTP and
WebSocket authentication, cookie/header stripping, cross-origin rejection,
expiry and closing the listener. `hub/src/web/routes/preview.test.ts` checks
namespace and session-machine binding. `WebPreviewTests` covers local URL rules
and invalid targets; an opt-in isolated integration server additionally verifies
native automatic authentication, HMR preserving input, Cookie/SSE and close.

The private integration fixture is not deployed to the production Hub/Runner.
Publishing this feature requires coordinated Hub, Runner and iOS updates.
