import Foundation
import CoreML

@main
struct VerifyModels {
    struct Example: Decodable { let text: String; let category: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "HomeMateMLTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "HomeMateMLTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass the built HomeMate.app path."]) }
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let classifier = try MLModel(contentsOf: app.appendingPathComponent("ExpenseClassifier.mlmodelc"), configuration: config)
        let forecast = try MLModel(contentsOf: app.appendingPathComponent("ExpenseForecast.mlmodelc"), configuration: config)
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: URL(fileURLWithPath: "ML/Data/categories-test.json")))
        var correct = 0
        for example in examples {
            if try ExpenseIntelligence.predictCategory(example.text, model: classifier) == example.category { correct += 1 }
        }
        try require(Double(correct) / Double(examples.count) >= 0.8, "Compiled classifier failed its held-out smoke check")
        let amount = try ExpenseIntelligence.predictMonth(history: [40000, 43000, 46000], model: forecast)
        let scaled = try ExpenseIntelligence.predictMonth(history: [80000, 86000, 92000], model: forecast)
        try require(amount > 0 && amount.isFinite, "Forecast must be positive and finite")
        try require(abs(scaled - 2 * amount) < 0.01, "Normalized forecast must preserve currency scaling")
        do {
            _ = try ExpenseIntelligence.predictMonth(history: [0, 100, 120], model: forecast)
            throw NSError(domain: "HomeMateMLTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Zero history should be rejected"])
        } catch ExpenseIntelligence.ModelError.insufficientHistory { }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Colombo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        func expense(_ month: Int, _ amount: Double) -> HouseholdRecord {
            HouseholdRecord(kind: .expense, title: "Monthly expenses", amount: amount, date: calendar.date(from: DateComponents(year: 2026, month: month, day: 10))!, category: "Groceries")
        }
        let history = [expense(7, 40000), expense(8, 43000), expense(9, 46000)]
        var paidBill = HouseholdRecord(kind: .bill, title: "Electricity", amount: 5000, date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!, category: "Utilities", completed: true)
        paidBill.paidAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let unpaidBill = HouseholdRecord(kind: .bill, title: "Water", amount: 2000, date: now, category: "Utilities")
        let octoberSpending = ExpenseIntelligence.spendingRecords([expense(10, 1000), paidBill, unpaidBill], inMonthOf: now, calendar: calendar)
        try require(octoberSpending.count == 2 && octoberSpending.reduce(0) { $0 + $1.amount } == 6000, "Paid bills must count in the paid month and unpaid bills must not count as spending")
        let totals = try ExpenseIntelligence.completedMonthTotals(records: history + [expense(10, 999999)], now: now, calendar: calendar)
        try require(totals == [40000, 43000, 46000], "Partial current month must not enter completed month history")
        do {
            _ = try ExpenseIntelligence.completedMonthTotals(records: [history[0], history[2]], now: now, calendar: calendar)
            throw NSError(domain: "HomeMateMLTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing history should be rejected"])
        } catch ExpenseIntelligence.ModelError.insufficientHistory { }
        let noAlert = ExpenseIntelligence.spendingAlerts(records: history + [expense(10, 1000)], now: now, calendar: calendar)
        let alert = ExpenseIntelligence.spendingAlerts(records: history + [expense(10, 100000)], now: now, calendar: calendar)
        try require(noAlert.isEmpty && alert.count == 1 && alert[0].category == "Groceries", "Spending alerts failed their threshold check")
        print("PASS: compiled classifier \(correct)/\(examples.count) on held-out demo descriptions")
        print("PASS: compiled regressor predicts \(amount.formatted(.number.precision(.fractionLength(2)))) for demo history 40000/43000/46000")
        print("PASS: scaling, invalid history, completed-month selection, missing-month handling and spending alerts")
    }
}
