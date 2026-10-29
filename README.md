# RemoteAgent

RemoteAgent owns the model weights and server-resident prompt caches. Decomposer
owns the investigation, background documents, tool execution, confirmations and
project files. Multiple Decomposer clients can share one loaded model; GPU jobs
run one at a time, with up to four waiting requests.

Open `RemoteAgent.xcodeproj`, select the **RemoteAgent** scheme, and run. Its Run
configuration is Release. The scheme embeds `RemoteAgentWorker` in the app's
`Contents/Helpers` directory. Keep this source folder beside Decomposer: the two
apps share the existing HarnessCore and HarnessMLX source packages at build time.
Built app bundles do not require those source folders at runtime.

## First connection

1. Stop/unload Decomposer's local model before loading 397B in RemoteAgent.
2. RemoteAgent automatically loads the last selected model and starts its service
   on launch (initial default: the local 397B directory). If the directory is
   unavailable, choose a model directory and click Load model and start. Automatic
   loading happens once per launch, with no retry loop after failure or manual
   Stop. For maintenance, launch with `--no-autoload`.
3. Wait for Ready and copy the access token. It is generated with secure random
   bytes and stored in the macOS Keychain, never in a URL or configuration file.
4. In Decomposer Settings, enter `http://127.0.0.1:8321`, paste the token, Connect.
   A successful connection is remembered; the token is stored in Keychain.

To connect offsite, install and sign in to Tailscale on both Macs, then run on the
server Mac:

```
tailscale serve --bg http://127.0.0.1:8321
```

Use the resulting HTTPS URL and the same RemoteAgent token in remote Decomposer.
Restrict access using your tailnet's grants/ACLs. Use Serve, not public Funnel.
Tailscale manages VPN reconnection and HTTPS certificates; RemoteAgent never
asks for a Tailscale password or changes your tailnet policy. The service itself
binds only to IPv4 loopback. Do not add an unauthenticated LAN reverse proxy.

## Token-level API

`POST /v1/rpc`, `Authorization: Bearer <token>`, `Content-Type: application/json`.
Responses are newline-delimited JSON events, with request ID, protocol version,
and a terminal result or error. Five-second heartbeat events distinguish a quiet
prefill/queue from a dead connection. Disconnect before a terminal result means
incomplete output, never successful generation. No writes are retried automatically.

Request fields are defined by `HarnessCore.RemoteAgentRequest`. Operations:

| Operation | Inputs and behavior |
| --- | --- |
| configuration / status | Loaded model and worker epoch |
| session.create / session.close | Create a random capability / release its caches |
| tokenize | sessionID and messages or text; exact model token IDs and verified reusable boundaries |
| cache.prefill | sessionID and full tokens; immutable processed cache and handle |
| cache.append | sessionID, cacheID and suffix tokens; new immutable branch |
| cache.fork | sessionID, cacheID, optional boundary; exact-boundary fork, replaying from an earlier snapshot when needed |
| cache.inspect | sessionID and cacheID; exact cached token IDs and length |
| cache.release | sessionID and cacheID; drop the named snapshot |
| generate | sessionID and messages or tokens; optional exact-prefix cacheID, maxTokens, temperature, topK, topP |
| verify | sessionID and up to 512 tokens, optional cacheID; next-logit comparisons against both a single cold batch and a cold replay of the recorded batches/copy points |
| cancel | targetID of the in-flight request |

Start with `{"version":1,"id":"<UUID>","operation":"session.create"}`.
Use the returned sessionID in subsequent operations. Every request needs a fresh
UUID. Handles are valid only in their owning session and worker epoch. An explicit
cacheID with changed prefix is an error. Without one, longest exactly matching
prefix selection is automatic. No approximate-prefix matching is performed.

Qwen3.5 attention, convolution and recurrent state, and next-token logits, are
kept together. Forks copy the full upstream cache. Arbitrary earlier boundaries
are reconstructed; recurrent state is never trimmed backward. Generated tokens
are processed into a new immutable snapshot, leaving the original branch intact.
Decode uses upstream MLX `TokenIterator` pipelining. If a stopping token was
forwarded by the iterator, it is retained in the exact cache token sequence and
reported in the generation terminal result's `tokens` array, separate from visible
output tokens. `cache.inspect` always returns the complete processed sequence.
Pending GPU work is drained before a snapshot is committed or an error returned.
Decomposer warms background/history boundaries and receives total/reused/new
token counts, prefill time, generated token counts and generation speed.

## Resource and failure policy

- 131,072-token initial context cap, bounded by the model's advertised capacity;
  reserve the complete reply allowance; reject overflow without truncation.
- One GPU request at a time, four FIFO waiters, 32 HTTP connections, bounded
  headers/bodies/IPC frames and output buffers. Slow consumers fail explicitly.
- Below ten allocated sessions, no idle timeout. At ten or more, sessions idle
  for an hour may expire. Active and queued sessions are protected. At sixteen,
  a new session replaces the longest-idle eligible session. The dashboard lists
  clients and allows manual session closure, releasing their caches.
- New clients identify app, device and process instance. A newly launched
  instance replaces the previous instance on that device, cancelling its queued
  jobs; multiple sessions in the same instance remain valid. Replaced instances
  cannot silently reconnect and evict the new owner during the worker epoch.
- Retained-cache ceiling min(8 GiB, RAM/32), with earlier eviction to reserve an
  independent working cache and 4 GiB GPU workspace for the incoming request.
  Fair per-session LRU remains, with a secondary 256-snapshot metadata ceiling.
- MLX allocations capped below physical RAM with an OS reserve. Admission estimates
  include the full working prompt and reserved reply tokens, independently of retained snapshots. System free/reclaimable
  pages and MLX active allocations are checked every prefill chunk/decode step.
  The OS headroom reserve is 4 GiB. A failed initial admission check waits two
  seconds and retries once before evicting eligible snapshots; a remaining
  shortfall still rejects before inference. The independent 4 GiB GPU-workspace
  allowance and MLX allocation cap remain in force. Cancellation interrupts the wait.
- Thirty-minute worker request watchdog; ten-minute loading deadline. Cancellation
  requests drain cooperatively; an unresponsive worker is killed after five seconds.
- Worker death invalidates every session/handle, fails pending requests and leaves
  the GUI alive. Stop/reload explicitly; no uncontrolled automatic restart loop or
  automatic replay of a partially delivered response.
- MLX/Metal/memory errors invalidate caches. Invalid client requests do not grant
  access to other sessions or rewrite earlier results. The protocol has no shell,
  file-writing, arbitrary SQL or remotely callable model-loading operation.

Memory estimates reduce risk; they cannot guarantee that a driver or OS will never
terminate a worker. A full 397B soak test and offsite Tailscale test are deployment
checks, not implied by compilation or fake-worker tests. Use `verify` with a short
real-model prompt to check cached/cold numerical behavior on the deployed model.

The dashboard's **Run local checks…** button tests the already loaded model over
the loopback API and saves a JSON report. It checks cache replay, fork/append,
immutable branches, cached/cold greedy output, Chat's temperature 0.6/top-k 20/
top-p 0.95 sampling, temperature-only sampling, session isolation, context overflow
and released handles. The access token stays in memory and is excluded from the
report. These checks briefly occupy the inference queue; run them between jobs.

Verification retains the original strict `equivalent` result (relative tolerance
0.005, absolute tolerance 0.05) against a single cold batch. `replayEquivalent`
compares against an empty-cache replay with the same batch sizes and cache-copy
points. A replay match alongside a single-batch mismatch identifies batch-dependent
numerics rather than a state-copy discrepancy for that trial. The report also
includes next-token agreement and maximum probability difference. A successful
short-prompt diagnostic is not proof of equivalence for every prompt or model.

During 397B loading, the dashboard shows elapsed time and the same empirical
memory progress estimates as Decomposer: total memory growth from the starting
baseline to +217 GB, and total wired memory from zero to 217 GB. These are system
memory estimates, affected by other apps, rather than a count of loaded tensors.

Prompt processing reports completed new tokens after each evaluated chunk, with
cached tokens excluded. Both apps display the completed/total count; Decomposer
labels reusable-context preparation separately from the remaining prompt pass.
These are live status updates, rather than one activity-log entry per chunk.

Run protocol/process/HTTP tests with `swift test`. They use a small fake worker and
do not load model weights. Build the native scheme to include MLX Metal resources.

## October 27 server capabilities

See [Service API update](Documentation/Service-API-Update.md) for authenticated background publication, capability negotiation, session identity, genuine queue states, idempotent generation and a bounded on-disk output recovery journal. Conversations remain owned by clients. These changes require restarting into the staged app; rebuilding does not update a running worker.
