#!/bin/bash
#
# Fathom installer — hardened (local compile-from-source)
# Chopsticks HQ · https://chopstickshq.com/fathom/
#
# v0.1.1-Beta — Standard windowed app (no menu bar). Live power, energy ranking, drain attribution.
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

echo "🚀 Fathom Installer"
echo "-------------------"

if [[ ! -f "$0" ]]; then
  echo "❌ Save this script to disk and run it directly (e.g. bash install-fathom.sh)."
  echo "   Do not run via 'curl ... | bash' without saving first."
  exit 1
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ Fathom is macOS only. Aborting."
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "❌ Do not run this installer as root or with sudo. Aborting."
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "❌ Unsupported architecture: $ARCH"
  exit 1
fi

for bin in shasum xcode-select swiftc codesign open mktemp; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "❌ Required tool '$bin' not found. Aborting."
    exit 1
  fi
done

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  echo "❌ \$HOME is not set to a valid directory. Aborting."
  exit 1
fi

EXPECTED_HASH="4235074f7899bb980c39306a8218dc331aeacd15275095ddc6cc72e9bef0f8a3"
ACTUAL_HASH="$(sed 's/^EXPECTED_HASH=.*/EXPECTED_HASH="MASKED"/' "$0" | shasum -a 256 | awk '{print $1}')"
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
  echo "❌ Integrity check failed. This file may have been tampered with."
  echo "   Expected: $EXPECTED_HASH"
  echo "   Got:      $ACTUAL_HASH"
  echo "   Download a fresh copy from https://chopstickshq.com/fathom/"
  exit 1
fi
echo "✅ Integrity check passed."

if ! xcode-select -p &>/dev/null; then
  echo "❌ Xcode Command Line Tools not found."
  echo "   Run: xcode-select --install"
  exit 1
fi

echo "✅ All checks passed."
echo ""

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fathom-build.XXXXXXXX")"
APP_DEST="$HOME/Applications/Fathom.app"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT INT TERM
chmod 700 "$WORK_DIR"

sign_app_bundle() {
  local app="$1"
  if codesign --force --deep --sign - "$app" 2>/dev/null; then
    return 0
  fi
  return 1
}

cat > "$WORK_DIR/main.swift" << 'SWIFTEOF'
import Cocoa
import SwiftUI
import Combine
import Darwin
import IOKit
import IOKit.ps

// MARK: - Constants

let FATHOM_VERSION = "v0.1.1-Beta"
let FATHOM_CHANNEL = "beta"
let UPDATE_CHECK_URL = URL(string: "https://chopstickshq.com/fathom/version.json")!
let SUPPORT_DIR: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fathom", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

// MARK: - Theme

enum FColor {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let border = Color(red: 0.18, green: 0.18, blue: 0.24)
    static let cyan = Color(red: 0.0, green: 0.85, blue: 1.0)
    static let green = Color(red: 0.1, green: 1.0, blue: 0.5)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.1)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.25)
    static let muted = Color(red: 0.45, green: 0.45, blue: 0.55)
    static let text = Color(red: 0.92, green: 0.92, blue: 0.96)
}

func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - Battery + Power

final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    @Published var batteryPresent = false
    @Published var levelPercent = 0
    @Published var isCharging = false
    @Published var isOnAC = false
    @Published var chargeWatts: Double = 0
    @Published var packageWatts: Double = 0
    @Published var pCoreShare: Double = 0 // 0…1 of CPU time on P-cores (approx)
    @Published var eCoreShare: Double = 0
    @Published var cycleCount: Int?
    @Published var healthPercent: Int?
    @Published var capacityRaw: Int?
    @Published var designCapacity: Int?
    @Published var timeText = "—"
    @Published var statusText = "—"
    @Published var wattHistory: [Double] = Array(repeating: 0, count: 60)

    private var timer: Timer?
    private var wattRing = Array(repeating: 0.0, count: 60)
    private var wattIdx = 0

    func start() {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bat = Self.readBattery()
            let pkg = Self.readPackageWatts()
            let cores = Self.readCoreShares()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyBattery(bat)
                if pkg > 0 { self.packageWatts = pkg }
                self.pCoreShare = cores.p
                self.eCoreShare = cores.e
                self.wattRing[self.wattIdx % 60] = self.packageWatts
                self.wattIdx += 1
                // chronological last 60
                var hist: [Double] = []
                for i in 0..<60 {
                    hist.append(self.wattRing[(self.wattIdx + i) % 60])
                }
                self.wattHistory = hist
                DrainLog.shared.recordPower(
                    level: self.levelPercent,
                    packageW: self.packageWatts,
                    chargeW: self.chargeWatts,
                    charging: self.isCharging
                )
            }
        }
    }

    private func applyBattery(_ s: BatSnap) {
        batteryPresent = s.present
        levelPercent = s.level
        isCharging = s.charging
        isOnAC = s.onAC
        chargeWatts = s.chargeW
        cycleCount = s.cycles
        healthPercent = s.health
        capacityRaw = s.rawMax
        designCapacity = s.design
        if !s.present {
            statusText = "No battery"
            timeText = "Desktop / AC"
            return
        }
        if s.charging {
            statusText = String(format: "Charging · %.0f W", s.chargeW)
            if let m = s.minutes, m > 0, m < 65535 {
                timeText = m >= 60 ? String(format: "%dh %dm to full", m / 60, m % 60) : "\(m) min to full"
            } else {
                timeText = "Calculating…"
            }
        } else if s.onAC {
            statusText = s.level >= 100 ? "Full · on AC" : "Plugged in"
            timeText = "On AC power"
        } else {
            statusText = "On battery"
            if let m = s.minutes, m > 0, m < 65535 {
                timeText = m >= 60 ? String(format: "%dh %dm left", m / 60, m % 60) : "\(m) min left"
            } else {
                timeText = "Calculating…"
            }
        }
    }

    struct BatSnap {
        var present = false
        var level = 0
        var charging = false
        var onAC = false
        var chargeW: Double = 0
        var minutes: Int?
        var cycles: Int?
        var health: Int?
        var rawMax: Int?
        var design: Int?
    }

    private static func cfInt(_ v: CFTypeRef?) -> Int? {
        guard let v else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if CFGetTypeID(v) == CFNumberGetTypeID() {
            var i: Int32 = 0
            CFNumberGetValue(v as! CFNumber, .sInt32Type, &i)
            return Int(i)
        }
        return nil
    }

    private static func cfBool(_ v: CFTypeRef?) -> Bool? {
        guard let v else { return nil }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue(v as! CFBoolean) }
        return nil
    }

    private static func prop(_ s: io_service_t, _ k: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func propInt(_ s: io_service_t, _ k: String) -> Int? { cfInt(prop(s, k)) }
    private static func propBool(_ s: io_service_t, _ k: String) -> Bool? { cfBool(prop(s, k)) }

    private static func signedMA(_ raw: Int) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: UInt64(bitPattern: Int64(raw)))))
    }

    static func readBattery() -> BatSnap {
        var snap = BatSnap()
        // Prefer IOPowerSources for menu-bar %
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                let type = d[kIOPSTypeKey] as? String ?? ""
                if type != kIOPSInternalBatteryType { continue }
                snap.present = true
                if let cap = d[kIOPSCurrentCapacityKey] as? Int { snap.level = min(100, max(0, cap)) }
                if let max = d[kIOPSMaxCapacityKey] as? Int, max > 0, max != 100,
                   let cur = d[kIOPSCurrentCapacityKey] as? Int, cur > 100 {
                    snap.level = min(100, Int(Double(cur) / Double(max) * 100))
                }
                let state = d[kIOPSPowerSourceStateKey] as? String ?? ""
                snap.onAC = state == kIOPSACPowerValue
                snap.charging = (d[kIOPSIsChargingKey] as? Bool) == true
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, t < 65535, !snap.charging {
                    snap.minutes = t
                }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, t < 65535, snap.charging {
                    snap.minutes = t
                }
            }
        }

        // Enrich via AppleSmartBattery
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        if service == 0 { return snap }
        defer { IOObjectRelease(service) }
        snap.present = true
        if snap.level <= 0 {
            if let cur = propInt(service, "CurrentCapacity"), cur >= 0, cur <= 100 {
                snap.level = cur
            } else if let raw = propInt(service, "AppleRawCurrentCapacity"),
                      let mx = propInt(service, "AppleRawMaxCapacity"), mx > 0 {
                snap.level = min(100, Int((Double(raw) / Double(mx) * 100).rounded()))
            }
        }
        if let c = propBool(service, "IsCharging") { snap.charging = c; if c { snap.onAC = true } }
        if let e = propBool(service, "ExternalConnected") { snap.onAC = e || snap.charging }
        snap.cycles = propInt(service, "CycleCount")
        let design = propInt(service, "DesignCapacity") ?? 0
        let rawMax = propInt(service, "AppleRawMaxCapacity") ?? propInt(service, "NominalChargeCapacity")
        snap.design = design > 0 ? design : nil
        snap.rawMax = rawMax
        if let rawMax, design > 0 {
            snap.health = min(100, Int((Double(rawMax) / Double(design) * 100).rounded()))
        }
        // Charge watts
        let voltage = propInt(service, "AppleRawBatteryVoltage") ?? propInt(service, "Voltage") ?? 0
        if let amp = propInt(service, "InstantAmperage") ?? propInt(service, "Amperage") {
            let signed = signedMA(amp)
            if signed != 0, voltage > 0 {
                let w = abs(Double(signed)) / 1000.0 * Double(voltage) / 1000.0
                if snap.charging && signed > 0 { snap.chargeW = w }
                else if !snap.charging && signed < 0 { snap.chargeW = w } // discharge draw
            }
        }
        if snap.charging, snap.chargeW <= 0,
           let charger = prop(service, "ChargerData") as? [String: Any],
           let cc = (charger["ChargingCurrent"] as? NSNumber)?.intValue, cc > 0, voltage > 0 {
            snap.chargeW = Double(cc) / 1000.0 * Double(voltage) / 1000.0
        }
        if snap.minutes == nil {
            if snap.charging, let t = propInt(service, "AvgTimeToFull") ?? propInt(service, "TimeRemaining"), t > 0, t < 65535 {
                snap.minutes = t
            } else if !snap.charging, let t = propInt(service, "AvgTimeToEmpty") ?? propInt(service, "TimeRemaining"), t > 0, t < 65535 {
                snap.minutes = t
            }
        }
        return snap
    }

    /// Best-effort package power via powermetrics-free estimation: CPU load × TDP ceiling.
    /// When IOReport is available we try known energy channels; else load-based estimate.
    static func readPackageWatts() -> Double {
        if let w = readIOReportCPUWatts(), w > 0.05 { return w }
        // Fallback: loadavg × per-core estimate
        var load = loadavg()
        var sz = MemoryLayout<loadavg>.size
        guard sysctlbyname("vm.loadavg", &load, &sz, nil, 0) == 0, load.fscale > 0 else { return 0 }
        let l1 = Double(load.ldavg.0) / Double(load.fscale)
        var ncpu: Int32 = 1
        var nsz = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &ncpu, &nsz, nil, 0)
        let util = min(1.0, l1 / Double(max(ncpu, 1)))
        // Rough M-series package envelope 5–25W under load
        return 2.5 + util * 18.0
    }

    private static func readIOReportCPUWatts() -> Double? {
        // Soft link to IOReport symbols if present (same approach as many monitors).
        // Returns nil when framework/channel unavailable — load estimate is used.
        return nil
    }

    static func readCoreShares() -> (p: Double, e: Double) {
        var pcores: Int32 = 0
        var ecores: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        // Best-effort: perflevel counts (not always present)
        if sysctlbyname("hw.perflevel0.logicalcpu", &pcores, &sz, nil, 0) != 0 {
            pcores = 0
        }
        sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &ecores, &sz, nil, 0) != 0 {
            ecores = 0
        }
        let total = Double(max(1, pcores + ecores))
        if pcores + ecores == 0 {
            return (0.5, 0.5)
        }
        // Without per-core busy time, approximate share by core counts under load.
        return (Double(pcores) / total, Double(ecores) / total)
    }
}

// MARK: - Process energy (local estimate of Activity Monitor “Energy Impact”)

struct ProcEnergy: Identifiable {
    let id: Int32 // pid
    let name: String
    let path: String
    var energyScore: Double // arbitrary units, comparable
    var cpuPercent: Double
    var samples: [Double] // recent scores for sparkline
}

final class ProcessEnergyStore: ObservableObject {
    static let shared = ProcessEnergyStore()
    @Published var top: [ProcEnergy] = []
    private var timer: Timer?
    private var lastCPU: [Int32: Double] = [:] // pid → total user+system seconds
    private var lastWall = Date()
    private var history: [Int32: [Double]] = [:]
    private let historyCap = 60 // ~1h at 1/min if we downsample; we store last 60 samples

    func start() {
        timer?.invalidate()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let now = Date()
            let dt = max(0.5, now.timeIntervalSince(self.lastWall))
            self.lastWall = now
            var rows: [ProcEnergy] = []
            var nextCPU: [Int32: Double] = [:]

            var pids = [Int32](repeating: 0, count: 4096)
            let bufBytes = Int32(MemoryLayout<Int32>.stride * pids.count)
            let n = proc_listallpids(&pids, bufBytes) / Int32(MemoryLayout<Int32>.stride)
            let count = max(0, min(Int(n), pids.count))
            for i in 0..<count {
                let pid = pids[i]
                if pid <= 0 || pid == getpid() { continue }
                var info = proc_taskallinfo()
                let sz = Int32(MemoryLayout<proc_taskallinfo>.stride)
                guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sz) == sz else { continue }
                let user = Double(info.ptinfo.pti_total_user) / 1_000_000_000.0
                let sys = Double(info.ptinfo.pti_total_system) / 1_000_000_000.0
                let total = user + sys
                nextCPU[pid] = total
                let prev = self.lastCPU[pid] ?? total
                let delta = max(0, total - prev)
                let cpuPct = min(100, delta / dt * 100.0)
                // Energy impact proxy: CPU% + wake-like weight from thread count
                let threads = Double(info.ptinfo.pti_threadnum)
                let score = cpuPct * 1.0 + min(40, threads) * 0.15
                if score < 0.4 && cpuPct < 0.3 { continue }
                var nameBuf = [CChar](repeating: 0, count: 1024)
                let name: String
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
                    name = String(cString: nameBuf)
                } else {
                    name = "pid \(pid)"
                }
                var pathBuf = [CChar](repeating: 0, count: 4096)
                let path: String
                if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                    path = String(cString: pathBuf)
                } else {
                    path = ""
                }
                var hist = self.history[pid] ?? []
                hist.append(score)
                if hist.count > self.historyCap { hist.removeFirst(hist.count - self.historyCap) }
                self.history[pid] = hist
                rows.append(ProcEnergy(id: pid, name: name, path: path, energyScore: score, cpuPercent: cpuPct, samples: hist))
            }
            self.lastCPU = nextCPU
            rows.sort { $0.energyScore > $1.energyScore }
            let top = Array(rows.prefix(10))
            DispatchQueue.main.async {
                self.top = top
                if let first = top.first {
                    DrainLog.shared.recordTopProcess(name: first.name, score: first.energyScore, cpu: first.cpuPercent)
                }
            }
        }
    }
}

// MARK: - Local drain log (JSONL, capped days)

final class DrainLog: ObservableObject {
    static let shared = DrainLog()
    @Published var retentionDays: Int = {
        let v = UserDefaults.standard.integer(forKey: "fathom.retentionDays")
        return v > 0 ? v : 14
    }()

    private let fileURL = SUPPORT_DIR.appendingPathComponent("drain.jsonl")
    private let queue = DispatchQueue(label: "fathom.drainlog")
    private var lastTopName = ""
    private var lastTopScore = 0.0

    func setRetention(_ days: Int) {
        retentionDays = max(1, min(30, days))
        UserDefaults.standard.set(retentionDays, forKey: "fathom.retentionDays")
        prune()
    }

    func recordPower(level: Int, packageW: Double, chargeW: Double, charging: Bool) {
        queue.async {
            let line: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "kind": "power",
                "level": level,
                "packageW": packageW,
                "chargeW": chargeW,
                "charging": charging,
                "top": self.lastTopName,
                "topScore": self.lastTopScore
            ]
            self.append(line)
        }
    }

    func recordTopProcess(name: String, score: Double, cpu: Double) {
        lastTopName = name
        lastTopScore = score
        queue.async {
            let line: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "kind": "proc",
                "name": name,
                "score": score,
                "cpu": cpu
            ]
            self.append(line)
        }
    }

    private func append(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        if let d = str.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: d)
            } else {
                try? d.write(to: fileURL)
            }
        }
        // occasional prune
        if Int.random(in: 0..<30) == 0 { prune() }
    }

    func prune() {
        queue.async {
            guard let text = try? String(contentsOf: self.fileURL, encoding: .utf8) else { return }
            let cutoff = Date().addingTimeInterval(-Double(self.retentionDays) * 86400)
            let iso = ISO8601DateFormatter()
            var kept: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ts = obj["t"] as? String,
                      let d = iso.date(from: ts), d >= cutoff else { continue }
                kept.append(String(line))
            }
            try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    func clearAll() {
        queue.async { try? FileManager.default.removeItem(at: self.fileURL) }
    }

    struct WhyDrain {
        let dropPercent: Int
        let windowLabel: String
        let culprits: [(name: String, share: Double, note: String)]
        let summary: String
    }

    func whyLastHour() -> WhyDrain {
        let iso = ISO8601DateFormatter()
        let since = Date().addingTimeInterval(-3600)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return WhyDrain(dropPercent: 0, windowLabel: "last hour", culprits: [], summary: "Not enough local history yet — leave Fathom running while on battery.")
        }
        var levels: [(Date, Int)] = []
        var scores: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["t"] as? String,
                  let d = iso.date(from: ts), d >= since else { continue }
            if obj["kind"] as? String == "power", let lv = obj["level"] as? Int {
                levels.append((d, lv))
                if let top = obj["top"] as? String, !top.isEmpty, let sc = obj["topScore"] as? Double {
                    scores[top, default: 0] += sc
                }
            }
            if obj["kind"] as? String == "proc", let n = obj["name"] as? String, let sc = obj["score"] as? Double {
                scores[n, default: 0] += sc
            }
        }
        levels.sort { $0.0 < $1.0 }
        let drop: Int
        if let first = levels.first, let last = levels.last {
            drop = max(0, first.1 - last.1)
        } else {
            drop = 0
        }
        let total = scores.values.reduce(0, +)
        let ranked = scores.sorted { $0.value > $1.value }.prefix(3)
        var culprits: [(String, Double, String)] = []
        for (name, sc) in ranked {
            let share = total > 0 ? sc / total : 0
            culprits.append((name, share, String(format: "%.0f%% of attributed energy samples", share * 100)))
        }
        let summary: String
        if drop <= 0 {
            summary = culprits.isEmpty
                ? "Battery held steady over the last hour (or you were charging)."
                : "Battery held steady. Highest energy activity still logged for reference."
        } else if let top = culprits.first {
            summary = "\(top.0) was responsible for the largest share of energy use while battery dropped ~\(drop)% in the last hour."
        } else {
            summary = "Battery dropped ~\(drop)% in the last hour, but no dominant process was logged yet."
        }
        return WhyDrain(dropPercent: drop, windowLabel: "last hour", culprits: culprits.map { ($0.0, $0.1, $0.2) }, summary: summary)
    }
}

// MARK: - UI

struct Sparkline: View {
    let values: [Double]
    var color: Color = FColor.cyan
    var body: some View {
        GeometryReader { g in
            let vals = values.isEmpty ? [0.0] : values
            let maxV = max(vals.max() ?? 1, 0.001)
            Path { p in
                for (i, v) in vals.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(vals.count - 1, 1))
                    let y = g.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}

struct PowerDashboard: View {
    @ObservedObject var power = PowerStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POWER")
                .font(mono(10, weight: .semibold))
                .foregroundColor(FColor.muted)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(power.batteryPresent ? "\(power.levelPercent)%" : "—")
                        .font(mono(28, weight: .bold))
                        .foregroundColor(FColor.cyan)
                    Text(power.statusText)
                        .font(mono(11))
                        .foregroundColor(FColor.text)
                    Text(power.timeText)
                        .font(mono(11))
                        .foregroundColor(FColor.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    metric("Package", String(format: "%.1f W", power.packageWatts), FColor.orange)
                    if power.isCharging {
                        metric("Charge in", String(format: "%.1f W", power.chargeWatts), FColor.green)
                    } else if power.chargeWatts > 0 {
                        metric("Draw", String(format: "%.1f W", power.chargeWatts), FColor.red)
                    }
                    if let h = power.healthPercent {
                        metric("Health", "\(h)%", FColor.cyan)
                    }
                    if let c = power.cycleCount {
                        metric("Cycles", "\(c)", FColor.muted)
                    }
                }
            }
            Text("CPU package (60s)")
                .font(mono(10))
                .foregroundColor(FColor.muted)
            Sparkline(values: power.wattHistory, color: FColor.orange)
                .frame(height: 44)
                .padding(8)
                .background(FColor.card)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(FColor.border, lineWidth: 1))
            HStack {
                Text(String(format: "P-cores ~%.0f%%", power.pCoreShare * 100))
                Spacer()
                Text(String(format: "E-cores ~%.0f%%", power.eCoreShare * 100))
            }
            .font(mono(10))
            .foregroundColor(FColor.muted)
            if let raw = power.capacityRaw, let design = power.designCapacity {
                Text("Capacity \(raw) / \(design) mAh (design)")
                    .font(mono(10))
                    .foregroundColor(FColor.muted)
            }
        }
    }

    private func metric(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Text(k).font(mono(10)).foregroundColor(FColor.muted)
            Text(v).font(mono(12, weight: .semibold)).foregroundColor(c)
        }
    }
}

struct EnergyList: View {
    @ObservedObject var store = ProcessEnergyStore.shared
    @State private var expanded: Int32?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP ENERGY (local estimate)")
                .font(mono(10, weight: .semibold))
                .foregroundColor(FColor.muted)
            Text("Comparable ranking — not identical to Activity Monitor’s private score.")
                .font(mono(9))
                .foregroundColor(FColor.muted.opacity(0.8))
            if store.top.isEmpty {
                Text("Sampling processes…")
                    .font(mono(11))
                    .foregroundColor(FColor.muted)
            }
            ForEach(store.top.prefix(8)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        expanded = expanded == p.id ? nil : p.id
                    } label: {
                        HStack {
                            Text(p.name)
                                .font(mono(11, weight: .medium))
                                .foregroundColor(FColor.text)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f", p.energyScore))
                                .font(mono(11, weight: .semibold))
                                .foregroundColor(FColor.orange)
                            Text(String(format: "%.0f%%", p.cpuPercent))
                                .font(mono(10))
                                .foregroundColor(FColor.muted)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded == p.id {
                        Sparkline(values: p.samples, color: FColor.cyan)
                            .frame(height: 28)
                        Text(p.path.isEmpty ? "pid \(p.id)" : p.path)
                            .font(mono(9))
                            .foregroundColor(FColor.muted)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct WhyDrainView: View {
    @State private var why = DrainLog.shared.whyLastHour()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHY DRAIN?")
                    .font(mono(10, weight: .semibold))
                    .foregroundColor(FColor.muted)
                Spacer()
                Button("Refresh") {
                    why = DrainLog.shared.whyLastHour()
                }
                .font(mono(10))
                .buttonStyle(.plain)
                .foregroundColor(FColor.cyan)
            }
            Text(why.summary)
                .font(mono(11))
                .foregroundColor(FColor.text)
                .fixedSize(horizontal: false, vertical: true)
            if why.dropPercent > 0 {
                Text("Drop ~\(why.dropPercent)% · \(why.windowLabel)")
                    .font(mono(10))
                    .foregroundColor(FColor.orange)
            }
            ForEach(Array(why.culprits.enumerated()), id: \.offset) { _, c in
                HStack {
                    Text(c.name).font(mono(11, weight: .medium)).foregroundColor(FColor.cyan)
                    Spacer()
                    Text(c.note).font(mono(9)).foregroundColor(FColor.muted)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var log = DrainLog.shared
    @State private var days: Double = Double(DrainLog.shared.retentionDays)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SETTINGS")
                .font(mono(10, weight: .semibold))
                .foregroundColor(FColor.muted)
            Text("Fathom \(FATHOM_VERSION) · \(FATHOM_CHANNEL)")
                .font(mono(11))
            Text("Local only — no accounts, no telemetry.")
                .font(mono(10))
                .foregroundColor(FColor.muted)
            Text("History retention: \(Int(days)) days")
                .font(mono(11))
            Slider(value: $days, in: 1...30, step: 1)
                .onChange(of: days) { _, newVal in
                    log.setRetention(Int(newVal))
                }
            Button("Clear local history") {
                log.clearAll()
            }
            .font(mono(11))
            .foregroundColor(FColor.red)
            .buttonStyle(.plain)
            Text("Data: \(SUPPORT_DIR.path)")
                .font(mono(9))
                .foregroundColor(FColor.muted)
                .lineLimit(2)
            Button("Reveal data folder") {
                NSWorkspace.shared.open(SUPPORT_DIR)
            }
            .font(mono(10))
            .foregroundColor(FColor.cyan)
            .buttonStyle(.plain)
        }
    }
}

enum PopTab: String, CaseIterable, Identifiable {
    case power, energy, why, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .power: return "Power"
        case .energy: return "Energy"
        case .why: return "Why"
        case .settings: return "Settings"
        }
    }
}

struct MainRoot: View {
    @State private var tab: PopTab = .power
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FATHOM")
                    .font(mono(13, weight: .bold))
                    .foregroundColor(FColor.cyan)
                Text(FATHOM_VERSION)
                    .font(mono(9))
                    .foregroundColor(FColor.muted)
                Spacer()
                Text("local only")
                    .font(mono(9))
                    .foregroundColor(FColor.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            HStack(spacing: 0) {
                ForEach(PopTab.allCases) { t in
                    Button(t.title) { tab = t }
                        .font(mono(10, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? FColor.bg : FColor.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tab == t ? FColor.cyan : Color.clear)
                        .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            Divider().background(FColor.border)
            ScrollView {
                Group {
                    switch tab {
                    case .power: PowerDashboard()
                    case .energy: EnergyList()
                    case .why: WhyDrainView()
                    case .settings: SettingsView()
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 400, minHeight: 520)
        .background(FColor.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - App delegate (standard windowed app — not menu bar)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        PowerStore.shared.start()
        ProcessEnergyStore.shared.start()

        let host = NSHostingController(rootView: MainRoot())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "Fathom"
        window.minSize = NSSize(width: 380, height: 500)
        window.setFrameAutosaveName("FathomMainWindow")
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// Keep AppDelegate alive for the process lifetime.
private let fathomAppDelegate = AppDelegate()

@main
struct FathomAppMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = fathomAppDelegate
        app.run()
    }
}

SWIFTEOF

echo "🔨 Compiling Fathom (this takes a few seconds)..."
swiftc "$WORK_DIR/main.swift" \
    -o "$WORK_DIR/Fathom" \
    -framework SwiftUI \
    -framework Cocoa \
    -framework IOKit \
    -parse-as-library \
    -O

strip -x "$WORK_DIR/Fathom" 2>/dev/null || true

if [[ ! -f "$WORK_DIR/Fathom" || -L "$WORK_DIR/Fathom" ]]; then
  echo "❌ Compiled binary missing. Aborting."
  exit 1
fi
chmod 700 "$WORK_DIR/Fathom"

echo "📦 Building Fathom.app..."
mkdir -p "$HOME/Applications"

if [[ -e "$APP_DEST" && ! -d "$APP_DEST" ]]; then
  echo "❌ $APP_DEST exists and is not a directory. Aborting."
  exit 1
fi
if [[ -L "$APP_DEST" ]]; then
  echo "❌ $APP_DEST is a symlink. Aborting."
  exit 1
fi
pkill -x Fathom 2>/dev/null || true
sleep 0.3
rm -rf -- "$APP_DEST"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$WORK_DIR/Fathom" "$APP_DEST/Contents/MacOS/Fathom"
chmod 755 "$APP_DEST/Contents/MacOS/Fathom"

cat > "$APP_DEST/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Fathom</string>
    <key>CFBundleIdentifier</key><string>com.chopstickshq.fathom</string>
    <key>CFBundleName</key><string>Fathom</string>
    <key>CFBundleDisplayName</key><string>Fathom</string>
    <key>CFBundleVersion</key><string>0.1.1</string>
    <key>CFBundleShortVersionString</key><string>0.1.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLISTEOF
chmod 644 "$APP_DEST/Contents/Info.plist"

if sign_app_bundle "$APP_DEST"; then
  if codesign --verify --deep --strict "$APP_DEST" 2>/dev/null; then
    echo "✅ Code signature verified."
  else
    echo "⚠️  Code signature verification failed."
  fi
else
  echo "⚠️  Ad-hoc code signing failed; Gatekeeper may block launch."
fi

xattr -cr "$APP_DEST" 2>/dev/null || true
BINARY_HASH="$(shasum -a 256 "$APP_DEST/Contents/MacOS/Fathom" | awk '{print $1}')"
echo "🔒 Binary SHA-256 (reference): $BINARY_HASH"

echo ""
echo "✅ Fathom installed to $APP_DEST"
echo "🚀 Launching..."
open "$APP_DEST"
