import Foundation
import CreateML
import CoreML
import TabularData

// Run from the repository root. Create ML trains on the Mac; the app only predicts.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataDirectory = root.appendingPathComponent("ML/Data")
let modelDirectory = root.appendingPathComponent("HomeMate/MLModels")
let reportDirectory = root.appendingPathComponent("ML/Reports")
func table(_ name: String) throws -> DataFrame {
    try DataFrame(contentsOfCSVFile: dataDirectory.appendingPathComponent(name + ".csv"))
}
func metadata(_ description: String) -> MLModelMetadata {
    MLModelMetadata(author: "HomeMate", shortDescription: description, version: "1.0-demo")
}
let classifier = try MLTextClassifier(
    trainingData: table("categories-train"), textColumn: "text", labelColumn: "category",
    parameters: .init(validation: .dataFrame(try table("categories-validation"), textColumn: "text", labelColumn: "category"), algorithm: .maxEnt(revision: 1), language: .english)
)
try classifier.write(to: modelDirectory.appendingPathComponent("ExpenseClassifier.mlmodel"), metadata: metadata("DEMO: trained on 180 hand-authored English household expense examples. Review every suggested category."))
let regressor = try MLLinearRegressor(
    trainingData: table("forecast-train"), targetColumn: "nextRatio", featureColumns: ["latestRatio", "previousRatio"],
    parameters: .init(validation: .dataFrame(try table("forecast-validation")), maxIterations: 50, l2Penalty: 0.01)
)
try regressor.write(to: modelDirectory.appendingPathComponent("ExpenseForecast.mlmodel"), metadata: metadata("DEMO: linear regression trained on simulated household histories, not real financial data. Inputs are normalized monthly spending ratios."))

struct TextExample: Decodable { let text: String; let category: String }
struct ForecastExample: Decodable { let latestRatio: Double; let previousRatio: Double; let nextRatio: Double }
let textTests = try JSONDecoder().decode([TextExample].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("categories-test.json")))
let forecastTests = try JSONDecoder().decode([ForecastExample].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("forecast-test.json")))
let outputName = classifier.model.modelDescription.predictedFeatureName ?? classifier.model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .string })!.key
let probabilitiesName = classifier.model.modelDescription.predictedProbabilitiesName ?? classifier.model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .dictionary })?.key ?? ""
var correct = 0
var mistakes: [[String: String]] = []
var perCategory: [String: [String: Int]] = [:]
for example in textTests {
    let input = try MLDictionaryFeatureProvider(dictionary: ["text": example.text])
    let output = try classifier.model.prediction(from: input)
    let predicted = output.featureValue(for: outputName)?.stringValue ?? ""
    perCategory[example.category, default: ["correct": 0, "total": 0]]["total", default: 0] += 1
    if predicted == example.category {
        correct += 1
        perCategory[example.category]!["correct", default: 0] += 1
    } else { mistakes.append(["text": example.text, "expected": example.category, "predicted": predicted]) }
}
var squaredError = 0.0, absoluteError = 0.0, baselineSquaredError = 0.0
for example in forecastTests {
    let input = try MLDictionaryFeatureProvider(dictionary: ["latestRatio": example.latestRatio, "previousRatio": example.previousRatio])
    let result = try regressor.model.prediction(from: input)
    let predicted = result.featureValue(for: "nextRatio")!.doubleValue
    squaredError += pow(predicted - example.nextRatio, 2)
    absoluteError += abs(predicted - example.nextRatio)
    baselineSquaredError += pow(1 - example.nextRatio, 2)
}
let count = Double(forecastTests.count)
let report: [String: Any] = [
    "dataProvenance": "Demonstration data only: authored English descriptions and simulated spending sequences. Test metrics are not real-world accuracy or financial validation.",
    "classifier": ["trainingRows": 180, "validationRows": 36, "testRows": textTests.count, "testAccuracy": Double(correct)/Double(textTests.count), "perCategory": perCategory, "mistakes": mistakes, "inputNames": Array(classifier.model.modelDescription.inputDescriptionsByName.keys), "outputName": outputName, "probabilitiesName": probabilitiesName],
    "forecast": ["trainingRows": 1600, "validationRows": 320, "testRows": forecastTests.count, "testRatioMAE": absoluteError/count, "testRatioRMSE": sqrt(squaredError/count), "historicalMeanBaselineRatioRMSE": sqrt(baselineSquaredError/count), "inputNames": Array(regressor.model.modelDescription.inputDescriptionsByName.keys), "outputName": "nextRatio", "note": "One-step synthetic test only; recursively predicting a second month has not been validated."]
]
let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
try reportData.write(to: reportDirectory.appendingPathComponent("evaluation.json"))
print("MODEL_OUTPUT \(outputName), probabilities \(probabilitiesName)")
print("Held-out category accuracy: \(correct)/\(textTests.count)")
print("Held-out forecast ratio RMSE: \(sqrt(squaredError/count)); mean baseline: \(sqrt(baselineSquaredError/count))")
print("Saved both trained Core ML models and ML/Reports/evaluation.json")
