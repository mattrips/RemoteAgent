import AppKit
import SwiftUI
import Observation
import RemoteAgentService
import HarnessCore
import Darwin

private struct DashboardMetric: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor @Observable final class RemoteWorkspace {
    var path = UserDefaults.standard.string(forKey: "modelPath") ?? (NSHomeDirectory() + "/Documents/Models/Qwen3.5-397B-A17B-4bit")
    var status = "Stopped"
    var notice = ""
    var running = false
    var starting = false
    let worker = WorkerBridge()
    var server: HTTPServer?
    var token: String?
    var activeBytes = 0
    var cacheBytes = 0
    var cacheCount = 0
    var sessions = 0
    var sessionList: [RemoteSessionInfo] = []
    var activeSessionID: UUID?
    var queuedSessions: [UUID: Int] = [:]
    var sessionEvents: [String] = []
    var activityRecords: [RemoteActivityRecord] = []
    var sessionToClose: RemoteSessionInfo?
    var closingSession = false
    var backgroundPath = UserDefaults.standard.string(forKey: "backgroundPath") ?? BackgroundPublication.defaultDirectory.path
    private var lastSessionRefresh = Date.distantPast
    var queued = 0
    var inputTokens = 0
    var reusedTokens = 0
    var generatedTokens = 0
    var prefillCompletedTokens: Int?
    var prefillTotalTokens: Int?
    var rate = "—"
    var rateIsLive = false
    var prefill = "—"
    var phase = "Idle"
    var requestActive = false
    var elapsed = "0:00"
    var loadStarted: Date?
    var loadingMemoryProgress: ModelLoadMemoryProgress?
    var errors: [String] = []
    var wired = 0
    var compressed = 0
    var available = 0
    var testing = false
    var automaticTestStarted = false
    private var startupHandled = false
    static func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
    func poll() async {
        if Date().timeIntervalSince(lastSessionRefresh) > 10 {
            lastSessionRefresh = Date(); await server?.refreshSessionsIfIdle()
        }
        status = await worker.status; activeBytes = await worker.activeBytes; cacheBytes = await worker.cacheBytes; cacheCount = await worker.cacheCount; sessions = await worker.sessionCount
        sessionList = await worker.sessions; activeSessionID = await worker.activeSessionID
        sessionEvents = await worker.sessionEvents
        activityRecords = await worker.activityRecords
        queuedSessions = await server?.queuedSessions() ?? [:]
        inputTokens = await worker.inputTokens; reusedTokens = await worker.reusedTokens; generatedTokens = await worker.generatedTokens; errors = await worker.recentErrors
        prefillCompletedTokens = await worker.prefillCompletedTokens; prefillTotalTokens = await worker.prefillTotalTokens
        queued = await server?.queueCount() ?? 0
        if let usage = await worker.lastUsage { rate = usage.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—"; prefill = usage.promptSeconds.map { String(format: "%.2f s", $0) } ?? "—" }
        let active = await worker.requestStartedAt
        let outcome = await worker.lastRequestOutcome
        requestActive = active != nil
        rateIsLive = active != nil && generatedTokens > 0
        if rateIsLive {
            if let speed = await worker.liveTokensPerSecond() { rate = String(format: "%.1f tok/s", speed) }
            else { rate = "Measuring…" }
        }
        phase = loadStarted != nil ? "Loading model" : (active == nil ? (outcome ?? "Idle") : (outcome == "Cancelling" ? "Cancelling" : (generatedTokens > 0 ? "Decoding" : "Processing prompt")))
        if await worker.configuration != nil || status.hasPrefix("Worker ") || status.contains("timed out") {
            loadStarted = nil; loadingMemoryProgress = nil
        }
        if let start = active ?? loadStarted { let seconds = Int(Date().timeIntervalSince(start)); elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60) }
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64_data_t(), page: vm_size_t = 0
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        if host_page_size(host, &page) == KERN_SUCCESS {
            let code = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: capacity) { host_statistics64(host, HOST_VM_INFO64, $0, &count) } }
            if code == KERN_SUCCESS { wired = Int(stats.wire_count) * Int(page); compressed = Int(stats.compressor_page_count) * Int(page); available = (Int(stats.free_count) + Int(stats.inactive_count)) * Int(page) }
        }
    }
    func choose() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { path = url.path } }
    func startOnLaunch() {
        // SwiftUI may recreate a view task or open another window. Neither that,
        // nor a manual Stop, should trigger another automatic load.
        guard !startupHandled else { return }
        startupHandled = true
        if let flag = CommandLine.arguments.firstIndex(of: "--load-model"), CommandLine.arguments.indices.contains(flag + 1) {
            path = CommandLine.arguments[flag + 1]
        }
        if !CommandLine.arguments.contains("--no-autoload") { start() }
    }
    func start() {
        guard !starting, !running else { return }; starting = true
        loadingMemoryProgress = ModelLoadMemoryProgress.applies(to: URL(fileURLWithPath: path))
            ? .init(startingUsed: (try? SystemMemorySnapshot.read())?.used) : nil
        Task {
            do {
                let modelURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("config.json").path) else {
                    throw HarnessError.state("Model directory is unavailable or missing config.json. Choose a local model directory, then load again.")
                }
                let key = try Credentials.loadOrCreate(); token = key
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RemoteAgentWorker")
                let adjacent = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("RemoteAgentWorker")
                let helper = FileManager.default.isExecutableFile(atPath: executable.path) ? executable : adjacent
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw HarnessError.state("RemoteAgentWorker helper is missing. Build the RemoteAgent Xcode scheme, which embeds its worker.") }
                let service = HTTPServer(worker: worker, secret: key, backgroundDirectory: URL(fileURLWithPath: (backgroundPath as NSString).expandingTildeInPath))
                try await service.start()
                do { try await worker.start(executable: helper, model: modelURL) }
                catch { await service.stop(); throw error }
                server = service; running = true; loadStarted = Date(); UserDefaults.standard.set(path, forKey: "modelPath")
                notice = ""
            } catch { await worker.recordServiceError("startup_failed"); status = "Needs attention"; notice = error.localizedDescription; loadingMemoryProgress = nil; loadStarted = nil }
            starting = false
        }
    }
    func stop() {
        starting = true
        Task { await worker.stop(); await server?.stop(); server = nil; running = false; starting = false; status = "Stopped"; loadStarted = nil; loadingMemoryProgress = nil }
    }
    func copyToken() { guard let token else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string); notice = "Access token copied. Paste it into Decomposer Settings → RemoteAgent." }
    func closeSelectedSession() {
        guard let session = sessionToClose, !closingSession else { return }
        sessionToClose = nil; closingSession = true
        Task {
            defer { closingSession = false }
            do { try await server?.closeIdleSession(session.id); notice = "Closed session " + session.id.uuidString.prefix(8); await poll() }
            catch { notice = error.localizedDescription }
        }
    }
    func runChecks(reportURL: URL) {
        guard !testing, let token else { return }
        testing = true; notice = "Running local inference and cache checks…"
        Task {
            do { notice = try await LocalSelfTest.run(key: token, reportURL: reportURL) + " Report: " + reportURL.path }
            catch { notice = "Local checks failed: " + error.localizedDescription }
            testing = false
        }
    }
    func chooseCheckReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RemoteAgent-local-checks.json"
        if panel.runModal() == .OK, let url = panel.url { runChecks(reportURL: url) }
    }
    func enableTailscale() {
        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
        notice = "Install/sign in to Tailscale on both Macs. Then run: tailscale serve --bg http://127.0.0.1:8321. Use its HTTPS URL in Decomposer. Do not use Funnel."
    }
}

@main struct RemoteAgentApp: App {
    @State private var workspace = RemoteWorkspace()
    @State private var selectedTab = "Status"
    var body: some Scene {
        WindowGroup("RemoteAgent") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("RemoteAgent", systemImage: "server.rack").font(.largeTitle.bold())
                    Spacer()
                    Text(workspace.status).font(.headline).textSelection(.enabled)
                    if workspace.running {
                        Button("Stop and unload") { workspace.stop() }.disabled(workspace.starting)
                    } else {
                        Button(workspace.starting ? "Starting…" : "Load model and start") { workspace.start() }.disabled(workspace.starting)
                    }
                }
                Text(URL(fileURLWithPath: workspace.path).lastPathComponent).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                Picker("View", selection: $selectedTab) {
                    Text("Status").tag("Status")
                    Text("Log").tag("Log")
                    Text("Settings").tag("Settings")
                }.pickerStyle(.segmented)
                if !workspace.notice.isEmpty {
                    Text(workspace.notice).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if selectedTab == "Status" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                if workspace.loadStarted != nil {
                    SystemMemoryView(loadingProgress: workspace.loadingMemoryProgress)
                }
                if workspace.phase == "Processing prompt", let done = workspace.prefillCompletedTokens, let total = workspace.prefillTotalTokens {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(total == 0 ? "Prompt fully cached" : "Processing \(done.formatted()) of \(total.formatted()) new tokens")
                            .monospacedDigit()
                        if total > 0 { ProgressView(value: Double(min(done, total)), total: Double(total)) }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Memory") {
                        VStack(alignment: .leading, spacing: 6) {
                            DashboardMetric("MLX active", value: RemoteWorkspace.bytes(workspace.activeBytes))
                            DashboardMetric("System wired", value: RemoteWorkspace.bytes(workspace.wired))
                            DashboardMetric("Compressed", value: RemoteWorkspace.bytes(workspace.compressed))
                            DashboardMetric("Reclaimable", value: RemoteWorkspace.bytes(workspace.available))
                            DashboardMetric("Cache states", value: RemoteWorkspace.bytes(workspace.cacheBytes) + " / " + RemoteWorkspace.bytes(RemoteAgentLimits.snapshotMemoryBudget(physicalBytes: ProcessInfo.processInfo.physicalMemory)))
                                .help("Retained-state memory / budget. Conservative sum of arrays; shared storage may be counted more than once. System headroom may require earlier eviction.")
                        }.monospacedDigit().frame(minWidth: 200)
                    }
                    GroupBox("Inference") {
                        VStack(alignment: .leading, spacing: 6) {
                            DashboardMetric("Stage", value: workspace.phase)
                            DashboardMetric("Elapsed", value: workspace.elapsed)
                            DashboardMetric("Prompt", value: workspace.inputTokens.formatted())
                            DashboardMetric("Reused", value: workspace.reusedTokens.formatted())
                            DashboardMetric("Generated", value: workspace.generatedTokens.formatted())
                            DashboardMetric(workspace.rateIsLive ? "Speed (live)" : "Last speed", value: workspace.rate)
                                .help("During generation: average tokens per second since the first streamed token, excluding prompt processing. After completion: the worker’s final generation rate.")
                        }.monospacedDigit().frame(minWidth: 200)
                    }
                    GroupBox("Service") {
                        VStack(alignment: .leading, spacing: 6) {
                            DashboardMetric("Waiting", value: "\(workspace.queued) / 4")
                            DashboardMetric("Allocated", value: "\(workspace.sessions) / 16")
                            DashboardMetric("Active", value: workspace.activeSessionID == nil ? "0" : "1")
                            DashboardMetric("Snapshots", value: workspace.cacheCount.formatted())
                                .help("Retention is governed primarily by the cache memory budget; a high metadata ceiling is a secondary safeguard.")
                            DashboardMetric("Last prefill", value: workspace.prefill)
                        }.monospacedDigit().frame(minWidth: 200)
                    }
                }
                DisclosureGroup("Client sessions (\(workspace.sessionList.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Idle sessions stay open below ten allocated sessions. At ten or more, sessions idle for an hour may expire. Cache snapshots have their own memory budget.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(workspace.sessionList) { session in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.clientName + (session.deviceName.map { " · " + $0 } ?? "")).font(.headline)
                                    Text(session.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                                    Text("Created " + session.createdAt.formatted(date: .abbreviated, time: .shortened) + " · Last activity " + session.lastActivity.formatted(date: .omitted, time: .standard)).font(.caption)
                                    Text("\(session.cacheCount) snapshots · " + RemoteWorkspace.bytes(session.cacheBytes)).font(.caption)
                                }
                                Spacer()
                                Text(workspace.activeSessionID == session.id ? "Active" : workspace.queuedSessions[session.id] != nil ? "Queued" : "Idle")
                                Button("Close session…") { workspace.sessionToClose = session }
                                    .disabled(workspace.activeSessionID == session.id || workspace.queuedSessions[session.id] != nil || workspace.closingSession)
                            }
                            Divider()
                        }
                        if workspace.sessionList.isEmpty { Text("No allocated sessions").foregroundStyle(.secondary) }
                        ForEach(Array(workspace.sessionEvents.enumerated()), id: \.offset) { _, event in Text(event).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.top, 8)
                }
                if !workspace.errors.isEmpty { DisclosureGroup("Recent errors") { ScrollView { Text(workspace.errors.joined(separator: "\n\n")).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120) } }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if selectedTab == "Log" {
                    RemoteActivityView(workspace: workspace)
                } else {
                    ScrollView {
                GroupBox("Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField("Local model directory", text: $workspace.path)
                            Button("Choose…") { workspace.choose() }
                        }.disabled(workspace.running || workspace.starting)
                        TextField("Background Prompt folder", text: $workspace.backgroundPath)
                            .disabled(workspace.running || workspace.starting)
                            .onChange(of: workspace.backgroundPath) { _, path in UserDefaults.standard.set(path, forKey: "backgroundPath") }
                        LabeledContent("Local endpoint") { Text("http://127.0.0.1:8321").textSelection(.enabled) }
                        HStack {
                            Button("Copy access token") { workspace.copyToken() }.disabled(workspace.token == nil)
                            Button(workspace.testing ? "Checking…" : "Run local checks…") { workspace.chooseCheckReport() }
                                .disabled(workspace.testing || workspace.status != "Ready" || workspace.requestActive)
                        }
                        DisclosureGroup("Private remote access") {
                            VStack(alignment: .leading, spacing: 8) {
                                Button("Tailscale setup…") { workspace.enableTailscale() }
                                Text("Use Tailscale Serve HTTPS and the access token for remote connections. The local service listens on 127.0.0.1 only.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                        }
                    }.padding(.top, 10)
                }
                    }
                }
            }.padding(24).frame(minWidth: 820, minHeight: 480)
            .confirmationDialog("Close this session and release its caches?", isPresented: Binding(get: { workspace.sessionToClose != nil }, set: { if !$0 { workspace.sessionToClose = nil } })) {
                Button("Close session", role: .destructive) { workspace.closeSelectedSession() }
            } message: { Text("The client must create a new session when it next connects. Saved conversations and project files are not deleted.") }
            .task {
                workspace.startOnLaunch()
                while !Task.isCancelled {
                    await workspace.poll()
                    if !workspace.automaticTestStarted, workspace.status == "Ready",
                       let flag = CommandLine.arguments.firstIndex(of: "--self-test-report"), CommandLine.arguments.indices.contains(flag + 1) {
                        workspace.automaticTestStarted = true
                        workspace.runChecks(reportURL: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .defaultSize(width: 900, height: 560)
    }
}

struct RemoteActivityView: View {
    @Bindable var workspace: RemoteWorkspace
    @State private var category = "All"
    @State private var query = ""
    @State private var selection: UUID?
    private var rows: [RemoteActivityRecord] {
        workspace.activityRecords.reversed().filter { row in
            (category == "All" || row.category == category) && (query.isEmpty || [row.client, row.operation, row.status, row.requestID?.uuidString ?? "", row.sessionID?.uuidString ?? "", row.errorCode ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Show", selection: $category) {
                    ForEach(["All", "Request", "Connection", "Error", "Service"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 220)
                TextField("Filter client, operation, ID or error code", text: $query)
                Button("Clear completed entries") { Task { await workspace.worker.clearActivity(); await workspace.poll() } }
            }
            Text("Latest 1,000 operational entries, kept only while this app is open. Client sessions are logical connections; routine HTTP/status polling is omitted. Prompt text, output and access tokens are not logged.").font(.caption).foregroundStyle(.secondary)
            Table(rows, selection: $selection) {
                TableColumn("Time") { row in Text(row.time.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(85)
                TableColumn("Type", value: \.category).width(85)
                TableColumn("Client", value: \.client)
                TableColumn("Operation", value: \.operation)
                TableColumn("Status", value: \.status).width(100)
            }.frame(minHeight: 220)
            if let row = workspace.activityRecords.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 4) {
                    if let id = row.requestID { Text("Request: " + id.uuidString).font(.caption.monospaced()) }
                    if let id = row.sessionID { Text("Session: " + id.uuidString).font(.caption.monospaced()) }
                    if let start = row.startedAt { Text("Execution: " + String(format: "%.2f s", max(0, (row.endedAt ?? Date()).timeIntervalSince(start)))).monospacedDigit() }
                    if let input = row.inputTokens { Text("Prompt: \(input) · reused: \(row.reusedTokens.map(String.init) ?? "—") · generated: \(row.generatedTokens.map(String.init) ?? "—")").monospacedDigit() }
                    if let code = row.errorCode { Text("Error: " + code).foregroundStyle(.orange) }
                    if !row.detail.isEmpty { Text(row.detail) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
