# Ray — iPhone App Product and Implementation Specification

Status: Design specification; implementation has not been authorized by this document.

Prepared: October 26, 2026.

App name: Ray.

App icon: reuse the existing Decomposer app icon artwork. Do not commission or generate a different icon for Ray.

## 1. Purpose

Build Ray, a native iPhone chat application that provides the ordinary chat experience of Decomposer while using RemoteAgent (RA) on the user's Mac for model inference. Each conversation begins with the project's background documents as its system context. The user should be able to discuss the project from home or offsite without loading model weights on the phone.

The interface should feel familiar to a person who uses ChatGPT's iPhone app: a quiet conversation screen, a bottom composer, streamed replies, easy access to conversation history, and convenient copying. Use an independent visual identity and native iOS behavior rather than reproducing OpenAI branding or claiming affiliation. This specification describes the desired interaction style, not pixel-for-pixel parity with any particular release of ChatGPT.

The primary requirements are dependable text delivery, useful project context, preservation of conversations, effective prompt caching, and recovery from interruptions. Configuration and diagnostics must remain available without dominating the chat screen.

### 1.1 App identity and icon

Use Ray as the app's Home Screen display name, Xcode project/scheme and executable product name, and user-facing name in settings and exports. RemoteAgent remains the model server's name; Decomposer remains the desktop client's name.

Reuse the artwork in Decomposer's current `Harness/Assets.xcassets/HarnessIcon.appiconset`, with `icon_512x512@2x.png` as the existing 1024-pixel source. In the current workspace this is `/Users/mattrips/Documents/Decomposer/Harness/Assets.xcassets/HarnessIcon.appiconset/icon_512x512@2x.png`. Copy the source artwork into Ray's own iOS icon asset or supported Icon Composer asset during implementation; do not make the iPhone build depend on an absolute path into the desktop checkout or ship the macOS `.icns` as an iOS icon. Preserve the design while meeting the selected iOS deployment target's icon packaging requirements. Verify the installed icon on a real iPhone.

## 2. Scope and defaults

### 2.1 Initial release

The first release shall include:

1. Native iPhone chat with persistent conversations and drafts.
2. A project background snapshot fetched from the Mac and retained with each conversation.
3. RA authentication using an access token stored in iOS Keychain.
4. Streaming text, Stop, retry/regenerate, copy, text selection, and export.
5. Per-conversation inference settings and a configurable default for new conversations.
6. Server-held sessions and exact-token cache reuse.
7. Explicit request states, real prompt-processing progress, and optional performance details.
8. Safe behavior on network loss, app suspension, cancellation, cache eviction, and RA restart.
9. Private offsite access using the user's existing Tailscale deployment.

Defaults shall match ordinary Decomposer Chat:

| Setting | Initial default |
| --- | --- |
| Temperature | 0.6 |
| Maximum reply tokens | 16,384 |
| Top-k | 20 |
| Top-p | 0.95 |
| Context capacity | Server-advertised capacity, currently capped at 131,072 tokens |
| Response presentation | Plain text |
| Reasoning display | Hidden |
| Tools | None |
| Concurrent requests from this phone | One |
| Background refresh during an existing conversation | Explicit user action |

Defaults are application preferences, not guarantees that a requested prompt fits the available context or memory. The actual server configuration always governs admission.

### 2.2 Deferred features

Do not include these in the initial implementation unless separately authorized:

- Running a model on the phone.
- Driving Decomposer's investigation procedure.
- Project-reading tools beyond the explicitly configured background snapshot.
- Project-writing tools, arbitrary SQL, shell execution, or remote file browsing.
- Web search, COCA, OED, attachments, image input, voice input/output, or camera access.
- Automatic conversation compaction or silent removal of older messages.
- iCloud conversation synchronization or synchronization with Decomposer's desktop chat history.
- Multiple user accounts, public hosting, or public access through Tailscale Funnel.
- Remotely loading, unloading, or restarting the Mac's model.
- A general system for distributing arbitrary project folders to clients.

The iPhone conversation library and Decomposer's existing library are separate in the first release.

## 3. Architecture and ownership

```text
iPhone application
  Conversation UI, drafts, local history, prompt snapshots, settings
            |
            | Authenticated HTTPS through private Tailscale Serve
            v
RemoteAgent application on Mac
  API, admission queue, request lifecycle/recovery records,
  configured read-only background publication
            |
            | Private worker communication
            v
RemoteAgent inference worker
  Loaded MLX model, tokenizer, chat template,
  immutable attention/recurrent cache snapshots, GPU execution
```

Ownership rules:

- The Decomposition folder on the Mac remains the source of truth for project background.
- The phone stores immutable background snapshots as conversation records; they are not an independently maintained edition of the project documents.
- The phone owns its conversation history, user edits, branches, and inference records.
- RA owns model weights, model-dependent tokenization, chat rendering, and processed cache state.
- Cache handles are temporary capabilities. They are never the sole copy of conversation content.
- The model does not configure networking, retrieve credentials, decide whether generation completed, or manage persistence.
- No new hosted service is required.

## 4. iPhone interface

### 4.1 Main conversation screen

Use a native SwiftUI screen with a compact navigation bar, a scrollable conversation, and a bottom composer above the keyboard/safe area.

The navigation bar shall contain a history/sidebar button, the conversation title, and an overflow menu. A new-chat action must be easy to reach. A subtle connection indicator can appear when connection state matters; a healthy connection must not consume a permanent warning banner.

Conversation layout:

- User messages use restrained rounded bubbles, aligned toward the trailing side.
- Assistant messages use readable, mostly full-width text aligned to the leading side, without heavy surrounding cards.
- Use the native system font at a comfortable body size with Dynamic Type. Do not copy the desktop's fixed 12-point setting onto a phone.
- Use adequate paragraph spacing and line length. Long replies must remain easy to select, scroll, and copy.
- Support system light and dark appearance, native keyboard behavior, and readable contrast.
- Do not put token counts, JSON envelopes, tool syntax, or network logs into the conversation body.
- Never present an interruption, cancellation, or server error as if it were an assistant-authored message.

The composer shall support multiline text, grow to a reasonable maximum height, and scroll internally beyond that height. Preserve drafts across navigation and app relaunch. Provide an explicit Send control; inserting a newline must remain possible with a hardware keyboard. Use a documented hardware-keyboard shortcut such as Command-Return for sending.

While a request is active, the Send action becomes Stop. The user may continue preparing a draft, but it must not be sent automatically after the current response ends. A second generation from this phone is not admitted until the current request is terminal or explicitly resolved as unavailable.

### 4.2 Streaming and scrolling

Follow new text automatically only while the user remains at the bottom. Manual scrolling upward disengages following immediately, even while generation continues. Show a small jump-to-latest button when the user is above the bottom. Tapping it re-enables following. Receiving another token must not drag the user back down.

Preserve scroll position when the keyboard opens, a status label changes, settings are dismissed, or new text is appended. Test with long conversations and long individual replies.

Accumulate every received text fragment exactly, but publish normal view updates at no more than approximately four per second. Show the first visible text promptly and flush remaining text immediately on a terminal event. Do not equate display batching with discarding tokens. The networking and persistence paths must not depend on the speed of text layout.

### 4.3 Message actions

An assistant reply shall have a convenient Copy action and a context menu with Select Text and Regenerate. Copy must obtain the entire visible reply from the stored message, including later paragraphs, rather than copying a visible subsection or a truncated view representation.

User messages shall support Copy and Edit. Editing an earlier message creates a new branch; it must not silently mutate the historical conversation or overwrite later replies. Regeneration likewise creates another response branch. A compact branch selector is sufficient; a graph UI is unnecessary.

Incomplete replies may be copied, but must remain labeled incomplete. Copy excludes hidden reasoning, inference diagnostics, and application status text.

### 4.4 Conversation history

Provide a sidebar or native slide-over history view with:

- New conversation.
- Conversations grouped by recency.
- Rename, search, delete, and export actions.
- Clear indication of the selected conversation.

Generate an initial title locally from the first user message. Do not consume a model call to name every conversation. Renaming a title must not alter model context or invalidate caches.

Navigation to another conversation must not cancel a request merely because its view disappeared. The request belongs to an application-level conversation controller. Only one phone-originated request is active at a time; show where that request is running if another conversation is opened.

### 4.5 Conversation information and settings

The overflow menu opens a compact information/settings sheet containing:

- Project and background snapshot version, source filenames, and refresh status.
- Model identity and actual context capacity.
- Temperature and maximum reply tokens.
- Advanced top-k and top-p controls, initially collapsed.
- Context usage, including reserved reply allowance.
- An optional collapsed Performance section.
- Export and branch-management actions.

App-level settings contain the server URL, connection test, access-token setup/replacement, default inference settings, and local data/export preferences. Never display the saved token in ordinary settings text.

Do not add engineering slogans or a permanent server dashboard to the chat screen.

## 5. Project background and prompt construction

### 5.1 Single source and publication

The initial project is Decomposition. The Mac shall publish only a configured background directory, initially:

`/Users/mattrips/Documents/Decomposition/Background Prompt`

RA currently does not expose project documents. Add a separate, authenticated, read-only background-publication component in the server application, outside the inference worker. It may read only the configured publication root, not arbitrary paths requested by the phone. Changing that root is a local Mac settings action.

Do not upload the whole Decomposition folder. Do not bundle a permanent copy of background documents into the iPhone app.

The current Decomposer background order is:

1. Identity.txt
2. ProjectIntro.txt
3. GlossarySquibs.md
4. Notation.txt
5. VerbFunctionExamples.tsv
6. Other supported files, ordered by filename using the shared assembler's deterministic ordering.

The implementation must share the authoritative assembly rule rather than maintain an independent phone-specific list. Notation must precede the verb-function examples. Supported current extensions are txt, md, tsv, yaml, and json; hidden files are excluded. Existing missing/unreadable-file behavior must be made explicit in the publication contract.

Require valid UTF-8. Report an unreadable document by name; do not silently omit it or substitute text. Reject symlinks escaping the configured publication root.

### 5.2 Snapshot contract

Each published snapshot shall include:

- A project identifier and display name.
- A snapshot identifier derived from the exact ordered background bytes and assembly-version identifier.
- An ordered manifest of filenames, UTF-8 byte lengths, and content hashes.
- The exact assembled background text, including the same document headers/separators used by Decomposer.
- Assembly schema/version information.
- Publication time for information only; fetching unchanged content must not create a new content version.

Assemble and validate a complete snapshot before returning it. Detect files changing during the read; retry a bounded number of times or report that publication is temporarily unavailable. Do not serve a mixture of document versions.

The phone verifies content hashes and saves the snapshot atomically. Store the exact system message separately as well; reconstructing it from future assembly code is not a sufficient audit record.

### 5.3 Snapshot changes

New conversations use the latest successfully fetched snapshot. Existing conversations remain pinned to their saved snapshot.

When a newer version exists, show a small notice with Review and Use Updated Background actions. Applying an update creates a new conversation revision/branch, preserves the old revision, and invalidates incompatible cached state. Do not silently replace the system message midway through a conversation.

An offline user can read history and prepare drafts. Sending with a previously saved background snapshot is permitted when RA is reachable; display that the conversation uses that saved version. Creating the first project conversation without any available snapshot must fail clearly rather than send without project background.

### 5.4 Message construction

Use actual system/user/assistant roles:

```text
system: complete pinned background + stable chat policy
user: first user message
assistant: first completed model response
user: next user message
...
```

Place background and stable output policy in one system message. Do not insert timestamps, connection notices, request IDs, performance details, or turn-specific text into that system message.

The chat policy shall request plain text, prohibit Markdown/LaTeX/HTML response formatting, and request no displayed thinking blocks. Native selection and copying must work even if the model ignores the formatting request; do not render Markdown or LaTeX in the initial release.

A proposed policy should preserve the existing Decomposer Chat formatting requirements and project identity without adding procedure-step instructions. Do not automatically insert Decomposer's investigation notebook or desktop transcript.

Preserve the exact raw model response separately from its display form. Reuse the shared Qwen non-thinking history/template handling. Hiding reasoning in the UI must not imply that those tokens were not generated, counted, or cached. A streaming filter must handle reasoning delimiters split across network/text batches. Visible-answer text and canonical model context must not be conflated.

## 6. RemoteAgent protocol integration

### 6.1 Existing capabilities

As inspected on October 26, 2026, RA uses authenticated `POST /v1/rpc` requests and newline-delimited JSON responses. Requests have a protocol version and UUID. Events have a matching request ID, an event kind, and a terminal indicator.

Existing operations include configuration/status, session.create/close, tokenize, cache.prefill/append/fork/inspect/release, generate, verify, and cancel. Existing generation settings include maxTokens, temperature, topK, and topP.

Initial server limits include one active GPU request, four waiting requests, sixteen sessions, eight cache snapshots, a 131,072-token cap bounded by the model, and a maximum reply request of 32,768 tokens. HTTP request bodies are bounded to 4,000,000 bytes and protocol frames to 8,000,000 bytes. Treat these as inspected implementation defaults, not permanently hardcoded phone assumptions.

The phone shall use Codable wire types in a small platform-neutral module. Do not link MLX, model loaders, AppKit, or the Mac application target into the iOS app. If extracting shared code, keep the wire protocol independent of the larger investigation engine.

### 6.2 Connection lifecycle

On connection:

1. Validate the configured endpoint and retrieve the token from Keychain.
2. Request server configuration/capabilities and confirm a usable model is loaded.
3. Fetch or validate the project snapshot.
4. Create a conversation session lazily when inference is actually needed.
5. Obtain exact model tokenization and cache boundaries from RA.

Keep three states distinct: network reachable, authenticated service available, and model ready. A reachable server with an exited worker is not a connected, inference-ready model.

Use the server's tokenizer and chat template. The phone must not independently guess Qwen role delimiters, token IDs, or reasoning preambles. Negotiate support for stable full-conversation/non-thinking behavior; the existing ModelMessage cacheFullConversation flag is an implementation mechanism to preserve, not a reason to duplicate template logic on iOS.

### 6.3 Required server additions

These are implementation requirements, not capabilities claimed to exist today:

| Addition | Purpose |
| --- | --- |
| Versioned capability advertisement | Negotiate background publication, recovery, queue reporting, template policy, and numeric limits |
| Background snapshot endpoint | Fetch the configured project's immutable manifest and assembled text |
| Bounded request-status/recovery API | Recover an in-flight or completed response after the phone loses its stream |
| Request-ID deduplication | Prevent a reconnect or transport retry from starting another generation |
| Sequenced replayable output | Reattach without missing or duplicating text |
| Explicit queue and processing phase events | Distinguish queued, prefill, decoding, cancelling, and terminal states truthfully |

Suggested routes are authenticated `GET /v1/capabilities`, `GET /v1/projects/default/background`, and session-scoped request status/replay routes. These names are proposals; finalize and version their schemas before implementing clients. Existing `/v1/rpc` compatibility for Decomposer must remain intact.

All new routes must be behind the same authentication and private network boundary. There must be no generic file-path parameter or directory listing through the background endpoint.

## 7. Sessions, exact-token caching, and context budgets

Give each conversation branch an independent session, allocated lazily. Close inactive sessions when practical; keep all durable conversation data locally so sessions can be recreated. Do not keep an unlimited session open for every conversation in history.

Preserve immutable server snapshots at reusable background/history boundaries and at the stable current-input boundary. Start later turns from the longest exactly matching token prefix. Never treat a warmed handle as proof that its cache remains resident: inspect it, or use an API that explicitly reports cache misses and valid replacement handles.

RA must preserve all model-required attention, recurrent, convolution, and other state. The phone receives handles and token IDs, not GPU arrays. Edits, branching, compaction, template changes, model reloads, and background revisions can all invalidate a previously useful prefix.

Keep visible text, raw generated token IDs, stopping-token metadata, and the server's complete processed cache token sequence conceptually separate. Existing RA may process an EOS token into its cache and report it in the terminal result separately from visible token events. Do not append that token as visible text or assume that displayed text can reconstruct its exact cache sequence.

Record a cache identity using the worker epoch, model/template identity, session, conversation revision, and relevant background/policy fingerprints. Cache handles never authorize mixing another conversation's responses into the current context.

Before generation, validate both:

```text
input tokens + reserved reply tokens <= actual context capacity
serialized request bytes <= negotiated request-body limit
```

If either budget is exceeded, explain the actual counts and available reply allowance. Offer an explicit smaller reply allowance, a new conversation, or a later user-approved compaction feature. Do not silently truncate documents, remove earlier messages, or lower the requested reply allowance.

Capacity is not a guarantee of available GPU memory. Display a distinct memory-admission/error state if the model cannot safely handle a request within the nominal token limit. Do not automatically retry a memory failure with altered context.

## 8. Request lifecycle, streaming, and recovery

### 8.1 States

The conversation controller shall persist a state machine with at least:

```text
Draft -> Preparing -> Waiting for server -> Processing prompt -> Generating
                                                    |              |
                                                    +-> Cancelling-+

Terminal states: Complete, Output limit, Cancelled, Failed
Uncertain transport state: Connection lost / Recovering
```

Use a queued label or position only when RA explicitly reports it. Heartbeats prove that a connection is alive; they do not prove GPU progress. A disconnected stream without a terminal record is incomplete, even if its text appears well formed.

### 8.2 Progress and timing

Use a small status area above the composer, with details available on demand:

- Waiting for server or queue state.
- Processing X of Y new tokens, using evaluated prefill counters.
- Generating, generated-token count, and Stop.
- Cancelling, followed by Cancelled only after acknowledgement.
- Connection lost / Recovering when the result is uncertain.

Optional performance details shall include total/cached/uncached input tokens, prompt-processing time, time to first visible text, generated tokens, live decode rate, final decode rate, and request elapsed time. Define time-to-first-text from Send, including queue/prefill; keep it distinct from decoding speed.

When the phone warms a cache as part of a request, aggregate that work into the request's uncached-token count and processing duration. Do not credit newly warmed tokens as pre-existing reuse merely because the later generate RPC reports them as cached. This avoids the mismatched client/server totals already encountered in desktop testing.

Timers stop on terminal states. Do not continue showing an elapsed clock as if a cancelled request is still active. Normal completion, output limit, cancellation, transport uncertainty, and failure need distinct presentations.

### 8.3 Lossless delivery

Network parsing, model-event handling, durable persistence, and view updates must be separate responsibilities. Use bounded queues with real backpressure or bounded coalescing. Neither a full UI queue nor a full network queue may silently drop response text. Increasing an arbitrary event-count limit is not an adequate design.

Persist text in exact order. Coalesce transient progress updates when useful, but preserve terminal events and all answer content. If an explicit hard byte/resource limit is exceeded, fail clearly and retain the exact partial output already received.

Test fragmentation in the middle of JSON records, UTF-8 characters, reasoning delimiters, and multiline paragraphs. The user must never receive missing punctuation or digits because the display consumer was slower than the model.

### 8.4 Cancellation

Stop sends an explicit cancellation request targeting the active request UUID. It must work while queued, waiting for first text, processing a prompt, or generating. A caller timeout or abandoned conversation controller must invoke the same explicit path; do not rely exclusively on a Swift stream being deallocated.

The UI shows Cancelling until cancellation is acknowledged or a different terminal outcome wins the race. If completion arrived first, preserve the completed response and explain that it finished before cancellation took effect.

RA's existing cooperative-drain and worker-isolation mechanisms remain authoritative. The phone cannot promise instantaneous interruption of GPU work. If RA must terminate its worker, report that the model needs attention on the Mac and that cache handles expired.

### 8.5 Network interruption and request identity

Persist the request UUID and exact request fingerprint before submission. Reuse that UUID only for status/recovery or a server-supported idempotent retry of the identical request. A repeated UUID with a different payload must be rejected.

On interruption, first ask RA what happened. Reattach using the last persisted event sequence number, replay only subsequent events, and deduplicate replayed events before updating text. A completed reply recovered from RA becomes complete only after its terminal record is verified.

Do not automatically start a fresh generation because a request timed out, the app was reopened, or the phone changed networks. If the server no longer has a record, retain the partial reply as incomplete and offer an explicit Retry as a new attempt. Preserve its relationship to the earlier attempt.

Required server recovery records shall be bounded, separate from GPU cache snapshots, and contain generated output, sequence/terminal metadata, usage, request fingerprint, and ownership information. Suggested initial limits: one-hour retention, at most 16 completed records, an aggregate 64 MiB output-journal budget, and an 8 MiB per-record bound. Finalize bounds with load tests. Do not hold request prompts or credentials in diagnostic logs. If a record expires or is evicted, report that explicitly; never claim its response can still be replayed.

Recovery cannot be promised by the current RA protocol alone. Request recovery is a prerequisite for considering offsite mobile use reliable.

## 9. iPhone lifecycle and offline behavior

The implementation must respect iOS background execution limits; it must not assume that an ordinary app can keep an inference stream alive indefinitely after the screen locks or another app opens.

On backgrounding, save the conversation, draft, request ID, and last persisted sequence. Use an OS-permitted short background task to finish this bookkeeping and request cancellation where appropriate. This is best-effort cleanup, not a guarantee that cancellation will reach the Mac before suspension.

For the first release, do not advertise unattended background generation. On return, query request status and recover any output generated before cancellation/suspension. If the OS killed the app before cancellation was delivered, recover or cancel the server request explicitly. A later background-completion feature requires a separate design and testing effort.

Offline behavior:

- Reading, searching, copying, renaming, and exporting saved conversations work offline.
- Drafts remain editable and durable.
- Unsent drafts are visibly unsent; reconnection does not send them automatically.
- Connection failure does not erase existing project snapshots or conversation data.
- The phone must not create an apparent assistant response from stale or cached text belonging to a different request.

## 10. Local data and audit records

Use a transactional local store appropriate for iOS. SQLite is a suitable default; the exact persistence wrapper can be chosen during implementation. Keep migrations versioned and test them. Avoid making a particular new persistence framework a requirement before the deployment target is selected.

Logical records:

| Record | Essential fields |
| --- | --- |
| ServerProfile | Local ID, display name, HTTPS endpoint, Keychain reference, last verified model/capabilities |
| ProjectSnapshot | Project ID, snapshot hash, ordered manifest, exact assembled background, assembly version, fetch time |
| Conversation | UUID, title, creation/update times, selected branch, draft, default settings |
| ConversationRevision | UUID, parent revision, project snapshot, exact system policy, canonical message references |
| Message | UUID, role, branch/parent association, exact display text, raw response reference, status, timestamps |
| GenerationAttempt | Request UUID, conversation revision, exact messages/settings or immutable references, model/epoch, token counts, sequence checkpoint, termination/error, usage |
| RemoteSessionBinding | Endpoint/epoch/session IDs, branch binding, cache handles/fingerprints, last successful use |

Session bindings are replaceable runtime metadata. Message records and snapshots remain available if every remote handle is lost.

Save user messages before network submission. Checkpoint streamed output on a small bounded interval, for example every 0.5–1 second, and flush on completion, cancellation, and lifecycle transitions. Prevent duplicate message insertion during recovery with unique request and sequence constraints.

Use platform file protection for local data. Never store bearer tokens, OED credentials, COCA credentials, or Tailscale credentials in conversation records. This phone app does not need the paid-source credentials to perform ordinary chat.

Deletion removes the selected local conversation and schedules best-effort remote session/cache cleanup; do not imply that it deletes the authoritative project documents. The interface must explain any retained export or shared file separately.

## 11. Networking, authentication, and security

- Use a Tailscale Serve HTTPS URL for the phone. `127.0.0.1` on an iPhone refers to the iPhone, not the Mac.
- Keep RA bound to Mac loopback and let the existing private Tailscale deployment carry remote traffic. Do not expose an unauthenticated LAN listener or use public Funnel.
- Require normal TLS certificate validation. Do not add an accept-any-certificate mode.
- Send the RA token only in the Authorization header. Never put it in a URL, QR image of a conversation, log, screenshot intended for support, export, or prompt.
- Store the token in iOS Keychain with device-local access semantics. A reinstall/restore must not be assumed to restore working authentication automatically.
- Reject unexpected redirects before resending authenticated data.
- Do not embed Tailscale credentials or manage the user's tailnet policy. Provide concise setup instructions and a connection test; the user signs in through Tailscale itself.
- Keep diagnostic logs free of complete prompts and model output by default. A user-requested diagnostic export must preview its contents and exclude secrets.

The Mac must be awake, RA must be serving a loaded model, and the private network route must be available. The phone cannot repair an asleep Mac or a crashed model worker by pretending to reconnect successfully.

## 12. Error behavior

| Condition | Required behavior |
| --- | --- |
| Tailscale/endpoint unreachable | Keep draft/history; explain connection failure; offer Test Connection |
| Authentication rejected | Prompt to replace the saved RA token; do not repeatedly retry it |
| Service reachable, model unavailable | Show model unavailable and ask the user to attend to RA on the Mac |
| Queue full | Show busy/retry information; do not silently create a new request |
| Cache evicted or session expired | Recreate context once from local canonical records when safe; report rebuild progress |
| Worker epoch changes | Invalidate handles, query request outcome, rebuild only for a new or confirmed-not-started request |
| Context/body budget exceeded | Report exact budget and explicit options; no silent truncation |
| MLX/Metal/memory failure | Retain partial text, mark failure, expose a short error and technical details; no automatic altered-context generation |
| Reply token limit | Mark Output limit, retain partial answer, offer explicit continuation/new attempt |
| Missing terminal record | Mark outcome uncertain/incomplete; recover by request ID |
| Malformed protocol or out-of-order sequence | Stop accepting the affected stream; retain verified text and attempt recovery without duplicating output |
| Background snapshot invalid/unreadable | Keep the last pinned snapshot; do not substitute a partially read one |

Successful recovery must not hide a server-side failure or turn an incomplete reply into a completed answer without evidence.

## 13. Accessibility and performance

Support Dynamic Type, VoiceOver, dark mode, sufficient contrast, and touch targets appropriate for iPhone. Status updates must not continuously interrupt VoiceOver. Announce meaningful state changes rather than every token.

Measure layout and scrolling with long replies, several hundred messages, and large saved backgrounds. Use stable message identities and lazy presentation so appending text does not rebuild every historical message. Keep expensive tokenization, JSON parsing, networking, and persistence off the main UI actor where appropriate.

There is no promised generation speed in the UI specification. The Mac, model, prompt length, queue, and settings determine inference performance. The phone should add little overhead and must not throttle model execution merely to animate text character by character.

## 14. Verification and acceptance criteria

### 14.1 Interface

1. A long streamed reply does not prevent scrolling up; new text does not steal scroll position.
2. Jump to latest restores following, including with the keyboard open.
3. Copy returns every visible paragraph of a long assistant reply exactly, including Unicode and final lines.
4. Plain text remains selectable when it contains Markdown-like syntax or formula notation.
5. Draft text survives app termination, history navigation, and a failed send.
6. Large accessibility text sizes remain usable without hiding Send/Stop.

### 14.2 Context and caches

1. Snapshot ordering matches Decomposer, including Notation before VerbFunction examples.
2. Same-content background fetches produce the same snapshot identity.
3. A conversation remains pinned until the user explicitly updates its background.
4. Independent branches/conversations cannot introduce each other's messages.
5. A second normal turn reuses an exact prefix when the cache is resident; eviction causes a safe rebuild.
6. Cached and cold short-prompt execution pass the appropriate numerical checks. Keep identical-batching replay checks distinct from different-batch numerical differences.
7. Token accounting includes cache warmup work; cached plus uncached equals total input.
8. Overflow reports the complete reserved-reply calculation and never truncates material silently.

### 14.3 Delivery and recovery

1. Deliberately pause the consumer and deliver a burst substantially larger than both former 512-event buffers. The assembled reply must match expected text byte-for-byte and retain its completion record.
2. Cancel while queued, before first text, during prefill, during decoding, and while a queue is full. Confirm prompt cancellation, GPU drain or explicit worker recovery, frozen timers, and an accurate Cancelled state.
3. Background/lock/terminate the phone app at each request stage. On return, obtain an explicit outcome or retain uncertainty; do not duplicate generation.
4. Disconnect and reconnect networks mid-paragraph, mid-UTF-8 sequence, and immediately before terminal completion. Replay must not lose or duplicate text.
5. Resubmit the same request UUID and payload. At most one generation executes. A changed payload with that UUID is rejected.
6. Restart RA or kill its worker. Cached handles expire, saved phone history remains intact, and the app does not claim the old model session is still ready.
7. Closing a phone session updates RA's actual session/cache counters. The model remains loaded for other clients.
8. Run Decomposer and the phone together. Verify queue fairness, bounded resources, and distinct sessions/caches without loading a second model.

### 14.4 Release gates

Compilation, fake-server tests, and a simulator run are necessary but insufficient. Before calling the initial release ready, complete:

- Real iPhone testing over the private Tailscale path.
- Real 397B generation, cache reuse, cancellation, and recovery tests.
- Phone suspension/network-change tests.
- A long-conversation and slow-consumer soak test.
- A concurrent Decomposer/phone session test.
- Authentication, export, and background-publication access checks.

## 15. Implementation sequence

1. Review this specification, confirm the deployment target, and freeze the initial scope. Create the app as Ray and reuse Decomposer's icon artwork as specified above.
2. Specify and test RA's capability, background-publication, request-identity, status, and replay contracts. Preserve Decomposer compatibility.
3. Extract the small platform-neutral wire/client layer and build deterministic fake-server tests before involving model weights.
4. Build the native conversation UI and transactional local persistence against the fake server.
5. Integrate project snapshots and exact prompt construction, then server sessions and cache reuse.
6. Complete Stop, cancellation acknowledgement, lifecycle transitions, and reconnection/replay.
7. Add export, branch navigation, settings, and optional performance details.
8. Run the release-gate checks on the actual Mac/model/iPhone combination.

An internal prototype may use the existing streaming RPC before recovery endpoints exist, but it must be labeled a prototype and must mark dropped connections incomplete. Do not advertise reliable offsite use until request recovery is implemented and tested.

## 16. Decisions still to confirm before implementation

- The user's iPhone model and minimum supported iOS version.
- Whether later releases should add project tools or desktop/phone history synchronization.
- Distribution method for the user's devices and the associated signing/provisioning setup.
- Whether authenticated response recovery should eventually survive restarting the RA application itself. The initial bounded recovery journal may remain in memory; a server restart must then report the loss explicitly.

These questions do not prevent retaining this specification or planning the initial architecture. No application code, project records, networking configuration, or credentials are changed by this document.
