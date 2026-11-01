# Window placement memory — 2026-10-31

All four app dashboards use ServiceKit WindowFrameMemory. Geometry is stored
in app-local UserDefaults after moves/resizes, with a 250 ms debounce and
close/quit flushes. A ColorSync display UUID and previous visible bounds support
restoration after display rearrangement. Disconnected or smaller displays use
visible fallback placement. Full-screen/minimized frames are excluded. Arrange
the windows once after installing; later positions and sizes are remembered.

13 ServiceKit tests passed, including six new placement/store tests. Release
app products all built successfully. Isolated committed service sources were
used so unrelated in-progress cache/protocol/compaction work was not shipped;
only dashboard executables are replaced, retaining installed helpers, icons and
metadata. Dependency pins match original package locks. Bundle signatures pass
deep/strict verification. Native Xcode manifest compilation has previously been
blocked by the environment sandbox; SwiftPM native Release builds were used.

Installed after confirmed quit; signatures verified and previous bundles retained. Retriever was moved/resized to 1053 × 829 points on the secondary display and restored that frame after Quit/relaunch. Orchestrator restored its changed 2560 × 1410-point frame after Quit/relaunch, verifying the SwiftUI attachment path. Both saved the same display UUID. All four services relaunched; RA, Data, Orchestrator and Retriever reached Ready. Actual display disconnection remains covered by policy tests rather than a physical monitor test.
