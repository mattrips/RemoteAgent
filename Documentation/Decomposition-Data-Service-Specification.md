# Central Decomposition Data Service — Implementation Specification

Status: Design specification. This document does not authorize implementation.

Prepared: October 26, 2026.

## 1. Purpose and decisions

Keep one authoritative Decomposition folder on the Mac Studio. Decomposer on that Mac and on remote Macs shall read and update its records through an authenticated project data service. Remote clients shall not maintain independently writable copies of the project databases or use Git pull/push to coordinate edits.

The model remains in RemoteAgent's inference worker. Project storage is a separate service with separate resource limits, credentials, lifecycle, and failure handling. Restarting or unloading the inference worker must not interrupt project reads, persistence, or recovery.

Initial authoritative root:

`/Users/mattrips/Documents/Decomposition`

The local administrator may change this path. Clients identify the project by a persistent project ID, not by supplying an arbitrary server filesystem root.

GitHub remains version history and an off-machine copy of Git-tracked project records. It is not a database replication mechanism or a complete backup of investigations and ignored files.

This specification supersedes the earlier suggestion of synchronizing two writable project repositories. It does not change the linguistic procedure, model settings, output schemas, or user approval requirements.

## 2. Architecture and process boundaries

```text
Decomposer — Mac Studio or MacBook
  UI, procedure orchestration, prompt assembly, approvals,
  browser-based COCA/OED retrieval, transient local recovery journal
       |
       +-- Model endpoint ----------------> RemoteAgent inference service
       |                                      -> isolated MLX worker
       |                                      -> weights and GPU caches
       |
       +-- Project endpoint --------------> Decomposition data service
                                              -> documents and corpus archives
                                              -> three append-only databases
                                              -> investigation checkpoints
                                              -> write/recovery journal
                                              -> Git backup coordinator
```

Implement the storage server as a separate executable/process that does not import or load MLX weights. RemoteAgent may initially provide its settings and dashboard, but starting/stopping the model must not start/stop storage. The launcher must clearly distinguish stopping inference, stopping storage, and quitting all services. A later LaunchAgent may keep storage available without the dashboard; do not imply this already exists.

Initial network arrangement:

| Service | Mac Studio listener | Local client URL | Remote client URL |
| --- | --- | --- | --- |
| Model inference | Existing loopback port 8321 | `http://127.0.0.1:8321` | Existing private Tailscale Serve HTTPS endpoint |
| Project data | Proposed loopback port 8322 | `http://127.0.0.1:8322` | Separate private Tailscale Serve HTTPS endpoint, proposed HTTPS port 8443 |

The separate HTTPS port avoids changing the working model route. Final port availability and Tailscale routing must be verified during implementation. No LAN-wide plaintext listener or public Funnel is required. All remote traffic uses certificate-verified HTTPS.

Decomposer settings shall distinguish Model Server from Project Server. A successful connection to one does not imply the other is ready.

## 3. Ownership and scope

### 3.1 Central project records

The service shall own access to:

- `VerbFunctions.sqlite`, `Glossary.sqlite`, and `Principles.sqlite`.
- Background Prompt documents and their established ordering.
- The selected current procedure document and the parsed procedure snapshot.
- Analysis documents, domain documents and the domains table.
- COCA archives in `ConcordanceExamples` and OED evidence in `Etymology`.
- Investigation records, complete inference trials, curated messages, human decisions, approvals, and documentation staging/recovery state.
- Other project documents through the existing bounded list, read, and literal-search tools.

Honor current file formats, path conventions, deprecated-document rules, and database semantics. Do not introduce bundled copies of project content as a fallback source of truth. The current text-only COCA archive requirement remains in force; this work is not an archive migration.

### 3.2 Client responsibilities

Decomposer continues to own procedure execution, model calls, chat, prompt assembly, evidence selection, semantic validation, and the UI for approvals. It receives project records through a repository interface rather than constructing remote paths.

Local caches are disposable read caches and immutable investigation snapshots. A local pending-save journal is a recovery copy, not an alternate project repository. The client must state when something is saved only locally.

COCA/OED sign-in and browser interaction remain on the Mac running Decomposer. Credentials stay in that Mac's Keychain. The client uploads the resulting validated evidence archive to central storage before a step relies on it. The data server does not receive the paid-account passwords or automate those websites in the first release.

### 3.3 Local access on the Mac Studio

The Mac Studio's Decomposer shall use the same data API over loopback. Once centralized mode is enabled, its database views, tools, procedure loader, documentation writer, and investigation store must not bypass the service.

Direct Finder/editor changes remain possible for the owner, but are out-of-band changes. Detect them through content/version checks, invalidate affected caches, and stop stale writes. Direct concurrent modification of SQLite files is unsupported; provide a maintenance state for such work.

## 4. Project identity, revisions, and consistent reads

Each project has a persistent UUID. Each service start has a separate instance/epoch ID. Restarting the server must not change project identity or erase durable operation receipts.

Every read response shall identify the project, API version, and resource version. Use:

- Database version IDs for individual append-only records.
- SHA-256 content hashes for files.
- Monotonically increasing revisions for investigation saves.
- A project change sequence for discovery, status, and cache invalidation.

The project change sequence is not a reason to reject unrelated edits. Validate a write against its actual read set: the records, definitions, and files on which it depends.

At investigation creation, the service supplies a coherent snapshot containing the selected procedure, ordered background documents, and applicable database/document versions. Preserve complete contents or immutable retrievable versions sufficient to reconstruct the exact prompts. A mutable path or hash without retained content is insufficient.

A snapshot shall not mix content from opposite sides of a documentation transaction. Readers may use an immutable earlier snapshot while a transaction is staged; new current-state reads must wait or receive a retryable status during the short publication barrier.

Do not hold a global write lock throughout model generation or a user discussion. Pin analytical inputs and check their versions again when writes are proposed. A background edit does not silently rewrite an ongoing investigation or chat.

## 5. API contract

Use a versioned authenticated JSON API. The initial transport may use one `POST /v1/project/rpc` endpoint with explicit operation names; file bodies and attachments may use separate bounded endpoints if needed. Do not reuse the inference request decoder or expose storage inside model cache sessions.

Common request fields:

```json
{
  "apiVersion": 1,
  "requestID": "UUID for this delivery attempt",
  "projectID": "persistent project UUID",
  "operation": "files.read",
  "arguments": {"path": "Analyses/GO.md"}
}
```

Write requests additionally carry an operation/idempotency ID, expected versions, client identity, and approval reference when applicable. Retries of the same write retain the operation ID and exact payload fingerprint, even if the delivery request ID changes.

### 5.1 Read operations

| Family | Required operations |
| --- | --- |
| Service | Health, capabilities, project identity, server version, storage/recovery status |
| Changes | Changes since sequence, bounded long polling, resource invalidation notices |
| Files | List, read, literal text search; return exact content and hashes |
| Snapshots | Create/read immutable ordered background and procedure snapshots |
| Verbs | Search/latest by lexeme and overload, history, exact-version read, decomposition dependency query |
| Glossary | Search, lookup, dependencies, latest and historical versions |
| Principles | Lookup by principle number, search, latest and historical versions |
| Domains | Read domains table, resolve domain records and authorized documents |
| Evidence | Discover/read saved COCA and OED data by normalized verb and archive identity |
| Investigations | List metadata, open latest revision, read checkpoints, trials, chats, and approved versions |
| Operations | Inspect pending or completed write receipt by operation ID |

Retain existing tool names such as ListFiles, ReadFile, SearchText, InspectDatabase, and database-specific lookup tools at the model interface. Their host implementations call these typed operations. Do not turn InspectDatabase into arbitrary remote SQL execution.

Paginated queries must return a stable cursor tied to a result snapshot plus an explicit completion indicator. A request for ALL matching verbs must exhaust those pages. Do not silently return the first page. Preserve the specialized query that finds direct and indirect incorporated functions inside `R(...)`.

Default page size: 100 records; maximum: 1,000. Use bounded search results and continuations rather than truncating content without notice.

### 5.2 Write operations

- Append a verb, glossary, or principle revision with an expected current version.
- Upload a validated corpus/OED archive using its content hash and logical identity.
- Create/save investigation checkpoints and append trial/chat/recovery records.
- Prepare, inspect, approve, apply, and recover a documentation transaction.
- Apply confirmed Chat project-tool writes through the same transaction machinery.
- Request Git synchronization/status through a fixed host operation, never a model-supplied shell command.

Use explicit create-versus-replace semantics. A missing expected target, changed target, unsupported schema, or ambiguous overload is an error, not permission to choose another target.

### 5.3 Limits and errors

Proposed starting limits: 4 MiB ordinary JSON requests, 16 MiB individual document/evidence transfers, and chunked immutable uploads for larger investigation archives. Advertise limits through capabilities and measure real saved investigations before finalizing them. Reject oversized input explicitly; never discard evidence or truncate an inference trial to fit a transport bound.

Error responses shall contain a stable code, readable explanation, affected resource, expected/actual version where relevant, retryability, operation ID, and recovery action. Never include credentials or private source text unnecessarily.

Distinguish unauthorized, unavailable, missing file, ambiguous record, conflict, invalid payload, disk full, pending recovery, locally saved only, centrally saved, and Git push pending. A timeout does not prove a write failed.

## 6. Database semantics

The three databases retain their append-only history. Normal edits, deprecation, and restoration create new versions; no history row is overwritten or deleted.

The server assigns UTC timestamps and version IDs. Determine the newest record through the database's authoritative version ordering, with a deterministic tie-breaker; do not depend on client clock agreement.

Preserve verb identity as the normalized lexeme plus `overloadName`. The usual overload value remains `not applicable`. Searches may return several overloads; clients must present the choice instead of selecting one silently. Preserve lowercase lexeme conventions and existing semantic validators.

Serialize writes and use optimistic concurrency checks against the expected current version. Run schema migrations under exclusive maintenance control, with a recoverable backup; never migrate an active database separately on each client.

For exactly-once append behavior after a crash, record the operation ID and transaction sub-operation ID in the same SQLite transaction as the new version. A receipt in a separate service database alone cannot prevent a duplicate append if the process dies between the two commits. Implement any necessary small internal schema addition without altering linguistic records.

## 7. Approved changes and multi-resource transactions

### 7.1 Preparation and approval

The server prepares a concrete, reviewable change set containing exact file bodies, database append payloads, expected versions, dependencies, and hashes. It returns an immutable change-set ID and digest.

Decomposer renders that assembled version for the user. Approval attaches to that exact digest and relevant versions. A changed formula, definition, plan item, or operation invalidates the old approval. Model-authored claims of approval are not accepted.

Regular Chat retains its project-tools toggle and native confirmation dialog before project writes. Procedure approval remains at the existing designated checkpoints. Routine host persistence of an investigation or corpus retrieval does not require a new per-save approval dialog.

The trusted client submits approval as a distinct host action; model tool arguments cannot create approval receipts. Device identity and token scopes are audit and access-control mechanisms, not protection against a deliberately compromised trusted client. Do not promise stronger human-identity guarantees than the implementation supplies.

### 7.2 Applying changes

Reuse the established Step 17 staging, validation, and recovery concepts. Move physical application to the server while leaving analytical planning and discussion in Decomposer.

Transaction lifecycle:

`prepared → awaitingApproval → approved → applying → applied`

Exceptional states include `conflict`, `rejected`, `recoveryRequired`, and `abortedBeforeApplication`. Git state is recorded separately.

Before application, revalidate the approval digest, read set, target paths, payloads, and database versions. Acquire short publication/write locks in a fixed order. Stage file contents on the same volume, persist the journal, and use atomic replacement for individual files. Flush critical journal transitions before acknowledging durable progress.

There is no single native atomic transaction spanning three independent SQLite databases and arbitrary files. Do not claim otherwise. Use a durable recovery journal and idempotent sub-operations, gate readers while publication is incomplete, and prefer deterministic roll-forward of an already approved transaction. After a crash, inspect committed operation IDs and file hashes before continuing.

Never erase append-only revisions to simulate rollback. A compensating revision requires an explicit recorded recovery policy or user-reviewed decision. If roll-forward cannot complete safely, keep affected current-state reads/writes blocked and expose a precise repair status rather than publishing a partly applied project as complete.

Return a durable receipt listing each applied resource, its new version/hash, and any remaining action. The client must show success from the receipt, not from the model saying it made changes.

### 7.3 Idempotency and interrupted connections

Persist operation ID, canonical payload digest, approval digest, state transitions, and result receipt. Repeating the same operation ID and payload returns its pending state or original result. Reusing the ID for different content is rejected.

If the connection drops after submission, query operation status before offering any retry. Closing a client connection must not cancel a write halfway through publication. An operation that has begun applying finishes or enters explicit recovery under server control.

## 8. Investigation ownership and saving

Store authoritative investigations centrally, including records currently excluded from Git. Refactor the investigation store abstraction so ProcedureEngine does not assume a local writable URL.

Each running investigation has one owner lease with a monotonically increasing fencing token. Proposed lease duration: 90 seconds; renew every 20 seconds. Other clients may read its committed checkpoints but cannot advance the same investigation concurrently. Expiry permits recovery by another client, not acceptance of late writes from the old owner. Check the fencing token on every save.

Save major state transitions before continuing: accepted results, user decisions, exact prompt snapshots, complete trial outputs, approvals, and write receipts. Batch transient token/progress updates; do not send a database or full investigation file for every generated token. Use bounded append records and revision-checked checkpoints, with compaction that preserves the archive.

If central saving fails, preserve the exact output and pending operation locally, pause before the next dependent step or project write, and show `Saved locally — central save pending`. Do not silently continue an entire procedure against disconnected project state.

On reconnection, reconcile pending saves by operation ID and expected investigation revision. Resume only after confirming the server state and lease ownership. If another client advanced the investigation, retain the local work as a recoverable branch/draft; never overwrite the newer checkpoint.

The first release does not promise that closing the MacBook transfers an active model stream or procedure execution to the Mac Studio. Server-side procedure execution and inference-response reattachment are separate features. Central checkpoint storage makes recovery possible but does not implement those features by itself.

## 9. Local caching and prompt reproducibility

Cache file contents by hash and records by immutable version ID. Keep a bounded disk cache with explicit project identity; cached documents must not be confused with editable working files.

Poll for invalidations approximately every 30 seconds while idle, or use a bounded change feed. At investigation creation and before a write, check current versions explicitly; polling is not a concurrency guarantee.

Prompt assembly remains in Decomposer. Preserve actual message roles, curated history, background ordering including Notation before VerbFunction examples, selected principle captions, compact glossary definitions, scoped evidence, inference settings, and all existing context-budget behavior. Archive the exact supplied messages and settings.

Project snapshot identities and RA cache handles are separate. RA caches remain temporary, model-dependent, server-held state. A storage restart should not automatically discard a valid model cache; changed prompt tokens must still invalidate reuse through exact-prefix matching. A model restart must not lose investigation records.

Ordinary Chat may continue from its already pinned snapshot during a project-service interruption, but project tools must clearly fail or wait. Do not silently substitute stale current-record reads or claim offline project writes succeeded.

## 10. Security and path confinement

- Generate a separate project-service credential and store client credentials in Keychain. Do not reuse OED/COCA passwords or embed tokens in URLs, project files, prompts, or Git.
- Prefer per-device credentials with read/write scopes and local revocation. Administrative root changes and credential issuance remain local settings actions.
- Verify TLS certificates and hostnames. Native Decomposer uses platform trust; the Python probe's certificate-bundle setup is not a reason to weaken app TLS verification.
- Accept only authenticated project-relative paths. Reject traversal, absolute paths, symlink escapes, aliases resolving outside the root, and unauthorized internal state directories.
- Prevent access to `.git` internals, Keychain exports, service secrets, and arbitrary host files through model tools. Recheck resolved targets at mutation time to address path races.
- Retain the existing tool allowlists and write confirmations. No shell, arbitrary SQL, model-controlled Git commands, or unbounded recursive file download.
- Bound concurrent connections, request bytes, upload sizes, search work, retained snapshots, and journals. Write application is serialized; reads may run concurrently against stable snapshots.

Project endpoint availability is subject to Tailscale access rules as well as application authentication. Do not change the user's tailnet policy or enable public exposure as part of this work.

## 11. Git history and backups

Only the server manages Git for the authoritative folder during normal operation. Clients do not automatically pull or push a second copy. Separate the facts `centrally saved`, `Git committed`, and `Git pushed` in receipts and UI.

Proposed policy:

1. Commit successful approved documentation transactions with their transaction IDs.
2. Batch independently saved corpus/OED additions after retrieval completes, or on a short debounce when no publication is in progress.
3. Push after those commits, with bounded retry/backoff when GitHub is unavailable.
4. Offer Commit/Push now and show the last successful push and pending changes.

Do not fail an already durable project update merely because pushing is offline. Preserve the commit and report `Saved centrally — push pending`. Never force-push, automatically discard local changes, or merge competing SQLite files.

Database files committed to Git must be consistent standalone SQLite snapshots. Coordinate writes, checkpoints/backup APIs, and file staging so Git never captures a main file missing WAL-only transactions. Do not commit live WAL/SHM files as a substitute for a consistent database snapshot. Define and test the exact snapshot procedure before enabling automatic commits.

Avoid holding a database transaction or publication lock during a GitHub network request. Capture the exact paths/content versions for a commit, and prevent unrelated half-finished changes entering it. Ignore build output, temporary staging files, credentials, caches, and service journals.

Fetch may detect unexpected upstream changes, but normal operation has one authoritative writer repository. An upstream divergence or manual repository change requires attention; do not auto-pull into active databases. Apply approved upstream maintenance only while clients and databases are quiescent.

Provide a separate recoverable backup of the full authoritative folder and required service state, including investigations excluded from Git. Existing Time Machine or another verified backup may satisfy this requirement; Git push alone does not. Test restoring the three databases, investigations, and recovery journal together.

## 12. Availability, recovery, and UI

The service shall start without loading a model. Advertise unavailable/recovering/ready/maintenance states and reject dependent writes while recovery is incomplete. Check disk space before accepting large uploads or applying documentation; never acknowledge a save before durable completion.

Detect sleep, restart, port conflicts, permission loss, unavailable project volume, disk-full conditions, corrupt journals, database failures, and interrupted transfers. Use bounded retries only for safe/idempotent operations. Do not loop blindly on conflicts or malformed approvals.

Decomposer shall show a small project status with enough information to distinguish:

- Connected to the named central project.
- Offline or authentication required.
- Saving or pending local recovery.
- Conflict or server recovery required.
- Centrally saved, with Git push pending when applicable.

Display the server/project identity to prevent accidentally writing to the wrong repository. Model readiness remains a separate status. Preserve clear native error dialogs and copyable diagnostics without exposing access tokens.

The host dashboard shall show storage readiness, project root, connected clients, active investigation leases, pending/recovering transactions, disk headroom, and Git/backup status. Prefer concise actionable information over repetitive activity messages.

## 13. Implementation sequence

1. Inventory every direct project filesystem/database access in Decomposer, including settings views, startup loaders, tool backends, Step 17, browser archive writers, and investigation save/reopen/export paths.
2. Introduce a platform-neutral ProjectRepository interface with a local implementation. Preserve behavior and test it before adding networking.
3. Implement the independent service, authentication, capabilities, typed read endpoints, consistent snapshots, and change tracking.
4. Implement append-only database writes, version checks, durable idempotency, staged document transactions, approval receipts, and fault-injected recovery.
5. Add investigation leases/checkpoints and durable evidence uploads. Refactor physical Step 17 application to use the service.
6. Add the remote client implementation, Keychain setup, separate project/model settings, local read cache, and pending-save recovery.
7. Move Mac Studio Decomposer through loopback first; audit that no project tools or views bypass the service. Then connect the MacBook through Tailscale.
8. Enable coordinated Git commits/pushes and full-folder backup verification after storage recovery is reliable.
9. Retire normal writable local-project mode for this deployment, retaining explicit maintenance/export paths. Do not delete existing folders or histories during migration.

Before switching over, stop investigations on both Macs, reconcile any genuine MacBook-only changes, back up the authoritative folder, and record the initial project ID/revision. Do not merge binary databases automatically or assume the newest file timestamp identifies the correct content.

## 14. Acceptance tests

The release is not ready based on compilation or a single successful remote read. Verify:

1. Mac Studio and MacBook read the same project identity, latest database versions, files, domains, and evidence through their respective endpoints.
2. All three DB views, prompt loaders, and model project tools work with no writable Decomposition folder on the MacBook.
3. Changing a background document invalidates future snapshot reads while an existing investigation retains reconstructable original prompts.
4. Competing updates to the same database version or file hash produce a conflict; unrelated valid writes can succeed serially.
5. Duplicate requests, timeouts after application, and reconnects never duplicate database revisions or apply an operation twice.
6. Fault injection after every file/database/journal boundary yields a completed approved transaction or explicit gated recovery, never silent partial publication.
7. Step 17 applies precisely the approved assembled change set, and Chat writes still require the local confirmation dialog.
8. A second client cannot advance a leased investigation; an expired owner's fenced writes are rejected after takeover.
9. Disconnecting the MacBook during generation preserves received work and prevents dependent progression until required central saves reconcile.
10. COCA/OED data retrieved on either Mac is centrally saved once and reused by later investigations without another website retrieval when the archive is suitable.
11. Reloading or crashing the inference worker does not interrupt data reads or lose saves; restarting storage preserves operation receipts and investigation state.
12. Disk full, unavailable volume, incorrect token, certificate failure, malformed requests, path escapes, and oversized uploads fail safely with actionable messages.
13. Every paginated ALL query retrieves its complete stable result set, including distinct verb overloads and historical versions when requested.
14. Git push failure leaves central updates intact and visibly pending. A later push succeeds without rewriting history.
15. A Git-committed database snapshot opens independently with all intended revisions; a full backup restore also recovers ignored investigations and pending-operation state.
16. Real Decomposer operation succeeds through Tailscale from the second Mac, including a complete investigation and an approved multi-resource documentation update.

## 15. Deferred work and limits

The first release does not include public hosting, organization-wide multi-user permissions, offline project editing with automatic merge, arbitrary shared folders, or automatic reconciliation of independent SQLite copies.

It also does not move procedure execution onto the server, guarantee completion while the MacBook sleeps, or add model-response replay/reattachment. Those features require separate lifecycle work.

The earlier iPhone chat specification's read-only background publication should eventually consume this service's immutable snapshot API. That future reuse does not add project-writing tools to the phone's initial scope.

Thresholds, ports, and polling/lease intervals identified as proposed defaults must be confirmed with real data and interruption tests. The acceptance criteria, single authoritative source, append-only history, exact-version approval, and explicit recovery behavior are requirements rather than optional tuning.
