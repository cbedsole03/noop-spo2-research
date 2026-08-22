import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Manual body + intake log
//
// Lightweight local log for the two values the user commonly wants to enter by hand:
// calories eaten today and body weight. Uses the existing metricSeries table so the values
// show up in Explore/Compare and ride along in full NOOP backups/server archives without a
// schema migration. Calories are additive for the local day; weight replaces the day's value.

enum ManualBodyNutritionLog {
    static let caloriesSource = "nutrition-csv"
    static let caloriesKey = "calories_in"
    static let weightSource = Repository.appleHealthSource
    static let weightKey = "weight"
}

extension Repository {
    func caloriesIn(day: String) async -> Double {
        guard let store = await storeHandle() else { return 0 }
        let pts = (try? await store.metricSeries(deviceId: ManualBodyNutritionLog.caloriesSource,
                                                 key: ManualBodyNutritionLog.caloriesKey,
                                                 from: day, to: day)) ?? []
        return pts.last?.value ?? 0
    }

    func loggedWeightKg(day: String) async -> Double? {
        guard let store = await storeHandle() else { return nil }
        let pts = (try? await store.metricSeries(deviceId: ManualBodyNutritionLog.weightSource,
                                                 key: ManualBodyNutritionLog.weightKey,
                                                 from: day, to: day)) ?? []
        return pts.last?.value
    }

    @discardableResult
    func saveManualBodyNutrition(day: String, addCalories calories: Double?, weightKg: Double?) async -> Bool {
        guard let store = await storeHandle() else { return false }
        var wrote = false
        do {
            if let calories, calories > 0 {
                let next = max(0, await caloriesIn(day: day) + calories)
                try await store.upsertMetricSeries(
                    [MetricPoint(day: day, key: ManualBodyNutritionLog.caloriesKey, value: next)],
                    deviceId: ManualBodyNutritionLog.caloriesSource)
                wrote = true
            }
            if let weightKg, weightKg > 0 {
                try await store.upsertMetricSeries(
                    [MetricPoint(day: day, key: ManualBodyNutritionLog.weightKey, value: weightKg)],
                    deviceId: ManualBodyNutritionLog.weightSource)
                wrote = true
            }
            if wrote { await refresh() }
            return wrote
        } catch {
            return false
        }
    }
}

struct ManualBodyNutritionLogView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    @State private var caloriesText = ""
    @State private var weightText = ""
    @State private var todayCalories: Double = 0
    @State private var latestWeightKg: Double?
    @State private var status: String?
    @State private var busy = false

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var day: String { Repository.localDayKey(Date()) }
    private var weightUnit: String { unitSystem == .imperial ? "lb" : "kg" }

    private var parsedCalories: Double? {
        Self.number(caloriesText).flatMap { (1...20_000).contains($0) ? $0 : nil }
    }

    private var parsedWeightKg: Double? {
        guard let raw = Self.number(weightText) else { return nil }
        let kg = unitSystem == .imperial ? raw / UnitFormatter.poundsPerKilogram : raw
        return (30...250).contains(kg) ? kg : nil
    }

    private var hasCaloriesInput: Bool { !caloriesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasWeightInput: Bool { !weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSave: Bool {
        (!hasCaloriesInput || parsedCalories != nil)
            && (!hasWeightInput || parsedWeightKg != nil)
            && (parsedCalories != nil || parsedWeightKg != nil)
            && !busy
    }

    var body: some View {
        ScreenScaffold(title: "Log intake & weight",
                       subtitle: "Add calories eaten today and your current body weight. Stored locally in NOOP.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                summaryCard
                inputCard
                helpCard
            }
            .task { await reload() }
        }
    }

    private var summaryCard: some View {
        StrandCard(padding: 18, tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Today", overline: "Manual log")
                HStack(spacing: 12) {
                    miniStat("Calories in", todayCalories > 0 ? "\(Int(todayCalories.rounded()))" : "—", "kcal")
                    miniStat("Weight", weightSummary, weightSummaryUnit)
                }
            }
        }
    }

    private var inputCard: some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calories eaten now")
                        .font(StrandFont.overline)
                        .foregroundStyle(StrandPalette.textTertiary)
                    TextField("e.g. 650", text: $caloriesText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Text("Adds to today's Calories In total.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Weight")
                        .font(StrandFont.overline)
                        .foregroundStyle(StrandPalette.textTertiary)
                    HStack(spacing: 8) {
                        TextField(unitSystem == .imperial ? "e.g. 185" : "e.g. 84", text: $weightText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        Text(weightUnit)
                            .font(StrandFont.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(minWidth: 34)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .background(NoopPanelSurface(cornerRadius: 9))
                            .accessibilityHidden(true)
                    }
                    Text("Replaces today's latest weight reading.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if let status {
                    Text(status)
                        .font(StrandFont.caption)
                        .foregroundStyle(status.hasPrefix("Saved") ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NoopButton(busy ? "Saving…" : "Save log", systemImage: "checkmark.circle.fill",
                           kind: .primary, fullWidth: true) { save() }
                    .disabled(!canSave)
            }
        }
    }

    private var helpCard: some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How this is used")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Calories In appears under Nutrition in Explore/Compare. Weight feeds the same weight series the Today Weight tile already reads. If Server archive is on, these values are included in the next daily backup.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var weightSummary: String {
        let kg = latestWeightKg ?? profile.weightKg
        let shown = unitSystem == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg
        return String(format: "%.1f", shown)
    }

    private var weightSummaryUnit: String {
        latestWeightKg == nil ? String(localized: "\(weightUnit) · profile") : weightUnit
    }

    private func miniStat(_ label: LocalizedStringKey, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(StrandFont.rounded(28, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(NoopPanelSurface(cornerRadius: 14))
    }

    private func save() {
        guard canSave else {
            status = String(localized: "Enter calories from 1-20,000 or weight from about 66-551 lb.")
            return
        }
        busy = true
        status = nil
        let calories = parsedCalories
        let weight = parsedWeightKg
        Task {
            let ok = await repo.saveManualBodyNutrition(day: day, addCalories: calories, weightKg: weight)
            await reload()
            await MainActor.run {
                busy = false
                if ok {
                    caloriesText = ""
                    weightText = ""
                    status = String(localized: "Saved today's log.")
                } else {
                    status = String(localized: "Could not save. Try again after NOOP finishes opening its local store.")
                }
            }
        }
    }

    private func reload() async {
        let cals = await repo.caloriesIn(day: day)
        let weight = await repo.loggedWeightKg(day: day)
        await MainActor.run {
            todayCalories = cals
            latestWeightKg = weight
        }
    }

    private static func number(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}
