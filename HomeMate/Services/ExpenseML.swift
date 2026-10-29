import Foundation
import CoreML

// Models train on the Mac. These cached Core ML models only run inference on-device.
enum ExpenseIntelligence {
    static let categories = ["Groceries", "Utilities", "Transport", "Home", "Health", "Other"]
    static let classifier = load("ExpenseClassifier")
    static let forecaster = load("ExpenseForecast")
    static var categoryModelReady: Bool { classifier != nil }
    static var forecastModelReady: Bool { forecaster != nil }

    enum ModelError: LocalizedError {
        case missingModel, emptyText, invalidPrediction, insufficientHistory
        var errorDescription: String? {
            switch self {
            case .missingModel: "The Core ML model could not be loaded. Try rebuilding the app; manual record entry is still available."
            case .emptyText: "Enter an expense description first."
            case .invalidPrediction: "The model could not make a valid prediction. Review the record manually."
            case .insufficientHistory: "Add expenses in each of the last three completed months to see a forecast."
            }
        }
    }
    private static func load(_ name: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: url, configuration: configuration)
    }
    static func suggestCategory(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.emptyText }
        guard let classifier else { throw ModelError.missingModel }
        return try predictCategory(text, model: classifier)
    }
    // A transparent terminology correction, not a learned model prediction.
    // Keep the existing trained model unchanged and preserve manual overrides.
    static func medicalCategoryCorrection(_ text: String) -> String? {
        let pattern = #"\b(medical report|medical test|blood test|laboratory test|doctor consultation|hospital bill)\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : "Health"
    }
    // Passing a model explicitly also lets the CLI tests exercise the exact app code.
    static func predictCategory(_ text: String, model: MLModel) throws -> String {
        let input = try MLDictionaryFeatureProvider(dictionary: ["text": String(text.prefix(12000))])
        let prediction = try model.prediction(from: input)
        let outputName = model.modelDescription.predictedFeatureName
            ?? model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .string })?.key
            ?? "label"
        guard let category = prediction.featureValue(for: outputName)?.stringValue, categories.contains(category) else { throw ModelError.invalidPrediction }
        return category
    }
    // OCR has a manual review screen; if prediction is unavailable, leave Other for review.
    static func categorize(_ text: String) -> String { (try? suggestCategory(text)) ?? "Other" }

    static func spendingDate(for record: HouseholdRecord) -> Date? {
        if record.kind == .expense { return record.date }
        if record.kind == .bill && record.completed { return record.paidAt ?? record.date }
        return nil
    }
    static func spendingRecords(_ records: [HouseholdRecord], inMonthOf month: Date, calendar: Calendar = .current) -> [HouseholdRecord] {
        uniqueSpending(records, calendar: calendar).filter { record in
            guard let date = spendingDate(for: record) else { return false }
            return calendar.isDate(date, equalTo: month, toGranularity: .month)
        }
    }

    struct MonthlyForecast {
        var thisMonth: Date
        var thisMonthAmount: Double
        var thisMonthUsesTrendFallback: Bool
        var nextMonth: Date
        var nextMonthAmount: Double
        var nextMonthUsesTrendFallback: Bool
        var history: [Double]
    }
    struct MonthlyEstimate {
        var amount: Double
        var usesTrendFallback: Bool
    }
    private static func trendFallback(for history: [Double]) -> MonthlyEstimate {
        let latest = history[2]
        let dampedTrend = latest + 0.5 * (latest - history[1])
        let minimumPlausible = (history.min() ?? latest) * 0.5
        let maximumPlausible = min((history.max() ?? latest) * 1.5, 1_000_000_000_000)
        let amount = min(max(dampedTrend, minimumPlausible), maximumPlausible)
        return MonthlyEstimate(amount: amount, usesTrendFallback: true)
    }
    static func completedMonthTotals(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current) throws -> [Double] {
        guard let currentMonth = calendar.dateInterval(of: .month, for: now)?.start else { throw ModelError.insufficientHistory }
        return try [-3, -2, -1].map { offset in
            guard let month = calendar.date(byAdding: .month, value: offset, to: currentMonth) else { throw ModelError.insufficientHistory }
            let expenses = spendingRecords(records, inMonthOf: month, calendar: calendar)
            let total = expenses.reduce(0) { $0 + $1.amount }
            guard !expenses.isEmpty, expenses.allSatisfy({ $0.amount.isFinite && $0.amount >= 0 }), total.isFinite, total > 0 else { throw ModelError.insufficientHistory }
            return total
        }
    }
    static func estimateMonth(history: [Double], model: MLModel) throws -> MonthlyEstimate {
        guard history.count == 3, history.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1_000_000_000_000 }) else { throw ModelError.insufficientHistory }
        let average = history.reduce(0, +) / 3
        guard average.isFinite, average > 0 else { throw ModelError.insufficientHistory }
        let latestRatio = history[2] / average
        let previousRatio = history[1] / average

        // The bundled regressor was trained on synthetic ratios in these ranges.
        // Outside that envelope it extrapolates sharply (e.g. 54k/23k/19k -> 5.4k),
        // so use a damped recent trend rather than trusting that extrapolation.
        let latestTrainingRange = 0.8330927492528469...1.1723745141781126
        let previousTrainingRange = 0.9390704276832605...1.0540911314301622
        guard latestTrainingRange.contains(latestRatio), previousTrainingRange.contains(previousRatio) else {
            return trendFallback(for: history)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["latestRatio": latestRatio, "previousRatio": previousRatio])
        let result = try model.prediction(from: input)
        guard let value = result.featureValue(for: "nextRatio"), value.type == .double else { throw ModelError.invalidPrediction }
        let amount = value.doubleValue * average
        guard amount.isFinite && amount > 0 && amount <= 1_000_000_000_000 && amount <= average * 10 else { throw ModelError.invalidPrediction }
        return MonthlyEstimate(amount: amount, usesTrendFallback: false)
    }
    static func predictMonth(history: [Double], model: MLModel) throws -> Double {
        try estimateMonth(history: history, model: model).amount
    }
    static func forecast(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current) throws -> MonthlyForecast {
        guard let forecaster else { throw ModelError.missingModel }
        let totals = try completedMonthTotals(records: records, now: now, calendar: calendar)
        let current = try estimateMonth(history: totals, model: forecaster)
        // Don't recursively feed a trend fallback into the model as if it were an ML forecast.
        let next: MonthlyEstimate
        if current.usesTrendFallback {
            next = trendFallback(for: [totals[1], totals[2], current.amount])
        } else {
            // Two-step forecast: next month includes this month's predicted total, not partial spending.
            next = try estimateMonth(history: [totals[1], totals[2], current.amount], model: forecaster)
        }
        let month = calendar.dateInterval(of: .month, for: now)!.start
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: month)!
        return MonthlyForecast(thisMonth: month, thisMonthAmount: current.amount,
            thisMonthUsesTrendFallback: current.usesTrendFallback,
            nextMonth: nextMonth, nextMonthAmount: next.amount,
            nextMonthUsesTrendFallback: next.usesTrendFallback, history: totals)
    }
    struct SpendingAlert: Identifiable {
        var category: String
        var current: Double
        var baseline: Double
        var id: String { category }
    }
    // Transparent statistical alerts, deliberately separate from ML predictions.
    static func spendingAlerts(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current) -> [SpendingAlert] {
        let records = uniqueSpending(records, calendar: calendar)
        guard let currentMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return categories.compactMap { category in
            let categoryRecords = records.filter { spendingDate(for: $0) != nil && $0.category == category && $0.amount.isFinite && $0.amount >= 0 }
            let previous = [-3, -2, -1].compactMap { offset -> Double? in
                guard let date = calendar.date(byAdding: .month, value: offset, to: currentMonth) else { return nil }
                let items = spendingRecords(categoryRecords, inMonthOf: date, calendar: calendar)
                return items.isEmpty ? nil : items.reduce(0) { $0 + $1.amount }
            }
            guard previous.count == 3 else { return nil }
            let average = previous.reduce(0, +) / 3
            let deviation = sqrt(previous.reduce(0) { $0 + pow($1 - average, 2) } / 3)
            let current = spendingRecords(categoryRecords, inMonthOf: now, calendar: calendar).reduce(0) { $0 + $1.amount }
            guard average > 0, current > average + max(average * 0.5, deviation * 2) else { return nil }
            return SpendingAlert(category: category, current: current, baseline: average)
        }
    }
}

extension ExpenseIntelligence {
    /// Call with one authorised household only. IDs have meaning within that scope.
    /// A paid bill IS spending: never create an additional expense for it here.
    static func uniqueSpending(_ records: [HouseholdRecord], calendar: Calendar = .current) -> [HouseholdRecord] {
        var ids = Set<UUID>()
        let unique = records.filter { ids.insert($0.id).inserted }
        let spending = unique.filter { spendingDate(for: $0) != nil && $0.amount.isFinite && $0.amount >= 0 }
        // Only suppress an explicit cross-kind duplicate with matching provider,
        // reference, amount and payment day. Similar titles alone are not evidence.
        func key(_ record: HouseholdRecord) -> String? {
            let reference = (record.referenceNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !reference.isEmpty, let date = spendingDate(for: record) else { return nil }
            return "\(record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(reference)|\(record.amount)|\(calendar.startOfDay(for: date).timeIntervalSince1970)"
        }
        var bills: [String: Int] = [:]
        for record in spending where record.kind == .bill {
            if let key = key(record) { bills[key, default: 0] += 1 }
        }
        return spending.filter { record in
            guard record.kind == .expense, let key = key(record), bills[key, default: 0] > 0 else { return true }
            bills[key, default: 0] -= 1
            return false
        }
    }

    struct AnomalyFeatures {
        let category: String
        let amountRatio: Double
        let householdRatio: Double
        let deviation: Double
        let categoryFrequency: Double
        let baseline: Double
        let sampleCount: Int
        var input: [String: Any] {
            ["category": category, "amountRatio": amountRatio, "householdRatio": householdRatio,
             "deviation": deviation, "categoryFrequency": categoryFrequency]
        }
    }
    static let anomalyModel = load("ExpenseAnomaly")
    static let anomalyThreshold = 0.7

    /// Strictly earlier transactions only; neither the target nor future records can leak into its baseline.
    static func anomalyFeatures(for record: HouseholdRecord, history: [HouseholdRecord], calendar: Calendar = .current) throws -> AnomalyFeatures {
        guard let date = spendingDate(for: record), record.amount.isFinite, record.amount > 0,
              categories.contains(record.category),
              let start = calendar.date(byAdding: .day, value: -180, to: date) else { throw ModelError.invalidPrediction }
        let previous = uniqueSpending(history, calendar: calendar).filter {
            guard $0.id != record.id, $0.amount > 0, let day = spendingDate(for: $0) else { return false }
            return day >= start && day < date
        }
        let same = previous.filter { $0.category == record.category }
        guard previous.count >= 20, same.count >= 6,
              let oldest = previous.compactMap({ spendingDate(for: $0) }).min(),
              calendar.dateComponents([.day], from: oldest, to: date).day ?? 0 >= 30 else { throw ModelError.insufficientHistory }
        let mean = same.reduce(0) { $0 + $1.amount } / Double(same.count)
        let overallMean = previous.reduce(0) { $0 + $1.amount } / Double(previous.count)
        let deviation = max(sqrt(same.reduce(0) { $0 + pow($1.amount - mean, 2) } / Double(same.count)), mean * 0.1)
        guard mean.isFinite, overallMean.isFinite, deviation.isFinite, mean > 0, overallMean > 0 else { throw ModelError.invalidPrediction }
        return AnomalyFeatures(category: record.category, amountRatio: min(record.amount / mean, 50),
            householdRatio: min(record.amount / overallMean, 50), deviation: min(max((record.amount - mean) / deviation, -50), 50),
            categoryFrequency: Double(same.count) / Double(previous.count), baseline: mean, sampleCount: same.count)
    }
    static func anomalyScore(_ features: AnomalyFeatures, model: MLModel) throws -> Double {
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features.input))
        guard let name = model.modelDescription.predictedProbabilitiesName,
              let score = prediction.featureValue(for: name)?.dictionaryValue["unusual"]?.doubleValue,
              score.isFinite, (0...1).contains(score) else { throw ModelError.invalidPrediction }
        return score
    }
    struct UnusualTransaction: Identifiable {
        let record: HouseholdRecord
        let baseline: Double
        let sampleCount: Int
        let score: Double?
        var id: UUID { record.id }
        var isML: Bool { score != nil }
        var explanation: String {
            "\(record.amount.formatted(.number.precision(.fractionLength(0...2)))) compared with a prior \(record.category.lowercased()) average of \(baseline.formatted(.number.precision(.fractionLength(0...2)))) across \(sampleCount) transactions. A large planned purchase can also be flagged."
        }
    }
    struct AnomalyReport {
        var transactions: [UnusualTransaction] = []
        var recentCount = 0
        var evaluated = 0
        var insufficient = 0
        var fallbackCount = 0
        var unavailable = false
        var failed = 0
    }
    static func unusualTransactions(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current, model: MLModel? = anomalyModel) -> AnomalyReport {
        let history = uniqueSpending(records, calendar: calendar)
        var report = AnomalyReport()
        report.unavailable = model == nil
        // Recent activity only; history still includes up to 180 earlier days for each transaction.
        let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        for record in history.sorted(by: { (spendingDate(for: $0) ?? .distantPast) > (spendingDate(for: $1) ?? .distantPast) }) {
            guard let date = spendingDate(for: record), date >= start, date <= now, record.amount > 0 else { continue }
            if Task.isCancelled { return report }
            report.recentCount += 1
            do {
                let features = try anomalyFeatures(for: record, history: history, calendar: calendar)
                report.evaluated += 1
                var score: Double?
                if let model {
                    do { score = try anomalyScore(features, model: model) }
                    catch { report.failed += 1 }
                }
                if score == nil { report.fallbackCount += 1 }
                let unusual = score.map { $0 >= anomalyThreshold } ?? (features.amountRatio > 3 && features.deviation > 3)
                if unusual {
                    report.transactions.append(UnusualTransaction(record: record, baseline: features.baseline, sampleCount: features.sampleCount, score: score))
                }
            } catch ModelError.insufficientHistory { report.insufficient += 1 }
            catch { report.failed += 1 }
        }
        return report
    }

    struct Pattern: Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    static func patterns(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current) -> [Pattern] {
        let records = uniqueSpending(records, calendar: calendar)
        guard let current = calendar.dateInterval(of: .month, for: now)?.start,
              let last = calendar.date(byAdding: .month, value: -1, to: current),
              let earlier = calendar.date(byAdding: .month, value: -2, to: current) else { return [] }
        var result: [Pattern] = []
        for category in categories {
            let items = records.filter { $0.category == category }
            let previous = spendingRecords(items, inMonthOf: last, calendar: calendar)
            let older = spendingRecords(items, inMonthOf: earlier, calendar: calendar)
            guard !previous.isEmpty, !older.isEmpty else { continue }
            let a = previous.reduce(0) { $0 + $1.amount }, b = older.reduce(0) { $0 + $1.amount }
            guard b > 0 else { continue }
            let change = (a-b)/b * 100
            result.append(Pattern(id: "trend-\(category)", title: "\(category): \(abs(change).formatted(.number.precision(.fractionLength(0))))% \(change >= 0 ? "higher" : "lower")",
                detail: "\(last.formatted(.dateTime.month(.wide))) versus \(earlier.formatted(.dateTime.month(.wide))), using completed months. \(previous.count) transactions last month."))
        }
        let recent = records.filter { (spendingDate(for: $0) ?? .distantPast) >= (calendar.date(byAdding: .month, value: -6, to: now) ?? now) && (spendingDate(for: $0) ?? .distantFuture) <= now }
        let groups = Dictionary(grouping: recent) { $0.category + "|" + $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) where group.count >= 3 {
            let ordered = group.sorted { spendingDate(for: $0)! < spendingDate(for: $1)! }
            let lastThree = Array(ordered.suffix(3))
            let intervals = zip(lastThree, lastThree.dropFirst()).map { calendar.dateComponents([.day], from: spendingDate(for: $0)!, to: spendingDate(for: $1)!).day ?? 0 }
            let mean = lastThree.reduce(0) { $0 + $1.amount } / 3
            guard mean > 0, intervals.allSatisfy({ (25...35).contains($0) }), lastThree.allSatisfy({ abs($0.amount-mean)/mean <= 0.2 }) else { continue }
            result.append(Pattern(id: "recurring-\(key)", title: "Possible monthly cost: \(lastThree[2].title)", detail: "Three payments about a month apart with similar amounts. Calculated from records; this does not confirm an active subscription."))
        }
        return result
    }
    struct ForecastComparison: Identifiable {
        let month: Date
        let estimate: Double
        let actual: Double
        let baseline: Double
        var id: Date { month }
        var percentageError: Double { abs(estimate-actual)/actual * 100 }
    }
    /// Historical replay, NOT a claim that a forecast was recorded in the past.
    static func forecastComparisons(records: [HouseholdRecord], now: Date = Date(), calendar: Calendar = .current) -> [ForecastComparison] {
        guard let forecaster, let start = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return [-3, -2, -1].compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: offset, to: start),
                  let history = try? completedMonthTotals(records: records, now: month, calendar: calendar),
                  let estimate = try? predictMonth(history: history, model: forecaster) else { return nil }
            let actual = spendingRecords(records, inMonthOf: month, calendar: calendar).reduce(0) { $0 + $1.amount }
            guard actual > 0 else { return nil }
            return ForecastComparison(month: month, estimate: estimate, actual: actual, baseline: history.reduce(0, +) / Double(history.count))
        }
    }
}
