import Darwin
import Foundation
import SwiftUI

/// System-wide physical memory, rather than Harness's process footprint or
/// virtual address space. Compressed memory is its actual RAM footprint.
struct SystemMemorySnapshot: Sendable {
    let total: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let swapUsed: UInt64?
    var used: UInt64 { app + wired + compressed }

    init(total: UInt64, statistics: vm_statistics64_data_t, pageSize: UInt64, swapUsed: UInt64?) {
        self.total = total
        // Purgeable pages are reclaimable; do not count them as app memory.
        app = (UInt64(statistics.internal_page_count) - min(UInt64(statistics.internal_page_count), UInt64(statistics.purgeable_count))) * pageSize
        wired = UInt64(statistics.wire_count) * pageSize
        compressed = UInt64(statistics.compressor_page_count) * pageSize
        self.swapUsed = swapUsed
    }

    static func read() throws -> Self {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else { throw MemoryReadError(code: pageResult) }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw MemoryReadError(code: result) }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return Self(total: ProcessInfo.processInfo.physicalMemory, statistics: statistics,
                    pageSize: UInt64(pageSize), swapUsed: swapResult == 0 ? swap.xsu_used : nil)
    }

    private struct MemoryReadError: LocalizedError {
        let code: kern_return_t
        var errorDescription: String? { "System memory unavailable (Mach error \(code))." }
    }
}

/// Empirical loading estimates for the 397B model. GB uses decimal bytes,
/// matching the requested 217 GB endpoints.
struct ModelLoadMemoryProgress {
    static let loadingTarget: UInt64 = 217_000_000_000
    static let wiringTarget: UInt64 = 217_000_000_000
    let startingUsed: UInt64?

    static func applies(to directory: URL) -> Bool {
        directory.lastPathComponent.range(of: #"(?i)(?<![0-9])397B(?![0-9])"#, options: .regularExpression) != nil
    }
    func loadedBytes(used: UInt64) -> UInt64? {
        startingUsed.map { used > $0 ? used - $0 : 0 }
    }
    static func fraction(_ bytes: UInt64, target: UInt64) -> Double {
        min(1, Double(bytes) / Double(target))
    }
}

struct SystemMemoryView: View {
    var loadingProgress: ModelLoadMemoryProgress? = nil
    @State private var snapshot: SystemMemorySnapshot?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let snapshot {
                if let loadingProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        memoryBar("Loading Into Memory", bytes: loadingProgress.loadedBytes(used: snapshot.used), target: ModelLoadMemoryProgress.loadingTarget)
                        memoryBar("Wiring", bytes: snapshot.wired, target: ModelLoadMemoryProgress.wiringTarget)
                    }
                    .padding(.bottom, 5)
                    .help("Memory-based estimates, updated once a second. Loading Into Memory measures the increase in total system memory used since loading began, up to 217 GB. Wiring measures total system wired memory from zero to 217 GB. Other applications can affect these readings.")
                }
                Text("System memory: \(gib(snapshot.used)) / \(gib(snapshot.total)) GiB used")
                Text("App: \(gib(snapshot.app)) GiB")
                Text("Wired: \(gib(snapshot.wired)) GiB")
                Text("Compressed: \(gib(snapshot.compressed)) GiB")
                Text("Swap used: " + (snapshot.swapUsed.map { gib($0) + " GiB" } ?? "Unavailable"))
            } else {
                Text(failure ?? "Reading system memory…")
            }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .textSelection(.enabled)
        .help("Entire Mac, updated once a second. Used is an estimate of app + wired + physically compressed memory; reclaimable file cache is excluded. Swap is separate. Values may differ slightly from Activity Monitor.")
        .task {
            // SwiftUI cancels this task when the loading readout leaves the view.
            while !Task.isCancelled {
                do { snapshot = try SystemMemorySnapshot.read(); failure = nil }
                catch { snapshot = nil; failure = error.localizedDescription }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    private func gib(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
    }

    private func memoryBar(_ title: String, bytes: UInt64?, target: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if let bytes {
                    let fraction = ModelLoadMemoryProgress.fraction(bytes, target: target)
                    Text("\((Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)))) / \(target / 1_000_000_000) GB · \(Int(fraction * 100))%")
                } else {
                    Text("Starting memory unavailable")
                }
            }
            ProgressView(value: bytes.map { ModelLoadMemoryProgress.fraction($0, target: target) } ?? 0)
                .progressViewStyle(.linear)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: 420)
    }
}
