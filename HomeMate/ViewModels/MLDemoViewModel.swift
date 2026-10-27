import Foundation
import Combine

@MainActor
final class MLDemoViewModel: ScreenViewModel {
    @Published var description = "Keells groceries and fresh milk"
    @Published var oldest = 40000.0
    @Published var previous = 43000.0
    @Published var latest = 46000.0
    @Published var category: String?
    @Published var prediction: Double?
    @Published var categoryError: String?
    @Published var forecastError: String?

    func predictCategory() {
        do { category = try ExpenseIntelligence.suggestCategory(description); categoryError = nil }
        catch { category = nil; categoryError = error.localizedDescription }
    }
    func predictForecast() {
        do {
            guard let model = ExpenseIntelligence.forecaster else { throw ExpenseIntelligence.ModelError.missingModel }
            prediction = try ExpenseIntelligence.predictMonth(history: [oldest, previous, latest], model: model); forecastError = nil
        } catch { prediction = nil; forecastError = error.localizedDescription }
    }

}
