# Pinned base prompt API

Authenticated POST /v1/rpc; normal version-1 NDJSON terminal events.
- baseline.status: no session/input required. pinStateKnown=true, epoch, and
  optional pinnedCache {fingerprint, epoch, tokenCount, bytes}. No GPU queue.
- baseline.ensure: messages=[one complete system ModelMessage], optional fingerprint.
  Uses cacheFullConversation to select the same tokenizer/template policy as Chat.
  Server computes SHA256 of UTF-8 "pinned-system-v1\nnative=1\n" + content
  (native=0 when cacheFullConversation is false). Returns confirmed pinnedCache
  or text=deferred if inference is busy. No client cache handle is published.

One current pin per worker. System bytes/template policy changes replace it only
after successful prefill and size checks. Worker epoch binds model/tokenizer
identity. The immutable full attention/recurrent state and logits are server-owned,
count toward the cache byte budget and are excluded from session/LRU eviction.
Requests in any authenticated session can automatically reuse an exact matching
token prefix; they get independent working copies. Explicit ordinary cache handles
remain session-scoped. Closing sessions cannot release the pin. Unload/restart or
changed model files invalidate it. No disk GPU-state persistence is provided.

Callers own cadence and background defaults; no server refreshes project contents.
Ray checks on startup/foreground/reconnect and once per foreground minute. It
stores chats only on the phone. Preparation makes no visible conversation turn.
Do not repeatedly retry deferred work or load a model automatically from this API.
