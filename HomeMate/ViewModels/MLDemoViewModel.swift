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
    @Published var forecastUsesTrendFallback = false

    func predictCategory() {
        do { category = try ExpenseIntelligence.suggestCategory(description); categoryError = nil }
        catch { category = nil; categoryError = error.localizedDescription }
    }
    func predictForecast() {
        do {
            guard let model = ExpenseIntelligence.forecaster else { throw ExpenseIntelligence.ModelError.missingModel }
            let estimate = try ExpenseIntelligence.estimateMonth(history: [oldest, previous, latest], model: model)
            prediction = estimate.amount
            forecastUsesTrendFallback = estimate.usesTrendFallback
            forecastError = nil
        } catch { prediction = nil; forecastUsesTrendFallback = false; forecastError = error.localizedDescription }
    }

}
