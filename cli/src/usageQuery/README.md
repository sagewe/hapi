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
probes return unavailable before process startup. Homes whose raw environment
value would be changed by trimming are also rejected. Generic API-key/template
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
A cached Codex value additionally requires a fresh identity-only effective-store
and account check, with no `account/rateLimits/read` request. Concurrent cache
readers share that check. A forced refresh cannot join this weaker check and skip
the required quota fetch; the old proof's generation cannot replace the new
result. Successful checks do not renew the quota observation's timestamp or TTL.

## Selected credential store

Local `auth.json` cannot prove the selected account when Codex uses keyring,
auto or ephemeral storage. A known local non-file mode is rejected before
process startup. Otherwise the native process must explicitly report effective
`cli_auth_credentials_store = "file"` through `config/read` before and after the
account/quota operations. This accounts for configuration layers and managed
requirements: a local root `file` setting alone is not sufficient evidence.
Missing/default local settings are allowed when the effective response proves
file mode; absent/unsupported/ambiguous effective metadata returns unavailable.
The code does not force file mode, edit auth/config, or directly access Keychain.
The selected Codex subprocess may consult its configured OS store during startup
before it can answer `config/read`; this does not make that store attributable to
the file snapshot.

Source checked 2026-11-15: Codex's [store enum](https://github.com/openai/codex/blob/main/codex-rs/config/src/types.rs)
defaults to file; [auto storage](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs)
checks keyring before fallback; the [configuration reference](https://developers.openai.com/codex/config-reference/)
describes effective credential-store modes and managed requirements.


## Historical logs

Recent Codex session JSONL `rate_limits` records have no established producing
OAuth account identity. Session ID, model provider, timestamp and file mtime do
not prove which account produced a row. They are therefore no longer a fallback
when a live probe fails. Old logs are not modified or deleted.

The availability tradeoff is deliberate: if the current OAuth account cannot be
corroborated, a live account read fails, or the deadline expires, the result is
explicitly unavailable instead of showing another account's historical limits.
Auth modes whose account ID or corroborating account metadata is unavailable
cannot supply native subscription quotas through this adapter. Native proof or query failures do not attach older cached windows. Other
template adapters retain their existing same-account stale-on-error behavior;
an identity/config change cannot inherit those values.

## Verification

`codexProvenance.test.ts` covers old-account JSONL preservation and refusal,
account A/B with a shared email, token refresh, home/profile changes,
unauthenticated/mismatched accounts, live normalization, deadlines and late
transport completions. `service.test.ts` covers cache invalidation, superseded
requests, account changes without replacement queries, stale failure suppression,
and A→B→A request generations.
