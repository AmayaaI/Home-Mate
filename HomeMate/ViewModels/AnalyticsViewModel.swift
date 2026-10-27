import Foundation
import Combine

@MainActor
final class AnalyticsViewModel: ScreenViewModel {
    struct Analysis {
        var anomalies: ExpenseIntelligence.AnomalyReport
        var patterns: [ExpenseIntelligence.Pattern]
        var forecast: Result<ExpenseIntelligence.MonthlyForecast, Error>
        var comparisons: [ExpenseIntelligence.ForecastComparison]
    }
    @Published private var completedAnalysis: Analysis?
    @Published private var completedKey: String?
    @Published private(set) var analysing = false
    var analysisKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (context?.identity ?? accountDataScope) + String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            + ((try? encoder.encode(activeRecords)).map { $0.base64EncodedString() } ?? "")
    }
    // Hide stale results immediately, even before SwiftUI starts the replacement task.
    var analysis: Analysis? { isActive && completedKey == analysisKey ? completedAnalysis : nil }
    func analyse() async {
        guard isActive else { return }
        let key = analysisKey, scope = accountDataScope, records = activeRecords
        analysing = true
        let worker = Task.detached(priority: .utility) {
            Analysis(anomalies: ExpenseIntelligence.unusualTransactions(records: records),
                patterns: ExpenseIntelligence.patterns(records: records),
                forecast: Result { try ExpenseIntelligence.forecast(records: records) },
                comparisons: ExpenseIntelligence.forecastComparisons(records: records))
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard isCurrent(scope), analysisKey == key else { return }
        completedAnalysis = result; completedKey = key; analysing = false
    }
    var groups: [(String, Double)] { ExpenseIntelligence.categories.map { category in (category, monthlyExpenses.filter { $0.category == category }.reduce(0) { $0 + $1.amount }) }.filter { $0.1 > 0 } }
    var previous: Double { ExpenseIntelligence.spendingRecords(activeRecords, inMonthOf: Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()).reduce(0) { $0 + $1.amount } }
    var currentTotal: Double { monthlyExpenses.reduce(0) { $0 + $1.amount } }
    var alerts: [ExpenseIntelligence.SpendingAlert] { ExpenseIntelligence.spendingAlerts(records: activeRecords) }
    var categoryModelReady: Bool { ExpenseIntelligence.categoryModelReady }
    var forecast: Result<ExpenseIntelligence.MonthlyForecast, Error> { analysis?.forecast ?? .failure(ExpenseIntelligence.ModelError.insufficientHistory) }
    var budgetWarning: String? {
        let budget = preferences.monthlyBudget
        guard budget > 0 else { return nil }
        if currentTotal > budget { return "Recorded spending is \(money(currentTotal - budget)) over your monthly budget." }
        if case .success(let value) = analysis?.forecast, value.thisMonthAmount > budget {
            return "Core ML estimates \(money(value.thisMonthAmount - budget)) above your monthly budget. This is an experimental estimate, not a confirmed overspend."
        }
        return nil
    }
}
