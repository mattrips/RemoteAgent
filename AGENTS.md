# RemoteAgent agent guide

Updated 2026-10-28. Inspect current code before relying on numeric defaults or
older milestone documentation. Keep this guide current when behavior changes.
User instructions take precedence.

## Boundaries and architecture

RemoteAgent (RA) serves loaded MLX models to Decomposer and Ray. It owns GPU work,
session capabilities, immutable prompt caches, admission, cancellation and status.
It does not run project tools, approve project edits or own the clients' permanent
conversation libraries. Data is the separate project storage server.

- `Sources/RemoteAgentApp`: SwiftUI dashboard, settings, loading and memory UI.
- `Sources/RemoteAgentService`: authenticated HTTP, request coordination/queue,
  worker bridge, bounded recovery journal, background publication and self-checks.
- `Sources/RemoteAgentWorker/main.swift`: isolated worker entry point. Much of the
  worker lives in sibling Decomposer's `Packages/HarnessMLX`; wire types and
  resource/session policies live in its `Packages/HarnessCore`.
- Sibling `ServiceKit` supplies common service supervision/connection components.
  Check downstream callers when modifying these shared packages.
- `Documentation/Service-API-Update.md` describes capabilities, background.get,
  request status/replay and idempotent generation. Older README/follow-up notes can
  predate those implementations; distinguish server support from client adoption.

## Protocol and correctness

- Loopback: `http://127.0.0.1:8321`, authenticated POST `/v1/rpc`, NDJSON events.
  Remote access uses certificate-verified private Tailscale Serve HTTPS, normally
  port 443. Data uses its own token and separate route on 8443. Do not reset or
  overwrite another Serve route, enable public Funnel or disable certificate checks.
- Credentials belong in Keychain/in-memory transport, not URLs, source, prompts,
  status output or reports. Server-side GPU arrays never leave the worker.
- Request IDs, session ownership and worker epochs matter. A cache handle is not
  transferable between sessions/epochs. An explicit mismatched prefix is an error;
  implicit reuse chooses an exactly matching prefix, never a semantic approximation.
- Preserve attention KV, convolution/recurrent state and next-token logits together.
  Qwen3.5 recurrent caches cannot be trimmed backward like attention-only caches;
  reconstruct earlier boundaries by replay. Forks must not mutate their baseline.
- Keep native TokenIterator pipelining. Synchronous evaluation of every token
  previously caused a substantial decoding slowdown. Drain pending GPU work before
  committing caches, declaring cancellation complete or returning failure.
- Preserve all text and event order across worker IPC and HTTP. A terminal outcome
  plus usage is required for completion. Heartbeats prove liveness, not progress.
  Slow-consumer handling must not silently discard output. Cancellation requested
  is different from cancellation confirmed; completion can win the race.
- All GPU gate owners call WorkerBridge.cancelAndDrain before releasing their
  slot, including normal stream exits (AsyncThrowingStream cancellation can end
  iteration without throwing). Drain waits independently of caller cancellation
  for a worker terminal event or isolation-watchdog cleanup. Never hand the slot
  to another request merely because cancellation was sent or HTTP disconnected.
  Cover generation, prefill/pinned-baseline preparation, metadata refresh and
  manual session closure; queued cancellation must not cancel another request.
- Recovery/idempotency is capability-specific. Never blindly regenerate after a
  lost connection; inspect the original request/receipt where supported. Temporary
  output recovery journals are not a permanent conversation store and can include
  generated thinking text; treat them as private.

Every generation uses a CPU-only bounded exact-token repetition detector: patterns
1–512 tokens, at least 12 consecutive repeats AND 128 repeated output tokens.
Only newly generated tokens are fed, including hidden thinking. A fixed 6,144-token
ring and early mismatch exits preserve native GPU pipelining. On detection, drain
GPU work, emit usage, then terminal error repetition_detected with pattern length,
repeat count and zero-based generated span start; never publish the working cache.
Existing immutable caches survive (normal pre-inference admission still applies).
The dashboard/log show Repetition detected, retain counts but no output/token IDs,
and release the slot normally. RA never silently retries. Decomposer/Ray may make
one new request using original messages plus their generic nudge; this exception
requires the explicit terminal repetition error, not network loss or cancellation.

## Resource management

Verify defaults in shared policies and the worker rather than copying them into
new clients. Current design: one GPU job, four queued waiters, sixteen sessions;
no idle expiry below ten sessions, eligible idle expiry above that threshold,
oldest eligible idle replacement at the cap, and explicit manual closure. Protect
active/queued work. A new app instance on the same device supersedes the old
instance's sessions; independent workflows in the same instance remain separate.

Retained caches are size-governed, with a separate metadata cap. The ceiling is
min(32 GiB, physical RAM/8), giving the 256 GiB Mac Studio 32 GiB. This is a ceiling,
not preallocation or guaranteed residency; earlier headroom reclamation still
applies. Admission reserves
an independent working cache for prompt plus reply and GPU workspace. The current
OS reserve is 4 GiB; GPU workspace is a separate 4 GiB allowance. A failed initial
check waits two seconds and retries once before eligible snapshot reclamation;
remaining shortfalls still reject. Free/reclaimable memory is an estimate, not a
guarantee of Metal allocation success. Shared snapshot storage means summing
reported sizes is not equivalent to physical memory reclaimed.

Keep worker crash isolation/watchdogs and visible failure. Worker death expires
handles and fails affected jobs while keeping the dashboard alive. Do not add
unbounded restart/retry loops or silently commit partial output. Loading bars for
397B are empirical system-memory estimates (+217 GB loading; 217 GB wired), not
an exact tensor-loading percentage. Model choice belongs to the host operator;
sampling/context settings are supplied by clients within server limits.

## Dashboard and activity log

The dashboard has Status, Log and Settings tabs. Keep model/service status,
loading bars, memory, inference metrics and manual session eviction on Status;
connection/model settings, Tailscale and diagnostics belong in Settings. Switching
tabs must not restart the worker or inference.
The Inference stage value is green when Idle; the generated-token value is green
only while Decoding. Other states and completed counts use the primary text color.
The dashboard uses an explicit white background and light color scheme, matching
Data, rather than the default gray window background.

`RemoteAgentService/ActivityLog.swift` owns a bounded, memory-only metadata log
(latest 1,000 entries). WorkerBridge records request queue/start/completion,
cancellation, usage, errors and model/worker lifecycle; session snapshots record
logical client connections added/dropped. HTTP interruption is separate from
inference cancellation because recovery can continue after transport loss.
Normal short-lived HTTP connections and routine status polling must not flood it.
The host polls once per second; never add a Task or UI update for every token.

Log entries expose client/device labels, request/session IDs, operation, outcome,
time and token counts. Never retain prompt text, output, raw token IDs, credentials,
headers or raw error messages in this log. Errors use bounded codes; full diagnostics
remain with the caller. Clear completed entries preserves active request rows.
Test bounded retention, lifecycle/duplicate terminal handling and HTTP/fake-worker
behavior without loading weights. Sandbox-denied loopback binding is not a passing
HTTP test: request network permission and rerun.

## Build and deployment

Keep RA beside Decomposer and ServiceKit for relative package dependencies. Use
`RemoteAgent.xcodeproj`, scheme **RemoteAgent** (Release), to include its embedded
worker and Metal resources. `swift test` from this root runs fake-worker/process/
HTTP tests without loading weights. Shared worker changes also require relevant
HarnessCore/HarnessMLX tests. Never change cache-equivalence tolerances simply to
turn a failure into a pass; distinguish strict cold-batch from matched replay checks.

The launched app is `Build/RemoteAgent.app`. Confirm the actual executable path;
older scratch copies have previously been mistaken for new installations. Verify
the dashboard AND embedded worker, their resources, versions and signatures.
Resigning changes raw binary hashes: compare executable content appropriately
before concluding that a hash mismatch means stale code.

Build/stage first; coordinate quitting RA before installation, which ends its
sessions/caches. Do not stop a live inference service for unrelated app work.
RA autoloads the remembered model; use `--no-autoload` for maintenance. Avoid
loading a second 397B instance alongside another model process. A compiled build
or fake-worker pass does not establish real-model memory or offsite reliability.
Use **Run local checks…** between jobs for deployed-model verification and retain
the report without exposing its token. Do not commit/push unless requested.

## Server-owned pinned baseline

baseline.status is authenticated service-mirrored metadata, bypassing GPU/queue and
creating no session. baseline.ensure accepts exactly one complete system message,
no raw tokens/handle, and only starts when JobGate.tryAcquire succeeds; otherwise
returns deferred. One current immutable baseline lives outside all session-owned
snapshots. Exact system bytes/template policy identify it; the loaded worker epoch
binds weights, tokenizer and template. Derive a safe extendable token prefix using
two disjoint user probes; never prefill the probe bodies. Automatic matching may
use the pin only on an exact token prefix, always copying full cache/recurrent
state and logits. Session closure/expiry/supersession, explicit ordinary-cache
release and memory/LRU eviction cannot remove it. Count its bytes in retained-cache
admission; reject work rather than evict it. Complete replacement is atomic and
size-checked, preserving the old pin on failure. Model changes/unload/worker death
invalidate it. Inference failures clear ordinary caches but preserve the untouched
immutable baseline. Metadata/logging must never include system text or tokens.

## Startup recovery

ServiceKit StartupRecovery retries failed startup indefinitely at 5/10/20/40/60
seconds, capped at one minute. A single owned task coalesces duplicate launches;
Stop cancels retries and cancellation must drain before another start. Clean up
failed listeners/helpers before retry. RA readiness includes complete model load,
not merely launching its worker; Data recoveryRequired is an already-running
repository needing exact transaction recovery, not permission to restart or replay
writes. Orchestrator retries upstream identity/bootstrap failures. Retriever retries
its service/store initialization, never interrupted paid captures. Show the last
startup error, attempt and next delay. Preserve autostart opt-outs and manual Stop.
This policy does not retry accepted inference, retrieval, writes or runtime job
errors, and does not bypass Keychain, FileVault or macOS login.

## Window placement

ServiceKit WindowFrameMemory saves each dashboard’s windowed frame in app-local
UserDefaults (ServiceKit.WindowPlacement.<app>.dashboard), with a ColorSync display
UUID and prior visible-screen bounds. SwiftUI roots use rememberWindowFrame;
Retriever retains the native controller before showing its window. Restore once
per window, not on each update/tab change. Save move/resize changes with a 250 ms
debounce, flush on close/quit, and exclude minimized/full-screen geometry.
Disconnected/rearranged/resized displays use bounded visible fallback placement.
Keep preferences separate from project files and service startup/session state.


## Opportunistic conversation preparation and count-only tokenization (2026-10-31)

RemoteAgentRequest.opportunistic is optional and valid only on configuration,
session.create, tokenize, cache.inspect and cache.prefill. HTTP admission uses
JobGate.tryAcquire and returns a terminal result with text=deferred when occupied;
never enqueue this optimization. Terminate the HTTP response even on deferral.
Normal calls keep existing admission, memory, prefix and cancellation policies.
Capabilities advertises opportunisticCachePreparation and tokenCountsWithoutAdmission.
RemoteAgentRequest.countOnly is optional and valid only for tokenize: return exact
inputTokens without a token array, cache allocation or generation-capacity check.
Keep bounded input validation; normal tokenization/prefill/generation still enforce
capacity. This permits measurement before bounded compaction of oversized histories.
RA owns only cache state; it neither compacts nor persists dialogue. Ready status
in the host dashboard is native green, while other status styling is unchanged.


Background document ordering uses HarnessCore BackgroundSnapshot.documentPrecedes: RecentEvents.txt is always last, including after unlisted extra documents. Keep exact snapshot bytes and hashes. Data's ordinary generic documentation transaction can include Decomposer's mechanically prepared RecentEvents append; it adds no server-side approval or custom write endpoint.


## Application-owned service lifetime (2026-10-31)

NSApplicationDelegate.applicationDidFinishLaunching starts the shared ServiceKit
ApplicationServiceLifetime, with one app-owned controller and poll loop. Never
attach service startup/monitoring or Stop to view tasks, onAppear/onDisappear,
window minimization or closure. Closing the last window leaves the app running.
Explicit Stop remains authoritative; monitor ticks never undo it. Quit returns
terminateLater, cancels/drains startup and monitoring, stops helpers, then replies.
The ProcessInfo activity prevents App Nap delays while allowing system sleep;
this does not bypass login/FileVault or prevent sleep. Data daily Git checks run
in this app-owned loop, independent of its dashboard. Keep window geometry and
visibility separate from service state.


## Host thermal status

The authenticated capabilities response includes optional hostThermal {state, sampledAt}, sampled from ProcessInfo.processInfo.thermalState in the RemoteAgent service process. States are nominal, fair, serious, critical or unknown. This is OS thermal pressure, not temperature, fan RPM or proof of throttling. Sampling never enters the GPU gate, creates sessions/caches or changes workload policy. Missing telemetry from an older server and unreachable-server readings must display unavailable rather than nominal. Decomposer uses its existing visible-only 10-second Server Status polling and clears old samples on failure. Optional fields preserve older client/worker interoperability.
