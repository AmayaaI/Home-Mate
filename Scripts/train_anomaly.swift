import Foundation
import CreateML
import CoreML
import TabularData
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func table(_ split: String) throws -> DataFrame { try DataFrame(contentsOfCSVFile: root.appendingPathComponent("ML/Data/anomaly-\(split).csv")) }
let forest = try MLRandomForestClassifier(trainingData: table("train"), targetColumn: "label",
    featureColumns: ["category", "amountRatio", "householdRatio", "deviation", "categoryFrequency"],
    parameters: .init(validation: .dataFrame(try table("validation")), maxDepth: 6, maxIterations: 60, randomSeed: 7241))
try forest.write(to: root.appendingPathComponent("HomeMate/MLModels/ExpenseAnomaly.mlmodel"), metadata: MLModelMetadata(author: "HomeMate", shortDescription: "Experimental supervised unusual-expense detector; trained on simulated disjoint household histories. Not fraud detection. Threshold 0.70; score is not calibrated confidence.", version: "1.0-simulation"))
let probabilityName = forest.model.modelDescription.predictedProbabilitiesName!
var reports: [String: Any] = [:]
for split in ["validation", "test"] {
    let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ML/Data/anomaly-\(split).json"))) as! [[String: Any]]
    var tp=0, fp=0, tn=0, fn=0, baselineTP=0, baselineFP=0, baselineFN=0
    for row in rows {
        let input = try MLDictionaryFeatureProvider(dictionary: row.filter { $0.key != "label" })
        let prediction = try forest.model.prediction(from: input)
        let score = prediction.featureValue(for: probabilityName)!.dictionaryValue["unusual"]!.doubleValue
        let positive = row["label"] as? String == "unusual"
        if score >= 0.7 { if positive { tp += 1 } else { fp += 1 } }
        else { if positive { fn += 1 } else { tn += 1 } }
        let baseline = (row["amountRatio"] as! Double) > 3 && (row["deviation"] as! Double) > 3
        if baseline { if positive { baselineTP += 1 } else { baselineFP += 1 } }
        else if positive { baselineFN += 1 }
    }
    let precision=Double(tp)/Double(max(1,tp+fp)), recall=Double(tp)/Double(max(1,tp+fn))
    reports[split] = ["rows": rows.count, "tp": tp, "fp": fp, "tn": tn, "fn": fn,
      "precision": precision, "recall": recall, "f1": 2*precision*recall/max(0.0001,precision+recall),
      "accuracy": Double(tp+tn)/Double(rows.count),
      "baselinePrecision": Double(baselineTP)/Double(max(1,baselineTP+baselineFP)),
      "baselineRecall": Double(baselineTP)/Double(max(1,baselineTP+baselineFN))]
}
reports["threshold"] = 0.7
reports["probabilityOutput"] = probabilityName
reports["provenance"] = "Synthetic households, disjoint seeds per split. Metrics do not establish real-world accuracy. No personal data used."
let dir=root.appendingPathComponent("ML/Evaluation")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted,.sortedKeys]).write(to: dir.appendingPathComponent("anomaly-evaluation.json"))
print(reports)
