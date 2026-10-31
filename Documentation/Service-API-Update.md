# RemoteAgent service update — October 27, 2026

This update is backward compatible with existing version-1 clients. New optional
fields are ignored by older clients. GPU arrays remain on the server. No project
write tools or server-side conversation library are added.

## Memory and sessions

Retained snapshots have a ceiling of min(32 GiB, physical RAM/8). Incoming inference
reserves the complete independent working cache, the reply allowance, and 4 GiB
of GPU workspace before immutable cache references are copied. Idle snapshots are
evicted first when headroom is inadequate; explicit selected handles are protected.
If the request still cannot fit, it is rejected rather than silently shortened.
Checks between prefill batches and decode steps remain. Estimates cannot prevent
every Metal-driver allocation failure; the isolated worker remains the final
failure boundary. Live 397B memory testing remains necessary.

Below ten allocated sessions there is no time-based expiry. At ten or more,
sessions idle for an hour become eligible. At the sixteen-session cap, a new
session replaces the longest-idle eligible session. Pending work is protected.
The dashboard separates allocated sessions from active inference and lists IDs,
app/device labels, activity, timestamps and cache use. “Close session” releases its
caches; it does not delete a client's saved history. Closing queued sessions is
refused until that work is cancelled.

Session-create requests can include clientName, deviceName, clientDeviceID and
clientInstanceID. The device UUID is stable per app installation; the instance
UUID is shared across connections in one process and changes on app launch.
A new instance replaces the previous instance's sessions on the same device,
cancelling its queued work after the current GPU job reaches a safe boundary.
Multiple sessions in the same instance are retained. A replaced instance is
rejected if it tries to auto-reconnect during the same worker epoch. Older clients
without these fields cannot be reliably distinguished; they use User-Agent labels
where available and remain manually manageable. Updated Decomposer and Ray client
sources send these fields; already-running older clients require a rebuild/restart
to gain this behavior.

## New operations

All operations use the existing authenticated POST /v1/rpc over loopback or
private Tailscale HTTPS. Capability/background/recovery operations run in the
service process and do not wait for GPU inference.

- capabilities: returns a versioned capabilities object with limits and features.
- background.get: reads only the server-configured Background Prompt directory,
  using Decomposer's established document order. Returns exact UTF-8 content,
  ordered manifest, content hashes, assembled text and fingerprint. Optional
  fingerprint returns notModified=true when unchanged. Configure the folder in
  RA Settings while stopped. No client-supplied path is accepted.
- request.status: targetID is the original generation UUID. Returns state,
  timestamps, expiration and lastSequence.
- request.replay: targetID plus afterSequence (exclusive, default zero), limit
  (1–1000). Returns replayEvents with their original request IDs and sequence
  numbers, wrapped in a terminal response using this replay call's own ID. Page
  until reaching lastSequence, then inspect request.status again if still running.
- cancel: the separate RPC acknowledges cancellation requested. The original
  request's terminal outcome determines whether cancellation actually completed.
  Completion can win the race. A stuck worker is isolated and stopped by watchdog.

Queued/running requestState events are genuine admission transitions. Heartbeats
still only prove the connection is alive. No fictitious queue position is reported.

## Temporary output recovery and idempotency

Only generate is journaled/idempotent in this revision. Before dispatch it records
the request UUID and a canonical payload hash. Supplied prompts, message histories,
token arrays and bearer credentials are not written to the journal. Generated text
(including any model thinking), state transitions, usage and terminal records are
saved in sequence. Journals are private files under Application Support/RemoteAgent/
RequestJournal, separated by a hash of the bearer credential. This is one trusted
user's authentication scope, not a multi-tenant account system.

An identical repeated UUID returns its existing requestStatus without re-running
inference. A different payload with the same UUID is rejected. A disconnected HTTP
consumer does not automatically cancel a journaled generation; it can query/replay
later. A client explicitly sending cancel still cancels it. Output delivery to an
attached client remains ordered. Disk-write or storage-limit failures explicitly
fail/cancel the request, preserving previously retained output.

Output retention is one hour, at most sixteen completed records, at most 8 MB per
request plus a small terminal-record reserve, and 64 MB total. Completed output
can be evicted sooner to meet limits. Expired records leave bounded metadata-only
tombstones for an additional day (maximum 4096 records), preventing accidental
re-execution during that window. There is no indefinite UUID guarantee after
tombstones expire. Unknown and expired records are explicit errors; clients must
not automatically resubmit uncertain work under a new UUID.

Appends precede stream publication; terminal records are synchronized to disk.
A final partial disk append is recovered as incomplete, not accepted as terminal.
Interior corruption fails closed. Restarted nonterminal records become interrupted
and are never automatically resumed. This is process/network-interruption recovery,
not a guarantee against hardware failure or abrupt power loss at every token.
Clients retain canonical conversations and exact prompts locally. Recovery records
are not a replacement for that library.

## Validation and deployment

Automated tests use fake workers and loopback HTTP, exercising request de-duplication,
replay pagination, restart/partial-file recovery, expiration, output limits, background
ordering/path checks, authentication, cancellation, worker isolation, and session
policy. These tests do not load a second model. The optimized worker and dashboard
must be staged separately from the running app. Restart and real-model checks are
required to deploy; rebuilding cannot change an already-running process.

Ray's initial UI still imports a background file and marks lost streams incomplete.
The server endpoints are now available for a later client integration; capability
negotiation does not automatically enable UI features that have not been wired up.
