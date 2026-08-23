import SwiftUI
import Combine
import Foundation
import StrandDesign
import WhoopProtocol
import WhoopStore

/// Research-only comparison of the newest WHOOP 4.0 v12 byte-85/86 pair with a manually entered
/// fingertip pulse-oximeter reading. Both WHOOP values are historical and sleep-gated, not live BLE
/// characteristics, so every observation preserves the raw bytes, timestamps, and lag.
struct Spo2ComparatorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    private struct Candidate: Equatable {
        let byte85: Int?
        let byte86: Int?
        let ts: Int

        var byte85Percent: Int? { Self.inBand(byte85) }
        var byte86Percent: Int? { Self.inBand(byte86) }

        private static func inBand(_ value: Int?) -> Int? {
            value.flatMap { (70...100).contains($0) ? $0 : nil }
        }
    }

    private static let alignedSeconds = 120
    private static let maximumPairingLagSeconds = 25 * 60

    @State private var latest: Candidate?
    @State private var referenceValue = 96
    @State private var observations = Spo2ComparisonArchive.load()
    @State private var isRefreshing = false
    @State private var readError: String?
    @State private var showClearConfirm = false

    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScreenScaffold(
            title: "SpO₂ Comparator",
            subtitle: "WHOOP 4.0 bytes 85/86 vs fingertip pulse oximeter",
            onRefresh: { await refreshCandidate() }
        ) {
            statusCard
            comparisonCard
            historyCard
        }
        .task { await refreshCandidate() }
        .onReceive(pollTimer) { _ in
            Task { await refreshCandidate() }
        }
        .confirmationDialog(
            "Clear comparison history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                observations = []
                Spo2ComparisonArchive.save([])
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the recorded pulse-oximeter comparisons from this device.")
        }
    }

    private var statusCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: 8) {
                    StatePill(
                        live.connected && live.bonded ? "Strap connected" : "Strap unavailable",
                        tone: live.connected && live.bonded ? .positive : .warning,
                        showsDot: live.connected && live.bonded)
                    Spacer()
                    alignmentPill
                }
                if isRefreshing { StatePill("Checking", tone: .accent, pulsing: true) }

                if let candidate = latest {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHOOP OPTICAL CANDIDATES")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                        HStack(spacing: NoopMetrics.space4) {
                            CandidateByteReadout(label: "BYTE 85", rawValue: candidate.byte85)
                            Divider().overlay(StrandPalette.hairline)
                            CandidateByteReadout(label: "BYTE 86", rawValue: candidate.byte86)
                        }
                        Text("\(candidateAgeText(candidate)) old")
                            .font(StrandFont.caption)
                            .foregroundStyle(candidateIsPairable(candidate)
                                ? StrandPalette.textTertiary : StrandPalette.statusWarning)
                        Text(candidateDate(candidate))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Waiting for a sleep-gated WHOOP 4.0 v12 candidate")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let readError {
                    Text(readError)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NoopButton("Sync strap now", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                    requestSync()
                }
                .disabled(!live.connected || !live.bonded)

                Text("Bytes 85 and 86 are emitted together in periodic sleep records. Values from 70 through 100 are shown as percentage-like; every saved pair also retains the unfiltered raw bytes.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("FINGERTIP REFERENCE")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                Stepper(value: $referenceValue, in: 70...100, step: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Pulse oximeter")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text("\(referenceValue)%")
                            .font(StrandFont.rounded(30))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                if let candidate = latest {
                    if let value = candidate.byte85Percent {
                        ComparatorReadoutRow(
                            label: String(localized: "Byte 85 minus reference"),
                            value: String(format: "%+d points", value - referenceValue))
                    }
                    if let value = candidate.byte86Percent {
                        ComparatorReadoutRow(
                            label: String(localized: "Byte 86 minus reference"),
                            value: String(format: "%+d points", value - referenceValue))
                    }
                    ComparatorReadoutRow(
                        label: String(localized: "Time separation"),
                        value: candidateAgeText(candidate))
                }

                NoopButton("Record comparison", systemImage: "plus", kind: .primary) {
                    recordComparison()
                }
                .disabled(latest.map { !candidateIsPairable($0) } ?? true)

                if let candidate = latest, !candidateIsPairable(candidate) {
                    Text("Sync and wait for a percentage-like byte 85 or 86 sample no more than 25 minutes old before recording a pair.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var historyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("RECORDED PAIRS")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("\(observations.count)")
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                if observations.isEmpty {
                    Text("No comparisons recorded")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(Array(observations.prefix(20).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(StrandPalette.hairline) }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("B85 \(row.byte85Display)")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("B86 \(row.byte86Display)")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text("ref \(row.referenceValue)%")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Text(row.deltaSummary)
                                .font(StrandFont.mono)
                                .foregroundStyle(row.deltas.allSatisfy { abs($0) <= 2 }
                                    ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                            Text("\(recordedDate(row)) · lag \(durationText(row.lagSeconds))")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        NoopButton("Export CSV", systemImage: "square.and.arrow.up", kind: .secondary) {
                            exportCSV()
                        }
                        Button("Clear", role: .destructive) { showClearConfirm = true }
                            .buttonStyle(.plain)
                            .font(StrandFont.subhead)
                    }
                }
            }
        }
    }

    @ViewBuilder private var alignmentPill: some View {
        if let candidate = latest {
            let age = candidateAgeSeconds(candidate)
            if candidate.byte85Percent == nil && candidate.byte86Percent == nil {
                StatePill("Status only", tone: .warning)
            } else if age <= Self.alignedSeconds {
                StatePill("Aligned", tone: .positive, showsDot: true)
            } else if age <= Self.maximumPairingLagSeconds {
                StatePill("Nearby", tone: .accent)
            } else {
                StatePill("Stale", tone: .warning)
            }
        } else {
            StatePill("No candidate", tone: .neutral)
        }
    }

    private func refreshCandidate() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let store = await model.repo.storeHandle() else {
            readError = String(localized: "On-device store is not ready")
            return
        }
        do {
            let row = try await store.latestWhoop4Spo2ResearchSample(deviceId: model.repo.deviceId)
            latest = row.map { sample in
                Candidate(byte85: sample.auxByte85, byte86: sample.auxByte86, ts: sample.ts)
            }
            readError = nil
        } catch {
            readError = String(localized: "Could not read the WHOOP candidate")
        }
    }

    private func requestSync() {
        model.ble.requestSync(.manual)
        Task {
            await refreshCandidate()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshCandidate()
        }
    }

    private func recordComparison() {
        guard let candidate = latest, candidateIsPairable(candidate) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let row = Spo2ComparisonObservation(
            id: UUID(), recordedTs: now, candidateTs: candidate.ts,
            candidateValue: candidate.byte85 ?? 0, byte86Raw: candidate.byte86,
            referenceValue: referenceValue,
            lagSeconds: abs(now - candidate.ts))
        observations.insert(row, at: 0)
        observations = Array(observations.prefix(Spo2ComparisonArchive.maximumRows))
        Spo2ComparisonArchive.save(observations)
    }

    private func exportCSV() {
        let formatter = ISO8601DateFormatter()
        var lines = ["recorded_at,candidate_at,byte_85_raw,byte_85_inband_pct,byte_86_raw,byte_86_inband_pct,reference_pct,byte_85_delta_points,byte_86_delta_points,lag_seconds"]
        lines += observations.reversed().map { row in
            let recorded = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.recordedTs)))
            let candidate = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.candidateTs)))
            return [recorded, candidate, String(row.candidateValue), row.csvByte85Percent,
                    row.csvByte86Raw, row.csvByte86Percent, String(row.referenceValue),
                    row.csvDelta85, row.csvDelta86, String(row.lagSeconds)].joined(separator: ",")
        }
        FileExport.exportText(
            lines.joined(separator: "\n") + "\n",
            suggestedName: FileExport.timestampedName("noop-spo2-comparison", ext: "csv"))
    }

    private func candidateAgeSeconds(_ candidate: Candidate) -> Int {
        max(0, Int(Date().timeIntervalSince1970) - candidate.ts)
    }

    private func candidateIsPairable(_ candidate: Candidate) -> Bool {
        candidateAgeSeconds(candidate) <= Self.maximumPairingLagSeconds
            && (candidate.byte85Percent != nil || candidate.byte86Percent != nil)
    }

    private func candidateAgeText(_ candidate: Candidate) -> String {
        durationText(candidateAgeSeconds(candidate))
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func candidateDate(_ candidate: Candidate) -> String {
        Date(timeIntervalSince1970: TimeInterval(candidate.ts))
            .formatted(date: .abbreviated, time: .standard)
    }

    private func recordedDate(_ row: Spo2ComparisonObservation) -> String {
        Date(timeIntervalSince1970: TimeInterval(row.recordedTs))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct CandidateByteReadout: View {
    let label: String
    let rawValue: Int?

    private var isInBand: Bool { rawValue.map { (70...100).contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(rawValue.map { isInBand ? "\($0)%" : "raw \($0)" } ?? "—")
                .font(StrandFont.rounded(32))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(isInBand ? "percentage-like" : "status / unavailable")
                .font(StrandFont.caption)
                .foregroundStyle(isInBand
                    ? StrandPalette.textSecondary : StrandPalette.statusWarning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ComparatorReadoutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(value)
                .font(StrandFont.mono)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct Spo2ComparisonObservation: Codable, Identifiable, Equatable {
    let id: UUID
    let recordedTs: Int
    let candidateTs: Int
    /// Kept under its original key so v1 observations decode without migration.
    let candidateValue: Int
    let byte86Raw: Int?
    let referenceValue: Int
    let lagSeconds: Int

    var byte85Percent: Int? { inBand(candidateValue) }
    var byte86Percent: Int? { byte86Raw.flatMap { inBand($0) } }
    var deltas: [Int] { [byte85Percent, byte86Percent].compactMap { $0 }.map { $0 - referenceValue } }
    var byte85Display: String { byteDisplay(candidateValue) }
    var byte86Display: String { byte86Raw.map(byteDisplay) ?? "—" }
    var deltaSummary: String {
        var values: [String] = []
        if let value = byte85Percent { values.append(String(format: "B85 %+d", value - referenceValue)) }
        if let value = byte86Percent { values.append(String(format: "B86 %+d", value - referenceValue)) }
        return values.isEmpty ? "No percentage-like value" : values.joined(separator: " · ")
    }
    var csvByte85Percent: String { byte85Percent.map { String($0) } ?? "" }
    var csvByte86Raw: String { byte86Raw.map { String($0) } ?? "" }
    var csvByte86Percent: String { byte86Percent.map { String($0) } ?? "" }
    var csvDelta85: String { byte85Percent.map { String($0 - referenceValue) } ?? "" }
    var csvDelta86: String { byte86Percent.map { String($0 - referenceValue) } ?? "" }

    private func inBand(_ value: Int) -> Int? { (70...100).contains(value) ? value : nil }
    private func byteDisplay(_ value: Int) -> String {
        inBand(value).map { "\($0)%" } ?? "raw \(value)"
    }
}

private enum Spo2ComparisonArchive {
    static let maximumRows = 100
    private static let key = "research.spo2Comparison.v1"

    static func load() -> [Spo2ComparisonObservation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Spo2ComparisonObservation].self, from: data) else {
            return []
        }
        return rows.sorted { $0.recordedTs > $1.recordedTs }
    }

    static func save(_ rows: [Spo2ComparisonObservation]) {
        if rows.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(Array(rows.prefix(maximumRows))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
