# Data / Retriever integration validation

Release builds completed for Data 20261030.3, Decomposer 20261030.5,
Retriever 20261030.4 and RemoteAgent 20261030.1. Staged native bundles and
embedded helpers are signed and pass strict signature verification.

65 Data tests, 27 affected Decomposer app tests, 31 Retriever tests and 4
shared cache-retention tests passed. Fixture coverage includes authenticated
HTTP, archive reuse, remote-first retrieval, lost start replies, reconnect/restart,
exact pending-write recovery, partial COCA handoff and local fallback.
No paid-site retrieval or real-model generation was performed as an automatic test.
Native Xcode manifest compilation was blocked by the coding sandbox; release
products were built using SwiftPM's native build system and packaged with native
app metadata, icons and resources. Builds do not prove live site reliability.

RA's retained-cache ceiling is now min(32 GiB, physical RAM/8), yielding 32 GiB
on the 256 GiB Studio. Existing admission and headroom reclamation remain enabled.
Installation is pending coordinated quit. First model requests after RA restart
will be cold; cache retention remains subject to actual memory headroom.
