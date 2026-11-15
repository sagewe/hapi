# Personal fork overlap review: 2026-11-15

Scope: personal `d151f28d`, upstream main `6c38c50f`, and the upstream commits named below. This is a source comparison and local test record, not a production deployment or a claim of new device verification.

## Absorbed improvements

### ACP delta text: #2332 / `90fbb417`

The upstream agy factory explicitly selects `textChunkMode: 'delta'`. The personal factory still selected overlap deduplication, even though its dedicated `AgyAcpDriver` owns the actual ACP path. A valid boundary such as `73-8` followed by `800` could therefore lose a repeated `8`.

The personal factory now selects delta mode. This preserves the existing bounded live stream snapshots, transcript continuation ownership, immediate prompt acknowledgement, and the shared backend's separate concurrent-prompt whole-reply suppression. The new regression uses the real factory, checks repeated characters and identical ordinary chunks, and retains the existing concurrent-Steer acknowledgement/usage regression.

The old agy concurrent-watcher equality heuristic remains deliberately scoped to a turn that has seen a concurrent prompt. Because that native wire has no stable text-event identity, identical legitimate chunks during concurrent prompt delivery remain ambiguous. Delta mode fixes ordinary stream overlap loss; it does not claim to eliminate every native watcher ambiguity.

### Runner upload streaming: #2429 / `30835911`

The upstream implementation provides useful sequential `uploadInit`, `uploadChunk`, `uploadFinalize` and `uploadAbort` RPCs. The personal implementation already has a stronger phone-to-Hub recovery guarantee: disk staging, SHA-256, namespace/session isolation, offset confirmation, expiry, restart recovery and a persisted completion receipt. Its gap was that final handoff still read the whole file and sent one base64 RPC.

The integration adopts the Runner RPCs and file identity registration, then bridges the personal staging file to them. It does not adopt the separate upstream public HTTP upload protocol or Web adapter. Completion now hashes the file as a stream and passes its path to a bounded, ordered Runner transfer. Every chunk acknowledgement must confirm the cumulative byte count. File length changes, invalid negotiated chunk sizes and failed/ambiguous acknowledgements abort that transfer without deleting the durable Hub staging file. A successful Runner result is persisted using the existing completion receipt before Hub bytes are removed.

The personal 50 MiB limit is retained. Upstream's 512 MiB default and up-to-10-GiB override are not adopted; `resolveMaxUploadBytes` is capped at 50 MiB, while smaller explicit limits remain possible. No Web/iOS large-file UI behavior or inline attachment limits are changed.

Already-running CLIs may lack the new RPCs. The gateway uses the old single-RPC handoff only when the RPC registry definitively has no `uploadInit` handler before dispatch. If an advertised init, chunk or finalize times out or fails, the gateway never retries through the legacy path. An unconfirmed init may leave a Runner partial upload until its existing TTL cleanup. An unconfirmed finalize may have produced an unreferenced final file, as was already possible across the personal Hub completion receipt crash boundary; retry does not send a chat message or invoke an Agent.

## Compared and retained

### Query templates: #1787 / `80a5b94f`

This is substantially the same community infrastructure already incorporated before upstream merge. Comparing the actual service/credentials/execution code shows that replacing it would remove the personal `codex-native` and `agy-cli` adapters, enabled defaults, grouped agy quotas, plan type, OAuth account fingerprints and four-agent settings migration. It would also restore heuristic placement of unidentified Zhipu windows into 5h/7d slots, reversing the personal strict-window fix. These are regressions, so the personal implementation stays.

### Native account quotas: #2389 / `31cb262e`

This is a distinct subsystem, not a newer revision of template queries. Its concrete advantages are a generic list of quota buckets (including variable windows and Codex limit groups), account/plan/credits/authentication status, observed Claude quota events bound to the producing account, process-persisted observations, bounded provider probes and a new Web Settings/Usage projection.

It requires a complete CLI→Runner RPC→Hub usage API→Web contract across 32 files. Copying the Web page alone would create requests our Hub does not serve, and blindly replacing personal query results would lose the iOS group/window contract. A future integration should share provider probes and account isolation beneath both projections, then adapt the native account model deliberately into Web and iOS. It must not create two independent periodic provider probes or show one account's cached data after another signs in.

The personal recent-Codex-log fallback has a related limitation: old JSONL rate-limit rows are not themselves proven to belong to the currently selected OAuth account. Its outer cache fingerprint prevents reuse of a cache entry across accounts but cannot establish the provenance of arbitrary recent log rows. The upstream direct account-aware API path is a better reference for eventually replacing that fallback; the reviewed provider API and historical fallback behavior are not changed in this batch.

### agy launch and wakeup: #2319 / `d784f1f7`, #2387 / `0bea8967`

Upstream and the personal fork have different live drivers (`agyAcpRemoteLauncher.ts` versus personal `acp/agyAcpDriver.ts`). Adding an upstream-only helper does not improve the executing personal path. Personal behavior to retain includes the strict pre-prompt resume/SkipHistory gate, mid-flight continuation ownership, normalized multi-generation transcripts, terminal tool reconciliation, pending-task settlement, immediate acknowledgement, and no automatic replay of ambiguous Steer sends.

In particular, upstream `0bea8967` caches parsed log tails using `(ino,size,mtimeMs)` plus an initial head check. The personal tracker uses nanosecond timestamps/ctime, generation normalization and fork signatures to detect rewrites that keep the head unchanged. Wholesale replacement would drop those stronger protections. The personal idle supplement also distinguishes foreground thinking from background work instead of keeping the foreground active solely to drain transcript continuations.

### agy canonical cards and questions: #2330, #2331, #2309

Upstream carries the native tool name/args into a canonical card mapper and preserves empty edit/write strings; these are useful semantics. The personal transcript formatter currently retains the original argument object, so its empty `Target`, `Replacement` and `Content` strings are not filtered out. However its generic `File …` / `Run …` cards do not automatically gain upstream canonical card selection. Proper adoption needs native identity on both live ACP and transcript-recovered calls, consistent call IDs, and generated client fixtures—not a mapper attached only to the unused upstream driver.

The upstream form path also has better explicit free-text flags, a lifecycle gate for forms delivered after Stop, and rejection of approvals without usable answers. The lifecycle gate is now adapted into the executing personal adapter: cancellation closes admission synchronously even with no pending forms, and a new foreground prompt explicitly reopens it. Two regressions check late-form cancellation, existing promise settlement, and the next prompt accepting a question normally. The personal adapter has a working question bridge but does not project `allowFreeText` end to end; directly porting only the reducer free-text enrichment would leave both Web/iOS parsing incomplete. These are specific follow-up improvements rather than claims of feature parity.

### Background round metadata: #2405 / `e24ccf5e`

Upstream adds round counts and running command snapshots. The personal driver already emits `background_tasks_changed` snapshots through the shared Hub/client contract; replacing it would duplicate task indicators. Round-count enrichment can be considered separately after reconciling the source of truth for foreground rounds and reactive continuations. It is not included in this batch.

## Verification

- Factory delta/Steer tests: 3 passed.
- Runner upload handlers plus factory tests: 17 passed, including sequential bytes, per-session isolation, size/index validation, expiry, cleanup and finalization.
- Hub upload storage, HTTP authorization/restart/completion, streaming, fallback and RPC suites: 30 passed. Coverage includes lost finalize acknowledgement, no fallback after an advertised init timeout, rejected chunk byte acknowledgements and 50 MiB policy preservation.
- CLI, Hub, Web and relay TypeScript checks passed after the upload adaptation.
- The larger agy and quota suites passed: 202 tests across 14 files. After the form lifecycle adaptation, adapter/driver regressions passed: 29 tests across 2 files; CLI typecheck was repeated.
- No database migration, production configuration read, binary replacement, service restart, push or deployment is part of these changes.


## Follow-up: form semantics across the executing personal path

The previous review's free-text/empty-answer gap is now addressed in the personal `acp/agyElicitationAdapter.ts`, not by attaching another upstream driver. A form explicitly advertises whether each question has a string-valued `qN_other` answer channel. Unsupported modes and forms with an unanswerable question decline before queueing. Single/multiple choice `oneOf` and `anyOf` aliases map displayed labels back to native values. A blank or unknown fixed-choice approval resolves `decline`, records a denied decision, and never stores a successful empty answer.

Web, iOS and Mac Catalyst now parse `allowFreeText`, hide forbidden custom-answer controls, and filter forbidden text from retained drafts at serialization. Missing flags keep the legacy permissive behavior for Claude/Cursor/older messages; Codex `request_user_input` notes and stable IDs are unchanged. A tool call can precede its form: the reducers enrich only missing per-question flags from the pending/completed permission input, preserving explicit input flags. Three Web-generated fixtures cover fixed-choice pending/completed calls and text-only synthesized cards. The Android protocol reducer has the same projection for fixture conformance; Android app UI is not changed in this batch.

The existing Stop admission gate and explicit reopening on the next foreground prompt stay in place. Request map keys remain unchanged; when the native form supplies a toolCallId, the request and completed record now retain that correlation metadata.

Verification for this follow-up: 34 adapter/driver tests, 646 Web question/tool-card/reducer/fixture tests, all 82 Swift chat golden cases plus parser/fixture decoding checks, 411 Android protocol tests, and 17 isolated iOS Simulator draft/card tests passed. The simulator suite includes an actual editable-field check for fixed-choice versus text-only forms, and existing recycling/anchor/theme tests. Tests used private HAPI_HOME/TMPDIR and sanitized environments. No device, production account, deployment, push or service restart was used.


### Follow-up review correction: partial multi-question answers

The form adapter now validates every emitted question after mapping labels and allowed text into native fields. A usable first answer cannot conceal an unknown, missing or blank second answer: the whole submission declines and is recorded as denied without answer metadata. Fully answered mixed fixed-choice/text-only forms still accept. This matches the clients' existing all-questions-answered contract rather than accepting a nonempty partial content object. The new regression reproduced the previous partial-accept behavior before the correction. Afterward, all 36 adapter/driver tests and the CLI typecheck passed.
