# Startup recovery — 20261031.1

All four services use ServiceKit StartupRecovery for startup failures. Retries
continue without an attempt limit, at 5, 10, 20, 40 and then 60 seconds. There is
one owned startup task per dashboard; repeated view/launch tasks cannot create
parallel listeners or model loads. Stop cancels retries, and an in-progress attempt
must finish cleanup before a new one can start. Errors, attempt count and delay
remain visible. Existing autostart opt-outs (and RA --no-autoload) still apply.

RA waits for actual model configuration/readiness, including asynchronous worker
load errors and its existing ten-minute load deadline. Failed listeners/workers
are stopped before retry. Data waits for its helper's health response; a live
recoveryRequired response preserves pending transactions for exact recovery and
is not a reason to restart the storage service. Orchestrator retries unavailable
Data identity/bootstrap checks using the configured project binding; it never
silently accepts another project. Retriever retries store/listener initialization
but does not automatically replay interrupted paid-site captures.

This retries startup, not accepted inference, retrieval, writes or runtime job
errors. It does not relaunch an app after the application process itself exits,
configure macOS Login Items, bypass FileVault/login or unlock Keychain. Existing
reboot/login launch configuration remains necessary.

Validation: 7 ServiceKit tests, 6 RA fake-worker/service tests, 65 Data tests,
39 Orchestrator tests and 32 Retriever tests passed (149 total). Coverage includes
unlimited capped retries, duplicate-start coalescing, Stop during delay/attempt,
cleanup before restart, live helper exit/reaping, Retriever invalid-port failure
and asynchronous RA model-load failure. No real inference or paid-site capture
was used as a fixture. Native project plists parse; native Xcode build remains
blocked during package-manifest resolution by sandbox_apply permission denial.
Release binaries are built with SwiftPM native build system and packaged with
native metadata/resources. Builds are not proof of unattended outage recovery.

Deployment: installed after confirmed quit; installed versions and strict code
signatures verified. All four services reached Ready. Orchestrator was started
while Data was absent, retried through four failures, and automatically became
Ready after Data started, without another Start click. Data saving remained
enabled; authenticated Retriever health was Ready. RA loaded the remembered
122B model and retained the 32 GB cache ceiling. No real inference, paid-site
retrieval or project content edits were invoked. Full power-cycle testing remains
a separate acceptance check.
