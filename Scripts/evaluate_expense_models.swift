import Foundation
import CoreML
import CryptoKit
// Read-only evaluation. Never trains or overwrites models. Run from repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func load(_ name: String) throws -> MLModel {
    let compiled = try MLModel.compileModel(at: root.appendingPathComponent("HomeMate/MLModels/\(name).mlmodel"))
    let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
    return try MLModel(contentsOf: compiled, configuration: config)
}
func rows(_ name: String) throws -> [[String: Any]] {
    guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ML/Data/\(name).json"))) as? [[String: Any]], !rows.isEmpty else { throw NSError(domain: "Empty evaluation dataset", code: 1) }
    return rows
}
func rate(_ numerator: Int, _ denominator: Int) -> Double { denominator > 0 ? Double(numerator)/Double(denominator) : 0 }
let classifier = try load("ExpenseClassifier"), forecast = try load("ExpenseForecast"), anomaly = try load("ExpenseAnomaly")
let labels = ["Groceries", "Utilities", "Transport", "Home", "Health", "Other"]
let trainTexts = Set(try rows("categories-train").compactMap { ($0["text"] as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
let validationTexts = Set(try rows("categories-validation").compactMap { ($0["text"] as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
func categoryReport(_ name: String) throws -> [String: Any] {
    let examples = try rows(name)
    var confusion: [String: [String: Int]] = [:], mistakes: [[String: String]] = [], slices: [String: [String: Int]] = [:]
    var correct = 0, overlap = 0
    let output = classifier.modelDescription.predictedFeatureName ?? classifier.modelDescription.outputDescriptionsByName.first { $0.value.type == .string }!.key
    for row in examples {
        let text = row["text"] as! String, actual = row["category"] as! String
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if trainTexts.contains(key) || validationTexts.contains(key) { overlap += 1 }
        let result = try classifier.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text":text]))
        let predicted = result.featureValue(for: output)!.stringValue
        confusion[actual, default: [:]][predicted, default: 0] += 1
        let slice = row["slice"] as? String ?? "original_holdout"
        slices[slice, default: [:]]["count", default: 0] += 1
        if predicted == actual { correct += 1; slices[slice, default: [:]]["correct", default: 0] += 1 }
        else { mistakes.append(["text":text,"expected":actual,"predicted":predicted]) }
    }
    var metrics: [String: [String: Double]] = [:]
    for label in labels {
        let tp = confusion[label]?[label] ?? 0
        let support = confusion[label]?.values.reduce(0,+) ?? 0
        let predicted = labels.reduce(0) { $0 + (confusion[$1]?[label] ?? 0) }
        let p = rate(tp,predicted), r = rate(tp,support)
        metrics[label] = ["precision":p,"recall":r,"f1":p+r > 0 ? 2*p*r/(p+r) : 0,"support":Double(support)]
    }
    return ["count":examples.count,"accuracy":rate(correct,examples.count),"macroF1":metrics.values.reduce(0) { $0 + $1["f1"]! }/Double(labels.count),"perCategory":metrics,"confusion":confusion,"slices":slices,"mistakes":mistakes,"exactTrainValidationOverlap":overlap]
}
func forecastReport(_ name: String, currency: Bool) throws -> [String: Any] {
    let examples = try rows(name)
    var ae=0.0, se=0.0, ape=0.0, rawAE=0.0, rawSE=0.0, rawAPE=0.0
    var baseAE=0.0, baseSE=0.0, baseAPE=0.0, fallbackCount=0
    let latestTrainingRange = 0.8330927492528469...1.1723745141781126
    let previousTrainingRange = 0.9390704276832605...1.0540911314301622
    for row in examples {
        let mean: Double, inputs: [String: Double], actual: Double
        let latestAmount: Double, previousAmount: Double, minimumAmount: Double, maximumAmount: Double
        if currency {
            let history = row["history"] as! [Double]; mean = history.reduce(0,+)/3
            inputs = ["latestRatio":history[2]/mean,"previousRatio":history[1]/mean]; actual = row["actual"] as! Double
            latestAmount = history[2]
            previousAmount = history[1]; minimumAmount = history.min()!; maximumAmount = history.max()!
        } else {
            mean = 1; inputs = ["latestRatio":row["latestRatio"] as! Double,"previousRatio":row["previousRatio"] as! Double]; actual = row["nextRatio"] as! Double
            latestAmount = inputs["latestRatio"]!
            previousAmount = inputs["previousRatio"]!
            let oldestAmount = 3 - latestAmount - previousAmount
            minimumAmount = min(oldestAmount, previousAmount, latestAmount); maximumAmount = max(oldestAmount, previousAmount, latestAmount)
        }
        let result = try forecast.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        let rawPrediction = result.featureValue(for:"nextRatio")!.doubleValue * mean
        let outOfRange = !latestTrainingRange.contains(inputs["latestRatio"]!) || !previousTrainingRange.contains(inputs["previousRatio"]!)
        if outOfRange { fallbackCount += 1 }
        let trend = latestAmount + 0.5 * (latestAmount - previousAmount)
        let safeTrend = min(max(trend, minimumAmount * 0.5), maximumAmount * 1.5)
        let prediction = outOfRange ? safeTrend : rawPrediction
        let error = abs(prediction-actual), baseError = abs(mean-actual)
        ae += error; se += error*error; ape += error/actual
        let rawError = abs(rawPrediction-actual)
        rawAE += rawError; rawSE += rawError*rawError; rawAPE += rawError/actual
        baseAE += baseError; baseSE += baseError*baseError; baseAPE += baseError/actual
    }
    let n = Double(examples.count)
    return ["count":examples.count,"units":currency ? "LKR (authored scenarios, not observed households)" : "normalised ratio",
        "MAE":ae/n,"RMSE":sqrt(se/n),"MAPEPercent":100*ape/n,"fallbackCount":fallbackCount,
        "rawModelMAE":rawAE/n,"rawModelRMSE":sqrt(rawSE/n),"rawModelMAPEPercent":100*rawAPE/n,
        "meanBaselineMAE":baseAE/n,"meanBaselineRMSE":sqrt(baseSE/n),"meanBaselineMAPEPercent":100*baseAPE/n]
}
let anomalyRows = try rows("anomaly-test")
var tp=0, fp=0, tn=0, fn=0
for row in anomalyRows {
    let result = try anomaly.prediction(from: MLDictionaryFeatureProvider(dictionary: row.filter { $0.key != "label" }))
    let score = result.featureValue(for: anomaly.modelDescription.predictedProbabilitiesName!)!.dictionaryValue["unusual"]!.doubleValue
    if score >= 0.7 { if row["label"] as! String == "unusual" { tp += 1 } else { fp += 1 } }
    else { if row["label"] as! String == "unusual" { fn += 1 } else { tn += 1 } }
}
let p = rate(tp,tp+fp), r = rate(tp,tp+fn)
var hashes: [String:String] = [:]
for name in ["ExpenseClassifier","ExpenseForecast","ExpenseAnomaly"] {
    hashes[name] = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("HomeMate/MLModels/\(name).mlmodel"))).map { String(format:"%02x",$0) }.joined()
}
let report: [String: Any] = [
    "provenance":"Authored descriptions and simulated histories only. Audit cases were written before evaluating; no tuning or retraining. No real-world validation claim. Zero denominators in classification metrics are reported as zero.",
    "modelSHA256": hashes,
    "category":try categoryReport("categories-test"),"categoryLocalOCRStress":try categoryReport("categories-audit"),
    "forecast":try forecastReport("forecast-test",currency:false),"forecastLKRStress":try forecastReport("forecast-audit",currency:true),
    "anomaly":["count":anomalyRows.count,"threshold":0.7,"tp":tp,"fp":fp,"tn":tn,"fn":fn,"precision":p,"recall":r,"f1":2*p*r/(p+r)]
]
let dir=root.appendingPathComponent("ML/Evaluation")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: dir.appendingPathComponent("all-models-evaluation.json"))
print("Evaluation written to ML/Evaluation/all-models-evaluation.json")
