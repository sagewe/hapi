# Usage query account ownership

The personal template service remains the single quota polling and cache path for
Web and native clients. Codex/agy adapters, 5h/7d windows, grouped agy limits and
plan labels keep their existing wire contract.

## Codex live probes

The Codex adapter reads quotas from one freshly owned app-server process, with a
bounded deadline. It corroborates authenticated `account/read` responses before
and after `account/rateLimits/read`, and verifies the selected local OAuth auth,
CODEX_HOME and complete config snapshot before starting and before returning.
The snapshot fingerprint includes account ID, token rotation and the OpenAI base
URL override. Relative CODEX_HOME values cannot establish native proof because
the Runner and spawned app-server have different working directories; those
probes return unavailable before process startup. Generic API-key/template
credential resolution is unchanged. Email can
corroborate a current app-server response, but is never the account key: two
workspaces/organizations with the same email still have distinct snapshots.
OAuth ID-token email claims are decoded only to compare local account metadata;
this does not validate a JWT or replace authentication by the app-server.

Account/provider/home/profile changes invalidate the cache. The service checks
identity and settings again before returning either success or stale-on-error
windows, including when no replacement query was started. Request generations
also reject superseded A→B→A completions. Current requests still share one
in-flight probe and the existing cache/cooldown; no extra periodic poller exists.

## Historical logs

Recent Codex session JSONL `rate_limits` records have no established producing
OAuth account identity. Session ID, model provider, timestamp and file mtime do
not prove which account produced a row. They are therefore no longer a fallback
when a live probe fails. Old logs are not modified or deleted.

The availability tradeoff is deliberate: if the current OAuth account cannot be
corroborated, a live account read fails, or the deadline expires, the result is
explicitly unavailable instead of showing another account's historical limits.
Auth modes whose account ID or corroborating account metadata is unavailable
cannot supply native subscription quotas through this adapter. Same-account
previously verified results may retain the service's existing stale-on-error
presentation; an identity/config change cannot inherit them.

## Verification

`codexProvenance.test.ts` covers old-account JSONL preservation and refusal,
account A/B with a shared email, token refresh, home/profile changes,
unauthenticated/mismatched accounts, live normalization, deadlines and late
transport completions. `service.test.ts` covers cache invalidation, superseded
requests, account changes without replacement queries, stale failure suppression,
and A→B→A request generations.
